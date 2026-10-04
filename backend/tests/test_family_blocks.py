"""Account-pair block/unblock contracts using only synthetic SQLite data."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import Event, Lock, get_ident

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event, select

from app.models import FamilyInvitation, FamilyLink, Task
from app.collaboration_models import FamilyMessage
from app.family_connection_models import FamilyBlock, FamilyConnectionRequest, FamilyConnectionOperation
from app.task_share_models import TaskShare
from app.care_models import CarePreference
from .test_integration import _headers
from .test_family_requests import requests, create_request, decision
from .test_family_messages import link_accounts, message_preview
from .test_task_sharing import share_request
from .memory_revision_helpers import memory_revision_headers


def block(client, elder, child, *, request_id=None, link_id=None, key='block-one'):
    payload = {'caregiver_id': child['account']['id'], 'client_operation_id': key}
    if request_id is not None:
        payload['request_id'] = request_id
    if link_id is not None:
        payload['link_id'] = link_id
    return client.post('/family-links/blocks', headers=_headers(elder), json=payload)


def unblock(client, elder, child, version=1, key='unblock-one'):
    return client.post(f"/family-links/blocks/{child['account']['id']}/unblock",
        headers=_headers(elder), json={'expected_version': version, 'client_operation_id': key})


def test_pair_block_rejects_pending_request_and_prevents_new_requests(requests):
    app, client, elder, child, other_elder, other_child = requests
    pending = create_request(client, child, elder)
    response = block(client, elder, child, request_id=pending['id'])
    assert response.status_code == 200, response.text
    result = response.json()
    assert result['elder_id'] == elder['account']['id']
    assert result['caregiver_id'] == child['account']['id']
    assert result['active'] is True and result['version'] == 1
    with app.state.session_factory() as db:
        old = db.get(FamilyConnectionRequest, pending['id'])
        assert old.status == 'rejected' and old.version == 2
        assert db.get(FamilyBlock, (elder['account']['id'], child['account']['id'])).active
    denied = client.post('/family-links/requests', headers=_headers(child),
        json={'elder_email': elder['account']['email'], 'client_request_id': 'blocked-new'})
    assert denied.status_code == 400, denied.text
    assert denied.json() == {'detail': 'Unable to create request'}


def test_pair_block_permanently_withdraws_incoming_message_and_preserves_sender_text(requests):
    app, client, elder, child, other_elder, other_child = requests
    link = link_accounts(client, elder, child, ['family_messages'])
    sent = client.post('/family-messages', headers=_headers(elder), json={
        'recipient_id': child['account']['id'], 'content': 'Preserve this original message',
        'client_message_id': 'old-message', **message_preview(link)})
    assert sent.status_code == 201, sent.text
    response = block(client, elder, child, link_id=link['id'])
    assert response.status_code == 200, response.text
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    with app.state.session_factory() as db:
        stored = db.get(FamilyMessage, sent.json()['id'])
        current = db.get(FamilyLink, link['id'])
        assert stored.content == sent.json()['content']
        assert stored.access_revoked_at is not None
        assert current.status == 'revoked'
        assert current.authorization_epoch > link['authorization_epoch']
    history = client.get('/family-messages/sent', headers=_headers(elder))
    assert history.status_code == 200, history.text
    assert history.json()[0]['content'] == sent.json()['content']


@pytest.fixture
def connected(requests):
    app, client, elder, child, other_elder, other_child = requests
    pending = create_request(client, child, elder)
    link = link_accounts(client, elder, child, ['care_tasks', 'family_messages'])
    other_link = link_accounts(client, elder, other_child, ['care_tasks', 'family_messages'])
    invitation = client.post('/family-links/invitations', headers=_headers(elder),
        json={'email': child['account']['email'], 'scopes': ['family_messages']}).json()
    with app.state.session_factory() as db:
        duplicate = FamilyConnectionRequest(elder_id=elder['account']['id'], caregiver_id=child['account']['id'],
            submitted_email=elder['account']['email'], client_request_id='legacy-duplicate',
            expires_at=datetime.now(timezone.utc) + timedelta(days=7))
        task = Task(owner_id=elder['account']['id'], created_by=elder['account']['id'],
            title='Owner private task', description='Owner full private body',
            due_at=datetime(2020, 1, 1, tzinfo=timezone.utc))
        own = Task(owner_id=child['account']['id'], created_by=child['account']['id'],
            title='Caregiver private task', description='Caregiver own body')
        db.add_all([duplicate, task, own, CarePreference(owner_id=child['account']['id'],
            settings={'task_reminders': True, 'quiet_start': '00:00', 'quiet_end': '00:00'})])
        db.commit()
        task_id, own_id, duplicate_id = task.id, own.id, duplicate.id
    for index, current in enumerate((link, other_link)):
        response = client.post(f'/tasks/{task_id}/shares', headers=_headers(elder),
            json=share_request(client, elder, task_id, current['id'], key=f'consent-{index}'))
        assert response.status_code == 201, response.text
    message = client.post('/family-messages', headers=_headers(elder), json={
        'recipient_id': child['account']['id'], 'content': 'Original private ordinary text',
        'client_message_id': 'original', **message_preview(link)})
    assert message.status_code == 201, message.text
    other_message = client.post('/family-messages', headers=_headers(elder), json={
        'recipient_id': other_child['account']['id'], 'content': 'Other pair keep text',
        'client_message_id': 'other-pair', **message_preview(other_link)})
    assert other_message.status_code == 201, other_message.text
    return dict(app=app, client=client, elder=elder, child=child, other_elder=other_elder,
        other_child=other_child, pending=pending, link=link, other_link=other_link,
        invitation=invitation, task_id=task_id, own_id=own_id, duplicate_id=duplicate_id,
        message=message.json(), other_message=other_message.json())


def snapshot(app):
    models = (FamilyBlock, FamilyConnectionOperation, FamilyConnectionRequest, FamilyInvitation,
        FamilyLink, FamilyMessage, Task, TaskShare)
    with app.state.session_factory() as db:
        return {model.__tablename__: sorted([tuple(getattr(row, column.name) for column in model.__table__.columns)
            for row in db.scalars(select(model))], key=repr) for model in models}


def test_block_atomic_withdrawal_preserves_private_owners_and_other_pair(connected):
    data = connected
    app, client, elder, child = (data[key] for key in ('app', 'client', 'elder', 'child'))
    before_task = client.get(f"/tasks/{data['task_id']}", headers=_headers(elder)).json()
    notifications = client.get('/notifications', headers=_headers(child)).json()['notifications']
    assert notifications
    response = block(client, elder, child, link_id=data['link']['id'])
    assert response.status_code == 200, response.text
    assert response.json()['caregiver_email'] == child['account']['email']
    assert response.json()['caregiver_name'] == child['account']['display_name']
    assert response.json()['operation_type'] == 'block' and response.json()['operation_id']
    with app.state.session_factory() as db:
        for request_id in (data['pending']['id'], data['duplicate_id']):
            request = db.get(FamilyConnectionRequest, request_id)
            assert request.status == 'rejected' and request.version == 2
        assert db.get(FamilyInvitation, data['invitation']['id']).status == 'revoked'
        assert db.get(FamilyMessage, data['message']['id']).content == data['message']['content']
        assert db.get(FamilyMessage, data['message']['id']).access_revoked_at is not None
        assert db.get(FamilyMessage, data['other_message']['id']).access_revoked_at is None
        shares = db.scalars(select(TaskShare)).all()
        assert all(share.revoked_at is not None for share in shares if share.family_link_id == data['link']['id'])
        assert all(share.revoked_at is None for share in shares if share.family_link_id == data['other_link']['id'])
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 404
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(elder)).json() == before_task
    assert client.get(f"/tasks/{data['own_id']}", headers=_headers(child)).json()['description'] == 'Caregiver own body'
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(data['other_child'])).status_code == 200
    assert client.get('/notifications', headers=_headers(child)).json()['notifications'] == []
    assert client.patch(f"/notifications/{notifications[0]['id']}", headers=_headers(child),
        json={'status': 'handled'}).status_code == 404
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    assert [row['id'] for row in client.get('/family-messages', headers=_headers(data['other_child'])).json()] == [data['other_message']['id']]


def test_block_unblock_replay_returns_current_state_without_reversing_newer_operations(requests):
    app, client, elder, child, other_elder, other_child = requests
    pending = create_request(client, child, elder)
    first = block(client, elder, child, request_id=pending['id'])
    assert first.status_code == 200, first.text
    unchanged = block(client, elder, child, request_id=pending['id'], key='another-block')
    assert unchanged.status_code == 200 and unchanged.json()['version'] == 1
    cleared = unblock(client, elder, child)
    assert cleared.status_code == 200 and cleared.json()['active'] is False and cleared.json()['version'] == 2
    before = snapshot(app)
    stale_block = block(client, elder, child, request_id=pending['id'])
    assert stale_block.status_code == 200 and stale_block.json()['active'] is False
    assert stale_block.json()['operation_id'] == first.json()['operation_id']
    assert snapshot(app) == before
    reblocked = block(client, elder, child, request_id=pending['id'], key='reblock')
    assert reblocked.status_code == 200 and reblocked.json()['active'] is True and reblocked.json()['version'] == 3
    before = snapshot(app)
    stale_clear = unblock(client, elder, child)
    assert stale_clear.status_code == 200 and stale_clear.json()['active'] is True
    assert stale_clear.json()['operation_id'] == cleared.json()['operation_id']
    assert snapshot(app) == before
    assert unblock(client, elder, child, version=2, key='wrong-version').status_code == 409
    assert unblock(client, elder, child, version=3, key='block-one').status_code == 409
    assert block(client, elder, other_child, request_id=pending['id'], key='block-one').status_code == 409
    assert block(client, elder, child, link_id='different-source', key='block-one').status_code == 409


def test_block_sources_roles_and_owner_list_are_pair_bound(requests):
    app, client, elder, child, other_elder, other_child = requests
    pending = create_request(client, child, elder)
    body = {'caregiver_id': child['account']['id'], 'request_id': pending['id'], 'client_operation_id': 'source'}
    assert client.post('/family-links/blocks', json=body).status_code == 401
    assert client.post('/family-links/blocks', headers=_headers(child), json=body).status_code == 403
    assert client.post('/family-links/blocks', headers=_headers(other_elder), json=body).status_code == 404
    assert block(client, elder, other_child, request_id=pending['id']).status_code == 404
    assert block(client, elder, child, link_id='arbitrary-account-id').status_code == 404
    assert client.post('/family-links/blocks', headers=_headers(elder), json={**body, 'scopes': ['care_tasks']}).status_code == 422
    assert block(client, elder, child).status_code == 422
    assert block(client, elder, child, request_id=pending['id'], link_id='both').status_code == 422
    assert block(client, elder, child, request_id=pending['id']).status_code == 200
    assert client.get('/family-links/blocks').status_code == 401
    assert client.get('/family-links/blocks', headers=_headers(child)).status_code == 403
    assert client.get('/family-links/blocks', headers=_headers(other_elder)).json() == []
    own = client.get('/family-links/blocks', headers=_headers(elder))
    assert own.status_code == 200 and len(own.json()) == 1
    assert own.json()[0]['caregiver_id'] == child['account']['id']
    assert child['account']['email'] not in client.get('/family-links/blocks', headers=_headers(other_elder)).text


def test_unblock_restores_nothing_and_new_approval_only_allows_fresh_shares(connected):
    data = connected
    app, client, elder, child = (data[key] for key in ('app', 'client', 'elder', 'child'))
    assert block(client, elder, child, link_id=data['link']['id']).status_code == 200
    assert unblock(client, elder, child).status_code == 200
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 404
    assert client.post('/family-links/invitations/accept', headers=_headers(child),
        json={'token': data['invitation']['token']}).status_code == 410
    with app.state.session_factory() as db:
        assert db.get(FamilyLink, data['link']['id']).status == 'revoked'
    fresh = create_request(client, child, elder, key='new-after-unblock')
    approved = decision(client, elder, fresh['id'], scopes=['care_tasks', 'family_messages'])
    assert approved.status_code == 200, approved.text
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 404
    old_payload = {'recipient_id': child['account']['id'], 'content': data['message']['content'], 'client_message_id': 'original', **message_preview(approved.json())}
    assert client.post('/family-messages', headers=_headers(elder), json=old_payload).status_code == 410
    new_message = client.post('/family-messages', headers=_headers(elder), json={**old_payload, 'client_message_id': 'new-key'})
    assert new_message.status_code == 201, new_message.text
    shared = client.post(f"/tasks/{data['task_id']}/shares", headers=_headers(elder),
        json=share_request(client, elder, data['task_id'], approved.json()['id'], key='fresh-consent'))
    assert shared.status_code == 201, shared.text
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 200


def test_failure_after_withdrawal_rolls_back_every_dependent_record_and_receipt(connected, monkeypatch):
    from app import family_connection_service
    data = connected
    app, client, elder, child = (data[key] for key in ('app', 'client', 'elder', 'child'))
    before = snapshot(app)
    original = family_connection_service.withdraw_family_access
    def fail_after_withdrawal(db, link, reason):
        original(db, link, reason)
        raise RuntimeError('Synthetic failure after withdrawal')
    with monkeypatch.context() as patch:
        patch.setattr(family_connection_service, 'withdraw_family_access', fail_after_withdrawal)
        with TestClient(app, raise_server_exceptions=False) as failed:
            response = block(failed, elder, child, link_id=data['link']['id'])
            assert response.status_code == 500, response.text
    assert snapshot(app) == before
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 200
    assert block(client, elder, child, link_id=data['link']['id']).status_code == 200


def test_forged_active_block_denies_existing_task_share_and_notifications(connected):
    data = connected
    app, client, elder, child = (data[key] for key in ('app', 'client', 'elder', 'child'))
    notifications = client.get('/notifications', headers=_headers(child)).json()['notifications']
    assert notifications
    payload = share_request(client, elder, data['task_id'], data['link']['id'], key='while-blocked')
    with app.state.session_factory() as db:
        db.add(FamilyBlock(elder_id=elder['account']['id'], caregiver_id=child['account']['id'], active=True))
        db.commit()
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 404
    assert client.get('/notifications', headers=_headers(child)).json()['notifications'] == []
    assert client.patch(f"/notifications/{notifications[0]['id']}", headers=_headers(child), json={'status': 'handled'}).status_code == 404
    assert client.post(f"/tasks/{data['task_id']}/shares", headers=_headers(elder), json=payload).status_code == 403


def test_support_replay_after_epoch_change_and_while_blocked_is_denied(requests):
    app, client, elder, child, other_elder, other_child = requests
    link = link_accounts(client, elder, child, ['family_messages'])
    contact = client.post('/safety/emergency-contacts', headers=_headers(elder),
        json={'family_link_id': link['id'], 'label': 'Family contact'})
    assert contact.status_code == 201, contact.text
    payload = {'emergency_contact_id': contact.json()['id'], 'message': 'Please call me', 'idempotency_key': 'support', **message_preview(link)}
    assert client.post('/safety/support-request', headers=_headers(elder), json=payload).status_code == 200
    assert block(client, elder, child, link_id=link['id']).status_code == 200
    assert client.post('/safety/support-request', headers=_headers(elder), json=payload).status_code == 403
    assert unblock(client, elder, child).status_code == 200
    fresh_link = link_accounts(client, elder, child, ['family_messages'])
    assert client.post('/safety/support-request', headers=_headers(elder), json=payload).status_code == 410
    fresh = client.post('/safety/support-request', headers=_headers(elder), json={**payload, **message_preview(fresh_link), 'idempotency_key': 'fresh-support'})
    assert fresh.status_code == 200, fresh.text


def test_source_card_tombstone_and_pair_withdrawal_never_restore_each_other(requests):
    app, client, elder, child, other_elder, other_child = requests
    link = link_accounts(client, elder, child, ['family_messages'])
    created = client.post('/stories', headers=memory_revision_headers(client, _headers(elder)),
        json={'title': 'Deleted title', 'content': 'Deleted private card body', 'memory_ids': []})
    assert created.status_code == 201, created.text
    story = created.json()
    sent = client.post('/family-messages', headers=memory_revision_headers(client, _headers(elder)),
        json={'recipient_id': child['account']['id'], 'client_message_id': 'deleted-card', **message_preview(link),
            'source_story_id': story['id'], 'content': story['title'] + '\n' + story['content']})
    assert sent.status_code == 201, sent.text
    assert client.delete(f"/stories/{story['id']}", headers=memory_revision_headers(client, _headers(elder))).status_code == 204
    with app.state.session_factory() as db:
        tombstone = db.get(FamilyMessage, sent.json()['id']).content
        assert story['content'] not in tombstone
    assert block(client, elder, child, link_id=link['id']).status_code == 200
    assert unblock(client, elder, child).status_code == 200
    link_accounts(client, elder, child, ['family_messages'])
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    history = client.get('/family-messages/sent', headers=_headers(elder))
    assert history.status_code == 200, history.text
    assert history.json()[0]['content'] == tombstone
    assert history.json()[0]['access_revoked_at'] is not None
    assert story['content'] not in history.text


def test_forged_active_block_denies_safety_support_even_with_live_link(requests):
    app, client, elder, child, other_elder, other_child = requests
    link = link_accounts(client, elder, child, ['family_messages'])
    contact = client.post('/safety/emergency-contacts', headers=_headers(elder),
        json={'family_link_id': link['id'], 'label': 'Live link contact'})
    assert contact.status_code == 201, contact.text
    payload = {'emergency_contact_id': contact.json()['id'], 'message': 'Please call', 'idempotency_key': 'before-block', **message_preview(link)}
    assert client.post('/safety/support-request', headers=_headers(elder), json=payload).status_code == 200
    with app.state.session_factory() as db:
        db.add(FamilyBlock(elder_id=elder['account']['id'], caregiver_id=child['account']['id'], active=True))
        db.commit()
    for key in ('before-block', 'fresh-key'):
        response = client.post('/safety/support-request', headers=_headers(elder), json={**payload, 'idempotency_key': key})
        assert response.status_code == 403, response.text


@pytest.mark.parametrize('first', ['block', 'share'])
@pytest.mark.parametrize('operation', ['accept', 'message', 'card', 'task_share'])
def test_bounded_races_both_guard_orders_end_with_no_access(requests, first, operation):
    app, client, elder, child, other_elder, other_child = requests
    source = create_request(client, child, elder)
    link = None
    task_id = None
    if operation == 'accept':
        invitation = client.post('/family-links/invitations', headers=_headers(elder),
            json={'email': child['account']['email'], 'scopes': ['care_tasks', 'family_messages']}).json()
        share_call = lambda: client.post('/family-links/invitations/accept', headers=_headers(child), json={'token': invitation['token']})
    else:
        link = link_accounts(client, elder, child, ['care_tasks', 'family_messages'])
        if operation == 'task_share':
            with app.state.session_factory() as db:
                task = Task(owner_id=elder['account']['id'], created_by=elder['account']['id'], title='Race task', description='Race body')
                db.add(task)
                db.commit()
                task_id = task.id
            payload = share_request(client, elder, task_id, link['id'], key='race-consent')
            share_call = lambda: client.post(f'/tasks/{task_id}/shares', headers=_headers(elder), json=payload)
        else:
            headers = _headers(elder)
            payload = {'recipient_id': child['account']['id'], 'content': 'Race ordinary text', 'client_message_id': 'race', **message_preview(link)}
            if operation == 'card':
                story = client.post('/stories', headers=memory_revision_headers(client, headers),
                    json={'title': 'Race card', 'content': 'Race private card', 'memory_ids': []})
                assert story.status_code == 201, story.text
                payload.update(source_story_id=story.json()['id'], content=story.json()['title'] + '\n' + story.json()['content'])
                headers = memory_revision_headers(client, headers)
            share_call = lambda: client.post('/family-messages', headers=headers, json=payload)
    block_call = lambda: block(client, elder, child, request_id=source['id'])
    first_locked, second_attempt, release = Event(), Event(), Event()
    mutex = Lock()
    state = {'first_thread': None}
    def before_begin(connection, cursor, statement, parameters, context, executemany):
        if statement.upper().startswith('BEGIN IMMEDIATE'):
            with mutex:
                if state['first_thread'] is None:
                    state['first_thread'] = get_ident()
                elif get_ident() != state['first_thread']:
                    second_attempt.set()
    def after_begin(connection, cursor, statement, parameters, context, executemany):
        if statement.upper().startswith('BEGIN IMMEDIATE') and get_ident() == state['first_thread']:
            first_locked.set()
            assert release.wait(10), 'First writer was not released within the bounded test window'
    event.listen(app.state.engine, 'before_cursor_execute', before_begin)
    event.listen(app.state.engine, 'after_cursor_execute', after_begin)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            winner = pool.submit(block_call if first == 'block' else share_call)
            try:
                assert first_locked.wait(5), 'First route did not reach its SQLite owner guard'
                loser = pool.submit(share_call if first == 'block' else block_call)
                assert second_attempt.wait(5), 'Second route did not contend on the same owner guard'
            finally:
                release.set()
            first_response = winner.result(timeout=10)
            second_response = loser.result(timeout=10)
    finally:
        release.set()
        event.remove(app.state.engine, 'before_cursor_execute', before_begin)
        event.remove(app.state.engine, 'after_cursor_execute', after_begin)
    blocked, shared = (first_response, second_response) if first == 'block' else (second_response, first_response)
    assert blocked.status_code == 200, blocked.text
    if first == 'block':
        assert shared.status_code in (403, 410), shared.text
    else:
        assert shared.status_code in (200, 201), shared.text
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    if task_id:
        assert client.get(f'/tasks/{task_id}', headers=_headers(child)).status_code == 404
    with app.state.session_factory() as db:
        assert db.get(FamilyBlock, (elder['account']['id'], child['account']['id'])).active
        assert all(row.status == 'revoked' for row in db.scalars(select(FamilyLink)))
        assert all(row.revoked_at is not None for row in db.scalars(select(TaskShare)))
        assert all(row.access_revoked_at is not None for row in db.scalars(select(FamilyMessage)))


def test_unblock_of_inconsistent_active_link_does_not_restore_old_access(connected):
    data = connected
    app, client, elder, child = (data[key] for key in ('app', 'client', 'elder', 'child'))
    with app.state.session_factory() as db:
        db.add(FamilyBlock(elder_id=elder['account']['id'], caregiver_id=child['account']['id'], active=True))
        db.commit()
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 404
    cleared = unblock(client, elder, child)
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()['active'] is False
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    assert client.get(f"/tasks/{data['task_id']}", headers=_headers(child)).status_code == 404
    with app.state.session_factory() as db:
        current = db.get(FamilyLink, data['link']['id'])
        old = db.get(FamilyMessage, data['message']['id'])
        assert current.status == 'revoked'
        assert current.authorization_epoch > data['link']['authorization_epoch']
        assert old.access_revoked_at is not None
        assert old.content == data['message']['content']
        assert db.get(Task, data['task_id']).description == 'Owner full private body'
        assert db.get(FamilyMessage, data['other_message']['id']).access_revoked_at is None


@pytest.mark.parametrize('failure_stage', ['request_flush', 'receipt_commit'])
def test_request_unique_conflict_returns_409_and_rolls_back_partial_records(requests, monkeypatch, failure_stage):
    """Synthetic SQL uniqueness injection; does not simulate real PG concurrency."""
    import sqlite3
    from sqlalchemy.exc import IntegrityError
    from sqlalchemy.orm import Session
    app, client, elder, child, other_elder, other_child = requests
    before = snapshot(app)
    method_name = 'flush' if failure_stage == 'request_flush' else 'commit'
    original = getattr(Session, method_name)
    injected = {'count': 0}
    def unique_conflict(db, *args, **kwargs):
        matching = any(isinstance(row, FamilyConnectionRequest) for row in db.new) if failure_stage == 'request_flush' else any(
            isinstance(row, FamilyConnectionOperation) and row.operation_type == 'create_request' for row in db.new)
        if matching:
            injected['count'] += 1
            table = 'family_connection_requests' if failure_stage == 'request_flush' else 'family_connection_operations'
            raise IntegrityError(f'INSERT INTO {table}', {}, sqlite3.IntegrityError('UNIQUE constraint failed: synthetic actor/client key'))
        return original(db, *args, **kwargs)
    with monkeypatch.context() as patch:
        patch.setattr(Session, method_name, unique_conflict)
        with TestClient(app, raise_server_exceptions=False) as failed:
            response = failed.post('/family-links/requests', headers=_headers(child),
                json={'elder_email': elder['account']['email'], 'client_request_id': 'collision'})
            assert response.status_code == 409, response.text
    assert injected['count'] == 1
    assert snapshot(app) == before
