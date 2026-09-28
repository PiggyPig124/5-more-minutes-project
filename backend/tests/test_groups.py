"""Human group chat permissions, invitation boundaries, and message isolation."""

from fastapi.testclient import TestClient

from app.main import create_app
from .test_integration import _headers, _register, _settings


def _group(client, owner):
    created = client.post('/groups', headers=_headers(owner), json={'title': 'Neighbourhood recipes'})
    assert created.status_code == 201, created.text
    return created.json()['id']


def _invite(client, owner, group_id, email):
    response = client.post(f'/groups/{group_id}/invitations', headers=_headers(owner), json={'email': email})
    assert response.status_code == 201, response.text
    return response.json()['id']


def _accept(client, invitee, invitation_id):
    response = client.post(f'/groups/invitations/{invitation_id}/accept', headers=_headers(invitee))
    assert response.status_code == 200, response.text


def test_invitation_only_messages_and_private_chat_isolation(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'human-groups.db'))) as client:
        owner = _register(client, 'owner@example.test')
        neighbour = _register(client, 'neighbour@example.test')
        stranger = _register(client, 'stranger@example.test')
        group_id = _group(client, owner)
        private_id = client.post('/conversations', headers=_headers(owner), json={}).json()['id']
        client.post(f'/conversations/{private_id}/messages', headers=_headers(owner),
                    json={'content': 'Private medical detail', 'client_message_id': 'private-1'})
        before = client.post(f'/groups/{group_id}/messages', headers=_headers(owner),
                             json={'content': 'Welcome', 'client_message_id': 'g-1'})
        assert before.status_code == 201
        assert client.get(f'/groups/{group_id}/messages', headers=_headers(neighbour)).status_code == 404
        invitation_id = _invite(client, owner, group_id, 'neighbour@example.test')
        assert client.get(f'/groups/{group_id}/members', headers=_headers(stranger)).status_code == 404
        assert client.get(f'/groups/{group_id}/messages', headers=_headers(neighbour)).status_code == 404
        assert len(client.get('/groups/invitations', headers=_headers(neighbour)).json()) == 1
        assert client.post(f'/groups/invitations/{invitation_id}/accept',
                           headers=_headers(stranger)).status_code == 404
        _accept(client, neighbour, invitation_id)
        assert client.get(f'/groups/{group_id}/messages', headers=_headers(neighbour)).json() == []
        assert client.post(f'/groups/{group_id}/reports', headers=_headers(neighbour),
                           json={'message_id': before.json()['id'],
                                 'reason': 'A message from before joining'}).status_code == 404
        sent = client.post(f'/groups/{group_id}/messages', headers=_headers(neighbour),
                           json={'content': 'I can bring a recipe', 'client_message_id': 'g-2'})
        assert sent.status_code == 201, sent.text
        own_history = client.get(f'/groups/{group_id}/messages', headers=_headers(owner)).json()
        assert [row['content'] for row in own_history] == ['Welcome', 'I can bring a recipe']
        assert 'Private medical detail' not in str(own_history)
        assert client.get(f'/conversations/{private_id}', headers=_headers(neighbour)).status_code == 403
        assert client.get(f'/groups/{group_id}/messages', headers=_headers(stranger)).status_code == 404


def test_leave_rejoin_only_sees_new_messages_and_retries_are_idempotent(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'group-rejoin.db'))) as client:
        owner = _register(client, 'owner2@example.test')
        member = _register(client, 'member2@example.test')
        group_id = _group(client, owner)
        _accept(client, member, _invite(client, owner, group_id, 'member2@example.test'))
        payload = {'content': 'First', 'client_message_id': 'retry-1'}
        first = client.post(f'/groups/{group_id}/messages', headers=_headers(owner), json=payload)
        assert first.status_code == 201
        replay = client.post(f'/groups/{group_id}/messages', headers=_headers(owner), json=payload)
        assert replay.status_code == 201 and replay.json()['id'] == first.json()['id']
        assert client.post(f'/groups/{group_id}/messages', headers=_headers(owner),
                           json={'content': 'Changed', 'client_message_id': 'retry-1'}).status_code == 409
        client.post(f'/groups/{group_id}/messages', headers=_headers(member),
                    json={'content': 'Before leaving', 'client_message_id': 'member-old'})
        assert client.post(f'/groups/{group_id}/leave', headers=_headers(member)).status_code == 204
        assert client.get(f'/groups/{group_id}/messages', headers=_headers(member)).status_code == 404
        client.post(f'/groups/{group_id}/messages', headers=_headers(owner),
                    json={'content': 'While away', 'client_message_id': 'retry-2'})
        _accept(client, member, _invite(client, owner, group_id, 'member2@example.test'))
        assert client.get(f'/groups/{group_id}/messages', headers=_headers(member)).json() == []
        assert client.post(f'/groups/{group_id}/messages', headers=_headers(member),
                           json={'content': 'Before leaving',
                                 'client_message_id': 'member-old'}).status_code == 409
        client.post(f'/groups/{group_id}/messages', headers=_headers(owner),
                    json={'content': 'After return', 'client_message_id': 'retry-3'})
        assert [row['content'] for row in client.get(f'/groups/{group_id}/messages',
                headers=_headers(member)).json()] == ['After return']


def test_invites_block_report_and_close(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'group-controls.db'))) as client:
        owner = _register(client, 'owner3@example.test')
        member = _register(client, 'member3@example.test')
        outsider = _register(client, 'outsider3@example.test')
        group_id = _group(client, owner)
        assert client.post(f'/groups/{group_id}/invitations', headers=_headers(outsider),
                           json={'email': 'member3@example.test'}).status_code == 404
        invitation_id = _invite(client, owner, group_id, 'member3@example.test')
        assert client.post(f'/groups/invitations/{invitation_id}/decline',
                           headers=_headers(member)).status_code == 204
        _accept(client, member, _invite(client, owner, group_id, 'member3@example.test'))
        report = client.post(f'/groups/{group_id}/reports', headers=_headers(member),
                             json={'reason': 'This message is unsafe'})
        assert report.status_code == 201 and report.json()['status'] == 'recorded'
        assert client.post(f'/groups/{group_id}/reports', headers=_headers(outsider),
                           json={'reason': 'Not mine'}).status_code == 404
        assert client.post('/groups/blocks', headers=_headers(outsider),
                           json={'account_id': owner['account']['id']}).status_code == 201
        assert client.post(f'/groups/{group_id}/invitations', headers=_headers(owner),
                           json={'email': 'outsider3@example.test'}).status_code == 403
        assert client.post(f'/groups/{group_id}/close', headers=_headers(member)).status_code == 403
        assert client.post(f'/groups/{group_id}/close', headers=_headers(owner)).status_code == 204
        assert client.get(f'/groups/{group_id}/messages', headers=_headers(member)).status_code == 404
