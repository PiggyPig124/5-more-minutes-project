"""Synthetic route contracts for caregiver requests and elder-only consent."""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import create_app
from app.models import Account, FamilyInvitation, FamilyLink
from app.family_connection_models import FamilyBlock, FamilyConnectionRequest
from .test_integration import _settings, _register, _headers
from .test_family_messages import link_accounts, message_preview


@pytest.fixture
def requests(tmp_path):
    app = create_app(_settings(tmp_path / 'requests.db'))
    with TestClient(app) as client:
        elder = _register(client, 'elder@example.test')
        child = _register(client, 'child@example.test', 'caregiver')
        other_elder = _register(client, 'other-elder@example.test')
        other_child = _register(client, 'other-child@example.test', 'caregiver')
        yield app, client, elder, child, other_elder, other_child


def create_request(client, child, elder, key='request-one'):
    response = client.post('/family-links/requests', headers=_headers(child),
        json={'elder_email': elder['account']['email'], 'client_request_id': key})
    assert response.status_code == 201, response.text
    return response.json()


def decision(client, elder, request_id, action='approve', version=1, scopes=None):
    payload = {'decision': action, 'expected_version': version}
    if scopes is not None:
        payload['scopes'] = scopes
    return client.post(f'/family-links/requests/{request_id}/decision',
        headers=_headers(elder), json=payload)


def block_pair(app, elder, child):
    with app.state.session_factory() as db:
        db.add(FamilyBlock(elder_id=elder['account']['id'], caregiver_id=child['account']['id'], active=True))
        db.commit()


def test_pending_request_never_grants_scopes_or_message_access(requests):
    app, client, elder, child, other_elder, other_child = requests
    result = create_request(client, child, elder)
    assert result['status'] == 'pending' and result['version'] == 1
    assert result['elder_id'] == elder['account']['id']
    assert result['caregiver_id'] == child['account']['id']
    assert result['elder_email'] == elder['account']['email']
    assert set(result) == {'id', 'elder_id', 'caregiver_id', 'elder_email', 'status', 'version',
                           'created_at', 'expires_at', 'decided_at'}
    duration = datetime.fromisoformat(result['expires_at'].replace('Z', '+00:00')) - datetime.fromisoformat(result['created_at'].replace('Z', '+00:00'))
    assert abs(duration.total_seconds() - timedelta(days=7).total_seconds()) < 2
    assert client.get('/family-links', headers=_headers(child)).json() == []
    assert client.get('/tasks', headers=_headers(child)).json() == []
    assert client.get('/family-messages', headers=_headers(child)).json() == []
    assert client.post('/family-messages', headers=_headers(child), json={
        'recipient_id': elder['account']['id'], 'content': 'Pending cannot send',
        'client_message_id': 'pending', **message_preview({'id': 'unavailable-link', 'authorization_epoch': 1})}).status_code == 403
    with app.state.session_factory() as db:
        assert db.scalars(select(FamilyLink)).all() == []


def test_pending_invitation_accept_rejects_existing_pair_block(requests):
    app, client, elder, child, other_elder, other_child = requests
    invitation = client.post('/family-links/invitations', headers=_headers(elder),
        json={'email': child['account']['email'], 'scopes': ['family_messages']})
    assert invitation.status_code == 201, invitation.text
    block_pair(app, elder, child)
    response = client.post('/family-links/invitations/accept', headers=_headers(child),
        json={'token': invitation.json()['token']})
    assert response.status_code == 403, response.text
    with app.state.session_factory() as db:
        assert db.scalars(select(FamilyLink)).all() == []
        assert db.get(FamilyInvitation, invitation.json()['id']).status == 'pending'


def test_request_replay_reuses_pending_pair_but_different_email_conflicts(requests):
    app, client, elder, child, other_elder, other_child = requests
    first = create_request(client, child, elder)
    for key, email in [('request-one', '  ELDER@EXAMPLE.TEST  '), ('different-key', elder['account']['email'])]:
        retry = client.post('/family-links/requests', headers=_headers(child),
            json={'elder_email': email, 'client_request_id': key})
        assert retry.status_code == 200, retry.text
        assert retry.json() == first
    conflict = client.post('/family-links/requests', headers=_headers(child),
        json={'elder_email': other_elder['account']['email'], 'client_request_id': 'request-one'})
    assert conflict.status_code == 409, conflict.text
    with app.state.session_factory() as db:
        assert len(db.scalars(select(FamilyConnectionRequest)).all()) == 1


@pytest.mark.parametrize('target', ['unknown', 'caregiver', 'self', 'inactive', 'blocked'])
def test_invalid_targets_have_one_generic_failure_without_creating_requests(requests, target):
    app, client, elder, child, other_elder, other_child = requests
    email = elder['account']['email']
    if target == 'unknown':
        email = 'not-registered@example.test'
    elif target == 'caregiver':
        email = other_child['account']['email']
    elif target == 'self':
        email = child['account']['email']
    elif target == 'inactive':
        with app.state.session_factory() as db:
            db.get(Account, elder['account']['id']).is_active = False
            db.commit()
    else:
        block_pair(app, elder, child)
    response = client.post('/family-links/requests', headers=_headers(child),
        json={'elder_email': email, 'client_request_id': 'invalid-target'})
    assert response.status_code == 400, response.text
    assert response.json() == {'detail': 'Unable to create request'}
    with app.state.session_factory() as db:
        assert db.scalars(select(FamilyConnectionRequest)).all() == []


def test_request_roles_authentication_and_caregiver_scopes_are_rejected(requests):
    app, client, elder, child, other_elder, other_child = requests
    body = {'elder_email': elder['account']['email'], 'client_request_id': 'auth'}
    assert client.post('/family-links/requests', json=body).status_code == 401
    assert client.get('/family-links/requests').status_code == 401
    assert client.post('/family-links/requests', headers=_headers(elder), json=body).status_code == 403
    assert client.post('/family-links/requests', headers=_headers(child),
        json={**body, 'scopes': ['family_messages']}).status_code == 422


def test_request_lists_show_only_own_pairs_and_verified_requester_identity(requests):
    app, client, elder, child, other_elder, other_child = requests
    with app.state.session_factory() as db:
        for auth in (child, other_child):
            db.get(Account, auth['account']['id']).display_name = 'Same public name'
        db.commit()
    first = create_request(client, child, elder)
    other = create_request(client, other_child, other_elder)
    incoming = client.get('/family-links/requests', headers=_headers(elder))
    assert incoming.status_code == 200, incoming.text
    assert len(incoming.json()) == 1
    assert incoming.json()[0]['id'] == first['id']
    assert incoming.json()[0]['requester_name'] == 'Same public name'
    assert incoming.json()[0]['requester_email'] == child['account']['email']
    assert other_child['account']['email'] not in incoming.text
    outgoing = client.get('/family-links/requests', headers=_headers(child))
    assert outgoing.status_code == 200, outgoing.text
    assert outgoing.json() == [first]
    assert other_elder['account']['email'] not in outgoing.text
    assert [row['id'] for row in client.get('/family-links/requests', headers=_headers(other_elder)).json()] == [other['id']]


@pytest.mark.parametrize('bad_scopes', [None, [], ['care_tasks', 'care_tasks'], ['unknown']])
def test_approve_requires_explicit_valid_unique_scopes(requests, bad_scopes):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    response = decision(client, elder, created['id'], scopes=bad_scopes)
    assert response.status_code == 422, response.text
    with app.state.session_factory() as db:
        assert db.get(FamilyConnectionRequest, created['id']).status == 'pending'
        assert db.scalars(select(FamilyLink)).all() == []


def test_decision_actor_target_version_and_extra_fields_are_checked(requests):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    assert decision(client, child, created['id'], scopes=['family_messages']).status_code == 403
    assert decision(client, other_elder, created['id'], scopes=['family_messages']).status_code == 404
    assert decision(client, elder, 'does-not-exist', scopes=['family_messages']).status_code == 404
    assert decision(client, elder, created['id'], version=99, scopes=['family_messages']).status_code == 409
    url = f"/family-links/requests/{created['id']}/decision"
    body = {'decision': 'approve', 'expected_version': 1, 'scopes': ['family_messages']}
    assert client.post(url, json=body).status_code == 401
    assert client.post(url, headers=_headers(elder), json={**body, 'caregiver_id': other_child['account']['id']}).status_code == 422
    with app.state.session_factory() as db:
        record = db.get(FamilyConnectionRequest, created['id'])
        assert record.status == 'pending' and record.version == 1
        assert db.scalars(select(FamilyLink)).all() == []


def test_approve_creates_only_selected_scope_and_replays_original_epoch(requests):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    accepted = decision(client, elder, created['id'], scopes=['family_messages'])
    assert accepted.status_code == 200, accepted.text
    link = accepted.json()
    assert link['elder_id'] == elder['account']['id']
    assert link['caregiver_id'] == child['account']['id']
    assert link['scopes'] == ['family_messages']
    assert link['authorization_epoch'] >= 1
    replay = decision(client, elder, created['id'], scopes=['family_messages'])
    assert replay.status_code == 200, replay.text
    assert replay.json() == link
    assert decision(client, elder, created['id'], scopes=['care_tasks']).status_code == 409
    assert client.post('/family-messages', headers=_headers(child), json={
        'recipient_id': elder['account']['id'], 'content': 'Approved explicit message permission',
        'client_message_id': 'approved', **message_preview(link)}).status_code == 201
    with app.state.session_factory() as db:
        record = db.get(FamilyConnectionRequest, created['id'])
        assert record.status == 'approved' and record.version == 2
        assert record.approved_epoch == link['authorization_epoch']
        assert len(db.scalars(select(FamilyLink)).all()) == 1


@pytest.mark.parametrize('change', ['remove', 'reconnect', 'block'])
def test_approved_request_replay_never_recovers_ended_authorization(requests, change):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    accepted = decision(client, elder, created['id'], scopes=['family_messages'])
    assert accepted.status_code == 200, accepted.text
    if change == 'block':
        block_pair(app, elder, child)
    else:
        assert client.delete(f"/family-links/{accepted.json()['id']}", headers=_headers(elder)).status_code == 200
        if change == 'reconnect':
            link_accounts(client, elder, child, ['family_messages'])
    assert decision(client, elder, created['id'], scopes=['family_messages']).status_code == 410


def test_reject_replay_is_terminal_and_new_request_uses_a_new_id(requests):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    rejected = decision(client, elder, created['id'], action='reject')
    assert rejected.status_code == 200, rejected.text
    assert rejected.json()['status'] == 'rejected' and rejected.json()['version'] == 2
    repeated = decision(client, elder, created['id'], action='reject', scopes=[])
    assert repeated.status_code == 200, repeated.text
    assert repeated.json() == rejected.json()
    assert decision(client, elder, created['id'], scopes=['family_messages']).status_code == 410
    fresh = create_request(client, child, elder, key='after-rejection')
    assert fresh['id'] != created['id'] and fresh['status'] == 'pending'
    with app.state.session_factory() as db:
        assert len(db.scalars(select(FamilyConnectionRequest)).all()) == 2
        assert db.scalars(select(FamilyLink)).all() == []


def test_reject_cannot_include_permissions(requests):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    assert decision(client, elder, created['id'], action='reject', scopes=['family_messages']).status_code == 422


@pytest.mark.parametrize('terminal', ['expired', 'unknown'])
def test_expired_or_unknown_requests_cannot_be_approved(requests, terminal):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    with app.state.session_factory() as db:
        record = db.get(FamilyConnectionRequest, created['id'])
        if terminal == 'expired':
            record.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
        else:
            record.status = 'unknown'
        db.commit()
    assert decision(client, elder, created['id'], scopes=['family_messages']).status_code == 410
    with app.state.session_factory() as db:
        assert db.get(FamilyConnectionRequest, created['id']).status == terminal
        assert db.scalars(select(FamilyLink)).all() == []


def test_active_pair_cannot_create_another_request(requests):
    app, client, elder, child, other_elder, other_child = requests
    link_accounts(client, elder, child, ['family_messages'])
    response = client.post('/family-links/requests', headers=_headers(child),
        json={'elder_email': elder['account']['email'], 'client_request_id': 'active'})
    assert response.status_code == 409, response.text
    with app.state.session_factory() as db:
        assert db.scalars(select(FamilyConnectionRequest)).all() == []


def test_request_withdrawal_is_caregiver_only_versioned_and_idempotent(requests):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    url = f"/family-links/requests/{created['id']}/withdraw"
    body = {'expected_version': 1}
    assert client.post(url, json=body).status_code == 401
    assert client.post(url, headers=_headers(elder), json=body).status_code == 403
    assert client.post(url, headers=_headers(other_child), json=body).status_code == 404
    assert client.post(url, headers=_headers(child), json={'expected_version': 99}).status_code == 409
    withdrawn = client.post(url, headers=_headers(child), json=body)
    assert withdrawn.status_code == 200, withdrawn.text
    assert withdrawn.json()['status'] == 'revoked' and withdrawn.json()['version'] == 2
    repeated = client.post(url, headers=_headers(child), json=body)
    assert repeated.status_code == 200, repeated.text
    assert repeated.json() == withdrawn.json()
    assert decision(client, elder, created['id'], scopes=['family_messages']).status_code == 410


def test_approved_request_cannot_be_withdrawn_as_pending(requests):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder)
    assert decision(client, elder, created['id'], scopes=['family_messages']).status_code == 200
    response = client.post(f"/family-links/requests/{created['id']}/withdraw",
        headers=_headers(child), json={'expected_version': 1})
    assert response.status_code == 410, response.text


def test_new_invitation_for_blocked_target_is_rejected(requests):
    app, client, elder, child, other_elder, other_child = requests
    block_pair(app, elder, child)
    response = client.post('/family-links/invitations', headers=_headers(elder),
        json={'email': child['account']['email'], 'scopes': ['family_messages']})
    assert response.status_code == 403, response.text
    with app.state.session_factory() as db:
        assert db.scalars(select(FamilyInvitation)).all() == []


@pytest.mark.parametrize('alias', ['token', 'invitation', 'short'])
@pytest.mark.parametrize('status', ['unknown', 'rejected', 'revoked', 'expired'])
def test_all_invitation_accept_aliases_reject_terminal_or_unknown_status(requests, alias, status):
    app, client, elder, child, other_elder, other_child = requests
    invitation = client.post('/family-links/invitations', headers=_headers(elder),
        json={'email': child['account']['email'], 'scopes': ['family_messages']}).json()
    with app.state.session_factory() as db:
        db.get(FamilyInvitation, invitation['id']).status = status
        db.commit()
    paths = {'token': '/family-links/invitations/accept',
        'invitation': f"/family-links/invitations/{invitation['id']}/accept",
        'short': f"/family-links/{invitation['id']}/accept"}
    response = client.post(paths[alias], headers=_headers(child), json={'token': invitation['token']})
    assert response.status_code == 410, response.text
    with app.state.session_factory() as db:
        assert db.scalars(select(FamilyLink)).all() == []


@pytest.mark.parametrize('alias', ['token', 'invitation', 'short'])
def test_all_accepted_invitation_aliases_are_fenced_after_reconnect(requests, alias):
    app, client, elder, child, other_elder, other_child = requests
    invitation = client.post('/family-links/invitations', headers=_headers(elder),
        json={'email': child['account']['email'], 'scopes': ['family_messages']}).json()
    accepted = client.post('/family-links/invitations/accept', headers=_headers(child),
        json={'token': invitation['token']})
    assert accepted.status_code == 201, accepted.text
    assert client.delete(f"/family-links/{accepted.json()['id']}", headers=_headers(elder)).status_code == 200
    link_accounts(client, elder, child, ['family_messages'])
    paths = {'token': '/family-links/invitations/accept',
        'invitation': f"/family-links/invitations/{invitation['id']}/accept",
        'short': f"/family-links/{invitation['id']}/accept"}
    assert client.post(paths[alias], headers=_headers(child), json={'token': invitation['token']}).status_code == 410


def test_elder_invitation_success_keeps_token_out_of_storage_and_lists(requests):
    app, client, elder, child, other_elder, other_child = requests
    response = client.post('/family-links/invitations', headers=_headers(elder),
        json={'email': child['account']['email'], 'scopes': ['family_messages']})
    assert response.status_code == 201, response.text
    invitation = response.json()
    with app.state.session_factory() as db:
        stored = db.get(FamilyInvitation, invitation['id'])
        assert stored.token_digest != invitation['token'] and len(stored.token_digest) == 64
    for actor in (elder, child):
        listed = client.get('/family-links/invitations', headers=_headers(actor))
        assert listed.status_code == 200, listed.text
        assert invitation['token'] not in listed.text
    accepted = client.post('/family-links/invitations/accept', headers=_headers(child),
        json={'token': invitation['token']})
    assert accepted.status_code == 201, accepted.text
    assert accepted.json()['caregiver_id'] == child['account']['id']


@pytest.mark.parametrize('retry_target', ['same', 'different_registered', 'unknown'])
def test_deduplicated_request_key_stays_bound_after_request_becomes_terminal(requests, retry_target):
    app, client, elder, child, other_elder, other_child = requests
    created = create_request(client, child, elder, key='original-key')
    alias = client.post('/family-links/requests', headers=_headers(child),
        json={'elder_email': elder['account']['email'], 'client_request_id': 'alias-key'})
    assert alias.status_code == 200, alias.text
    assert alias.json()['id'] == created['id']
    rejected = decision(client, elder, created['id'], action='reject')
    assert rejected.status_code == 200, rejected.text
    email = {'same': elder['account']['email'],
        'different_registered': other_elder['account']['email'],
        'unknown': 'never-registered@example.test'}[retry_target]
    retry = client.post('/family-links/requests', headers=_headers(child),
        json={'elder_email': email, 'client_request_id': 'alias-key'})
    if retry_target == 'same':
        assert retry.status_code == 200, retry.text
        assert retry.json()['id'] == created['id']
        assert retry.json()['status'] == 'rejected' and retry.json()['version'] == 2
    else:
        assert retry.status_code == 409, retry.text
    with app.state.session_factory() as db:
        assert len(db.scalars(select(FamilyConnectionRequest)).all()) == 1
