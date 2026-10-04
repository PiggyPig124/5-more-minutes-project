"""Real-route regressions for permanent family-message access withdrawal."""
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import create_app
from app.models import FamilyLink
from app.collaboration_models import FamilyMessage
from .test_integration import _settings, _register, _headers
from .test_family_messages import link_accounts, message_preview


@pytest.fixture
def family(tmp_path):
    app = create_app(_settings(tmp_path / 'withdrawal.db'))
    with TestClient(app) as client:
        elder = _register(client, 'elder@example.test')
        child = _register(client, 'child@example.test', 'caregiver')
        stranger = _register(client, 'stranger@example.test', 'caregiver')
        link = link_accounts(client, elder, child, ['care_tasks', 'family_messages'])
        yield app, client, elder, child, stranger, link


def send(client, sender, recipient, link, key='original', content='Private original text'):
    payload = {'recipient_id': recipient['account']['id'], 'content': content,
               'client_message_id': key, **message_preview(link)}
    response = client.post('/family-messages', headers=_headers(sender), json=payload)
    assert response.status_code == 201, response.text
    return response.json(), payload


def test_reconnect_never_restores_incoming_message_but_preserves_sender_record(family):
    app, client, elder, child, stranger, link = family
    original, payload = send(client, elder, child, link)
    assert len(client.get('/family-messages', headers=_headers(child)).json()) == 1
    assert client.delete(f"/family-links/{link['id']}", headers=_headers(elder)).status_code == 200
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    restored = link_accounts(client, elder, child, ['care_tasks', 'family_messages'])
    assert restored['id'] == link['id']
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    receipts = client.get('/family-messages/sent', headers=_headers(elder))
    assert receipts.status_code == 200, receipts.text
    receipt = next(row for row in receipts.json() if row['id'] == original['id'])
    assert receipt['content'] == payload['content']
    assert receipt['access_revoked_at'] is not None
    assert receipt['access_revocation_reason']
    assert client.get('/family-messages/sent', headers=_headers(child)).json() == []
    assert client.get('/family-messages/sent', headers=_headers(stranger)).json() == []
    with app.state.session_factory() as db:
        stored = db.get(FamilyMessage, original['id'])
        current = db.get(FamilyLink, link['id'])
        assert stored.content == payload['content']
        assert stored.access_revoked_at is not None
        assert stored.link_epoch < current.authorization_epoch


def test_removed_message_scope_never_restores_old_key(family):
    app, client, elder, child, stranger, link = family
    original, payload = send(client, elder, child, link)
    link_accounts(client, elder, child, ['care_tasks'])
    assert client.post('/family-messages', headers=_headers(elder), json=payload).status_code == 403
    restored = link_accounts(client, elder, child, ['care_tasks', 'family_messages'])
    payload.update(message_preview(restored))
    replay = client.post('/family-messages', headers=_headers(elder), json=payload)
    assert replay.status_code == 410, replay.text
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    fresh, _ = send(client, elder, child, restored, key='new-epoch', content='New consent message')
    incoming = client.get('/family-messages', headers=_headers(child)).json()
    assert [row['id'] for row in incoming] == [fresh['id']]
    with app.state.session_factory() as db:
        assert db.get(FamilyMessage, original['id']).content == payload['content']
        assert len(db.scalars(select(FamilyMessage)).all()) == 2


def test_sender_receipts_are_private_even_after_removal(family):
    app, client, elder, child, stranger, link = family
    original, payload = send(client, elder, child, link)
    reply, _ = send(client, child, elder, link, key='reply', content='Child original reply')
    assert client.delete(f"/family-links/{link['id']}", headers=_headers(child)).status_code == 200
    for sender, message in ((elder, original), (child, reply)):
        response = client.get('/family-messages/sent', headers=_headers(sender))
        assert response.status_code == 200, response.text
        assert [row['id'] for row in response.json()] == [message['id']]
        receipt = response.json()[0]
        assert receipt['content'] == message['content']
        assert receipt['access_revoked_at']
        assert not any(key.endswith('email') for key in receipt)
        assert 'recipient_name' not in receipt
        assert client.get('/family-messages', headers=_headers(sender)).json() == []
    assert client.get('/family-messages/sent', headers=_headers(stranger)).json() == []


def test_revoke_one_pair_does_not_withdraw_another_pairs_messages(family):
    app, client, elder, child, stranger, link = family
    other_link = link_accounts(client, elder, stranger, ['family_messages'])
    old, _ = send(client, elder, child, link, key='child')
    unaffected, _ = send(client, elder, stranger, other_link, key='stranger')
    assert client.delete(f"/family-links/{link['id']}", headers=_headers(elder)).status_code == 200
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    assert [row['id'] for row in client.get('/family-messages', headers=_headers(stranger)).json()] == [unaffected['id']]
    with app.state.session_factory() as db:
        assert db.get(FamilyMessage, old['id']).access_revoked_at is not None
        assert db.get(FamilyMessage, unaffected['id']).access_revoked_at is None


def test_live_retry_preserves_one_message_and_changed_payload_conflicts(family):
    app, client, elder, child, stranger, link = family
    original, payload = send(client, elder, child, link)
    replay = client.post('/family-messages', headers=_headers(elder), json=payload)
    assert replay.status_code == 201, replay.text
    assert replay.json()['id'] == original['id']
    changed = client.post('/family-messages', headers=_headers(elder), json={**payload, 'content': 'Changed'})
    assert changed.status_code == 409, changed.text
    with app.state.session_factory() as db:
        stored = db.get(FamilyMessage, original['id'])
        assert stored.link_epoch == db.get(FamilyLink, link['id']).authorization_epoch
        assert stored.access_revoked_at is None
        assert len(db.scalars(select(FamilyMessage)).all()) == 1


def test_withdrawal_service_rolls_back_message_marks_epoch_and_task_shares_together(family):
    from app.family_connection_service import begin_family_guard, withdraw_family_access
    from app.models import Task
    from app.task_share_models import TaskShare
    from .test_task_sharing import share_request
    app, client, elder, child, stranger, link = family
    original, _ = send(client, elder, child, link)
    with app.state.session_factory() as db:
        task = Task(owner_id=elder['account']['id'], created_by=elder['account']['id'], title='Private task')
        db.add(task)
        db.commit()
        task_id = task.id
        epoch = db.get(FamilyLink, link['id']).authorization_epoch
    payload = share_request(client, elder, task_id, link['id'])
    shared = client.post(f'/tasks/{task_id}/shares', headers=_headers(elder), json=payload)
    assert shared.status_code == 201, shared.text
    with app.state.session_factory() as db:
        begin_family_guard(db, elder['account']['id'])
        current = db.get(FamilyLink, link['id'])
        withdraw_family_access(db, current, 'synthetic_rollback')
        db.rollback()
    with app.state.session_factory() as db:
        assert db.get(FamilyLink, link['id']).authorization_epoch == epoch
        assert db.get(FamilyMessage, original['id']).access_revoked_at is None
        assert db.get(TaskShare, shared.json()['id']).revoked_at is None
    assert client.get(f'/tasks/{task_id}', headers=_headers(child)).status_code == 200


def test_deleted_story_card_never_restores_original_in_sender_receipts(family):
    from .memory_revision_helpers import memory_revision_headers
    app, client, elder, child, stranger, link = family
    story = client.post('/stories', headers=memory_revision_headers(client, _headers(elder)),
        json={'title': 'Private card title', 'content': 'Sensitive deleted source body', 'memory_ids': []})
    assert story.status_code == 201, story.text
    card = story.json()
    sent = client.post('/family-messages', headers=memory_revision_headers(client, _headers(elder)),
        json={'recipient_id': child['account']['id'], 'client_message_id': 'source-card', **message_preview(link),
              'source_story_id': card['id'], 'content': card['title'] + '\n' + card['content']})
    assert sent.status_code == 201, sent.text
    deleted = client.delete(f"/stories/{card['id']}", headers=memory_revision_headers(client, _headers(elder)))
    assert deleted.status_code == 204, deleted.text
    with app.state.session_factory() as db:
        tombstone = db.get(FamilyMessage, sent.json()['id']).content
        assert card['content'] not in tombstone
    assert client.delete(f"/family-links/{link['id']}", headers=_headers(elder)).status_code == 200
    link_accounts(client, elder, child, ['family_messages'])
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    response = client.get('/family-messages/sent', headers=_headers(elder))
    assert response.status_code == 200, response.text
    assert response.json()[0]['content'] == tombstone
    assert card['content'] not in response.text
    assert response.json()[0]['access_revoked_at'] is not None


def test_existing_pair_block_prevents_live_message_visibility_and_send(family):
    from app.family_connection_models import FamilyBlock
    app, client, elder, child, stranger, link = family
    original, payload = send(client, elder, child, link)
    with app.state.session_factory() as db:
        db.add(FamilyBlock(elder_id=elder['account']['id'], caregiver_id=child['account']['id'], active=True))
        db.commit()
    for account in (elder, child):
        response = client.get('/family-messages', headers=_headers(account))
        assert response.status_code == 200, response.text
        assert response.json() == []
    replay = client.post('/family-messages', headers=_headers(elder), json=payload)
    assert replay.status_code == 403, replay.text


@pytest.mark.parametrize('revision_mode,expected', [('missing', 422), ('stale', 409)])
def test_live_story_retry_keeps_memory_revision_fence(family, revision_mode, expected):
    from .memory_revision_helpers import memory_revision_headers
    app, client, elder, child, stranger, link = family
    created = client.post('/stories', headers=memory_revision_headers(client, _headers(elder)),
        json={'title': 'Live story', 'content': 'Unchanged private source', 'memory_ids': []})
    assert created.status_code == 201, created.text
    story = created.json()
    current_headers = memory_revision_headers(client, _headers(elder))
    payload = {'recipient_id': child['account']['id'], 'client_message_id': 'live-card-retry', **message_preview(link),
        'source_story_id': story['id'], 'content': story['title'] + '\n' + story['content']}
    sent = client.post('/family-messages', headers=current_headers, json=payload)
    assert sent.status_code == 201, sent.text
    retry_headers = _headers(elder)
    if revision_mode == 'stale':
        retry_headers['X-Memory-Revision'] = str(int(current_headers['X-Memory-Revision']) - 1)
    retry = client.post('/family-messages', headers=retry_headers, json=payload)
    assert retry.status_code == expected, retry.text
    with app.state.session_factory() as db:
        messages = db.scalars(select(FamilyMessage)).all()
        assert len(messages) == 1
        assert messages[0].content == payload['content']
        assert messages[0].access_revoked_at is None
