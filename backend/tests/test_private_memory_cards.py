"""Synthetic private-card contracts; never use a configured database or model."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from threading import Event

import pytest
from sqlalchemy import event, select

from app.collaboration_models import FamilyMessage
from app.memory_models import PersonalMemory, Story, StoryMemoryLink
from app.models import FamilyLink, Task
from app.task_share_models import TaskShare
from .test_family_messages import message_preview
from tests.test_memory_controls import setup, auth, headers, state, enable, save, deletion


def create(client, owner, ids=(), **changes):
    return client.post('/stories', headers=headers(client, owner), json={
        'title': 'Original title', 'content': 'Original private card',
        'memory_ids': list(ids), **changes})


def card(client, owner, ids=()):
    response = create(client, owner, ids)
    assert response.status_code == 201, response.text
    return response.json()


def patch(client, owner, story, captured=None, **changes):
    return client.patch('/stories/' + story['id'],
                        headers=captured or headers(client, owner),
                        json={'title': 'Edited title', 'content': 'Edited private card', **changes})


def family_link(app, owner, recipient):
    with app.state.session_factory() as db:
        link = FamilyLink(elder_id=owner['account']['id'],
                          caregiver_id=recipient['account']['id'],
                          scopes=['family_messages', 'care_tasks'], status='active')
        db.add(link); db.commit()
        return {'id': link.id, 'authorization_epoch': link.authorization_epoch}


def share(client, owner, recipient, story, *, link, key='old-card-share', captured=None):
    return client.post('/family-messages', headers=captured or headers(client, owner), json={
        'recipient_id': recipient['account']['id'], 'source_story_id': story['id'],
        'content': story['title'] + '\n' + story['content'], 'client_message_id': key, **message_preview(link)})


def snapshot(app):
    """Persisted values, including revisions/timestamps, detect partial writes."""
    with app.state.session_factory() as db:
        tables = (Story, StoryMemoryLink, PersonalMemory, FamilyMessage, Task, TaskShare)
        result = {}
        for model in tables:
            result[model.__tablename__] = sorted(
                [tuple(getattr(row, col.name) for col in model.__table__.columns)
                 for row in db.scalars(select(model))], key=repr)
        from app.memory_models import MemoryRevision
        result['revision'] = sorted((row.owner_id, row.version, row.updated_at)
                                    for row in db.scalars(select(MemoryRevision)))
        return result


def test_patch_preserves_id_sources_and_withdraws_only_owner_old_share(setup):
    app, client, (owner, other, recipient) = setup
    enable(client, owner)
    first, second = save(client, owner), save(client, owner, 'Second source')
    story = card(client, owner, [first['id'], second['id']])
    independent_response = create(client, owner, title='Independent title', content='Keep independent body')
    assert independent_response.status_code == 201
    independent = independent_response.json()
    foreign = card(client, other)
    link = family_link(app, owner, recipient)
    link_id = link['id']
    sent = share(client, owner, recipient, story, link=link)
    assert sent.status_code == 201, sent.text
    unrelated = share(client, owner, recipient, independent, link=link, key='unrelated-share')
    assert unrelated.status_code == 201
    with app.state.session_factory() as db:
        ordinary = FamilyMessage(link_id=link_id, sender_id=owner['account']['id'],
                                 recipient_id=recipient['account']['id'], content='Ordinary message',
                                 client_message_id='ordinary')
        foreign_sender = FamilyMessage(link_id=link_id, sender_id=recipient['account']['id'],
                                       recipient_id=owner['account']['id'], content='Foreign sender keep',
                                       source_story_id=story['id'], client_message_id='foreign-sender')
        task = Task(owner_id=owner['account']['id'], created_by=owner['account']['id'],
                    title='Independent task', description='Keep task')
        db.add_all([ordinary, foreign_sender, task]); db.flush()
        task_share = TaskShare(task_id=task.id, family_link_id=link_id,
                               shared_by=owner['account']['id'], content_hash='a'*64,
                               request_hash='b'*64, idempotency_key='keep-task-share')
        db.add(task_share); db.commit()
    before = snapshot(app)
    revision = state(client, owner)['revision']
    response = patch(client, owner, story, title='  Edited title  ', content='  Edited private card  ')
    assert response.status_code == 200, response.text
    edited = response.json()
    assert edited['id'] == story['id'] and edited['created_at'] == story['created_at']
    assert set(edited['memory_ids']) == {first['id'], second['id']}
    assert edited['title'] == 'Edited title' and edited['content'] == 'Edited private card'
    assert edited['revision'] == revision + 1 == state(client, owner)['revision']
    after = snapshot(app)
    for table in ('story_memory_links', 'personal_memories', 'tasks', 'task_shares'):
        assert after[table] == before[table]
    with app.state.session_factory() as db:
        tombstone = db.get(FamilyMessage, sent.json()['id'])
        assert tombstone.content.startswith('[') and tombstone.content.endswith(']')
        assert story['content'] not in tombstone.content
        assert tombstone.source_story_id == story['id']
        assert db.get(FamilyMessage, unrelated.json()['id']).content == unrelated.json()['content']
        assert db.scalar(select(FamilyMessage).where(FamilyMessage.client_message_id == 'ordinary')).content == 'Ordinary message'
        assert db.scalar(select(FamilyMessage).where(FamilyMessage.client_message_id == 'foreign-sender')).content == 'Foreign sender keep'
        assert db.get(Story, independent['id']).content == independent['content']
        assert db.get(Story, foreign['id']).content == foreign['content']
    received = client.get('/family-messages', headers=auth(recipient))
    assert received.status_code == 200 and story['content'] not in received.text
    # Editing never implicitly republishes, even when the supplied text matches.
    assert len(after['family_messages']) == len(before['family_messages'])


@pytest.mark.parametrize('boundary,expected', [('missing', 422), ('stale', 409),
    ('malformed', 422), ('foreign', 403), ('caregiver', 403), ('guest', 401), ('absent', 404)])
def test_patch_revision_and_owner_boundaries_are_atomic(setup, boundary, expected):
    app, client, (owner, other, recipient) = setup
    story = card(client, owner)
    captured = headers(client, owner)
    if boundary == 'missing': captured = auth(owner)
    if boundary == 'stale': captured['X-Memory-Revision'] = '0'
    if boundary == 'malformed': captured['X-Memory-Revision'] = 'not-an-integer'
    if boundary == 'foreign': captured = headers(client, other)
    if boundary == 'caregiver': captured = {**auth(recipient), 'X-Memory-Revision': '0'}
    if boundary == 'guest': captured = {'X-Memory-Revision': '0'}
    if boundary == 'absent': story = {**story, 'id': 'missing-story'}
    before = snapshot(app)
    assert patch(client, owner, story, captured).status_code == expected
    assert snapshot(app) == before


@pytest.mark.parametrize('changes', [ {'memory_ids': []}, {'owner_id': 'other'},
    {'id': 'different'}, {'revision': 0}, {'unexpected': True}, {'title': ''},
    {'title': ' \t '}, {'content': ''}, {'content': '\n '},
    {'title': 'x'*241}, {'content': 'x'*30001} ])
def test_patch_forbids_source_changes_extra_fields_and_invalid_text(setup, changes):
    app, client, (owner, _, _) = setup
    story = card(client, owner)
    before = snapshot(app)
    assert patch(client, owner, story, **changes).status_code == 422
    assert snapshot(app) == before


@pytest.mark.parametrize('missing_field', ['title', 'content'])
def test_patch_requires_both_text_fields(setup, missing_field):
    app, client, (owner, _, _) = setup
    story = card(client, owner)
    payload = {'title': 'New', 'content': 'New body'}
    payload.pop(missing_field)
    before = snapshot(app)
    response = client.patch('/stories/' + story['id'], headers=headers(client, owner), json=payload)
    assert response.status_code == 422
    assert snapshot(app) == before


def test_patch_accepts_text_limits_and_rejects_oversize_family_payload_without_truncation(setup):
    app, client, (owner, _, recipient) = setup
    story = card(client, owner); link = family_link(app, owner, recipient)
    response = patch(client, owner, story, title='T'*240, content='B'*30000)
    assert response.status_code == 200, response.text
    assert response.json()['title'] == 'T'*240 and response.json()['content'] == 'B'*30000
    before = snapshot(app)
    assert share(client, owner, recipient, response.json(), link=link).status_code == 422
    assert snapshot(app) == before


@pytest.mark.parametrize('invalid', ['candidate', 'paused', 'deleted', 'superseded', 'foreign', 'missing'])
@pytest.mark.parametrize('operation', ['create', 'edit'])
def test_mixed_sources_reject_entire_card(setup, invalid, operation):
    app, client, (owner, other, _) = setup
    enable(client, owner)
    good, bad = save(client, owner), save(client, owner, 'Invalidated source')
    story = card(client, owner, [good['id'], bad['id']]) if operation == 'edit' else None
    with app.state.session_factory() as db:
        row = db.get(PersonalMemory, bad['id'])
        if invalid == 'candidate': row.status = 'candidate'
        if invalid == 'paused': row.suppressed = True
        if invalid == 'deleted': row.deleted_at = datetime.now(timezone.utc)
        if invalid == 'superseded': row.superseded_by = good['id']
        if invalid == 'foreign': row.owner_id = other['account']['id']
        if invalid == 'missing' and operation == 'create': db.delete(row)
        db.commit()
    if invalid == 'missing' and operation == 'edit':
        # A normal FK cascade removes provenance, and the public deletion API
        # also purges this card and advances revision (tested separately).
        # Deliberately construct an orphan only in this synthetic SQLite
        # connection to prove PATCH rejects a retained missing source link.
        with app.state.engine.connect() as connection:
            try:
                connection.exec_driver_sql('PRAGMA foreign_keys=OFF'); connection.commit()
                connection.exec_driver_sql('DELETE FROM personal_memories WHERE id=?', (bad['id'],))
                connection.commit()
            finally:
                connection.exec_driver_sql('PRAGMA foreign_keys=ON'); connection.commit()
        with app.state.session_factory() as db:
            retained = set(db.scalars(select(StoryMemoryLink.memory_id).where(
                StoryMemoryLink.story_id == story['id'])))
            assert retained == {good['id'], bad['id']}
    before = snapshot(app)
    response = patch(client, owner, story) if operation == 'edit' else create(client, owner, [good['id'], bad['id']])
    assert response.status_code == 400, response.text
    assert snapshot(app) == before


def test_create_duplicate_sources_rejected_without_write(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner); memory = save(client, owner)
    before = snapshot(app)
    assert create(client, owner, [memory['id'], memory['id']]).status_code == 422
    assert snapshot(app) == before


@pytest.mark.parametrize('operation', ['modified', 'deleted'])
def test_source_changed_after_preview_rejects_captured_revision(setup, operation):
    app, client, (owner, _, _) = setup
    enable(client, owner); memory = save(client, owner)
    story = card(client, owner, [memory['id']])
    captured = headers(client, owner)
    if operation == 'modified':
        response = client.patch('/memories/' + memory['id'], headers=captured,
                                json={'content': 'Corrected source'})
    else:
        response = deletion(client, owner, mode='selected', ids=[memory['id']], key='after-preview')
    assert response.status_code == 200, response.text
    before = snapshot(app)
    assert patch(client, owner, story, captured).status_code == 409
    assert snapshot(app) == before
    assert client.get('/stories/' + story['id'], headers=auth(owner)).status_code == 404


def test_edit_old_share_key_cannot_revive_and_fresh_preview_can_share(setup):
    app, client, (owner, _, recipient) = setup
    story = card(client, owner); link = family_link(app, owner, recipient)
    captured = headers(client, owner)
    sent = share(client, owner, recipient, story, link=link, captured=captured)
    assert sent.status_code == 201
    edited_response = patch(client, owner, story)
    assert edited_response.status_code == 200, edited_response.text
    edited = edited_response.json()
    assert share(client, owner, recipient, story, link=link, captured=captured).status_code == 409
    assert share(client, owner, recipient, story, link=link).status_code == 409
    assert share(client, owner, recipient, edited, link=link).status_code == 409
    fresh = share(client, owner, recipient, edited, link=link, key='fresh-preview-new-key')
    assert fresh.status_code == 201 and fresh.json()['content'] == 'Edited title\nEdited private card'
    with app.state.session_factory() as db:
        assert db.get(FamilyMessage, sent.json()['id']).content != sent.json()['content']
        assert len(list(db.scalars(select(FamilyMessage)))) == 2


def test_same_text_edit_advances_revision_and_withdraws_share(setup):
    app, client, (owner, _, recipient) = setup
    story = card(client, owner); link = family_link(app, owner, recipient)
    sent = share(client, owner, recipient, story, link=link)
    assert sent.status_code == 201
    revision = state(client, owner)['revision']
    edited = patch(client, owner, story, title=story['title'], content=story['content'])
    assert edited.status_code == 200 and edited.json()['revision'] == revision + 1
    with app.state.session_factory() as db:
        assert db.get(FamilyMessage, sent.json()['id']).content != sent.json()['content']


def test_failed_edit_rolls_back_story_links_shares_and_revision(setup):
    app, client, (owner, _, recipient) = setup
    enable(client, owner); memory = save(client, owner)
    story = card(client, owner, [memory['id']]); link = family_link(app, owner, recipient)
    assert share(client, owner, recipient, story, link=link).status_code == 201
    before = snapshot(app)
    def fail(conn, cursor, statement, parameters, context, executemany):
        if statement.upper().startswith('UPDATE FAMILY_MESSAGES '):
            raise RuntimeError('Synthetic failure after share withdrawal SQL')
    event.listen(app.state.engine, 'after_cursor_execute', fail)
    try:
        assert patch(client, owner, story).status_code == 500
    finally:
        event.remove(app.state.engine, 'after_cursor_execute', fail)
    assert snapshot(app) == before
    assert patch(client, owner, story).status_code == 200


@pytest.mark.parametrize('winner', ['edit', 'share'])
def test_edit_share_owner_lock_serializes_both_winners(setup, winner):
    app, client, (owner, _, recipient) = setup
    story = card(client, owner); link = family_link(app, owner, recipient)
    captured = headers(client, owner)
    held, release, attempted = Event(), Event(), Event()
    sql_prefix = 'UPDATE STORIES ' if winner == 'edit' else 'INSERT INTO FAMILY_MESSAGES '
    def hold(conn, cursor, statement, parameters, context, executemany):
        if statement.upper().startswith(sql_prefix):
            held.set()
            assert release.wait(5), 'Synthetic lock holder was not released'
    def observe(conn, cursor, statement, parameters, context, executemany):
        if statement.strip().upper() == 'BEGIN IMMEDIATE': attempted.set()
    event.listen(app.state.engine, 'after_cursor_execute', hold)
    observing = False
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            edit = lambda: patch(client, owner, story, captured)
            send = lambda: share(client, owner, recipient, story, link=link, captured=captured)
            first = pool.submit(edit if winner == 'edit' else send)
            assert held.wait(3), 'First HTTP mutation never reached its guarded write'
            event.listen(app.state.engine, 'before_cursor_execute', observe); observing = True
            second = pool.submit(send if winner == 'edit' else edit)
            try:
                assert attempted.wait(3), 'Competing HTTP request never attempted owner lock'
                assert not second.done(), 'Second mutation bypassed held owner transaction'
            finally:
                release.set()
            first_response, second_response = first.result(timeout=5), second.result(timeout=5)
            assert first_response.status_code == (200 if winner == 'edit' else 201), first_response.text
            assert second_response.status_code == (409 if winner == 'edit' else 200), second_response.text
    finally:
        release.set()
        event.remove(app.state.engine, 'after_cursor_execute', hold)
        if observing: event.remove(app.state.engine, 'before_cursor_execute', observe)
    with app.state.session_factory() as db:
        assert db.get(Story, story['id']).content == 'Edited private card'
        messages = list(db.scalars(select(FamilyMessage)))
        if winner == 'edit': assert messages == []
        else:
            assert len(messages) == 1 and story['content'] not in messages[0].content


def test_memory_off_keeps_explicit_existing_card_management_and_share(setup):
    app, client, (owner, _, recipient) = setup
    enable(client, owner); memory = save(client, owner)
    story = card(client, owner, [memory['id']]); link = family_link(app, owner, recipient)
    enable(client, owner, False)
    assert client.get('/stories/' + story['id'], headers=auth(owner)).status_code == 200
    assert client.get('/stories', headers=auth(owner)).json()[0]['id'] == story['id']
    edited = patch(client, owner, story)
    assert edited.status_code == 200, edited.text
    assert share(client, owner, recipient, edited.json(), link=link).status_code == 201
    assert create(client, owner, [memory['id']]).status_code == 201
    assert state(client, owner)['enabled'] is False
    assert client.post('/memories/search', headers=auth(owner), json={'query': 'source'}).status_code == 403
    assert client.delete('/stories/' + story['id'], headers=headers(client, owner)).status_code == 204
    assert state(client, owner)['enabled'] is False
