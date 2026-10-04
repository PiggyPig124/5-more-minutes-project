from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient

from app.main import create_app
from .test_integration import _settings, _register, _headers


def link_accounts(client, elder, caregiver, scopes):
    invitation = client.post('/family-links/invitations', headers=_headers(elder), json={
        'email': caregiver['account']['email'], 'scopes': scopes,
    })
    assert invitation.status_code == 201
    accepted = client.post('/family-links/invitations/accept', headers=_headers(caregiver), json={'token': invitation.json()['token']})
    assert accepted.status_code == 201
    return accepted.json()


def message_preview(link):
    """Wire fields from the link already reviewed by this test; no live lookup."""
    return {'family_link_id': link['id'],
            'expected_authorization_epoch': link['authorization_epoch']}


def test_messages_need_separate_consent_and_revoke_immediately(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'family-chat.db'))) as client:
        elder = _register(client, 'elder@example.test')
        child = _register(client, 'child@example.test', 'caregiver')
        stranger = _register(client, 'stranger@example.test', 'caregiver')
        payload = {'recipient_id': child['account']['id'], 'content': '星期日一齊飲茶？', 'client_message_id': 'one', **message_preview({'id': 'unavailable-link', 'authorization_epoch': 1})}
        assert client.post('/family-messages', headers=_headers(elder), json=payload).status_code == 403
        limited = link_accounts(client, elder, child, ['care_tasks'])
        payload.update(message_preview(limited))
        assert client.post('/family-messages', headers=_headers(elder), json=payload).status_code == 403
        link = link_accounts(client, elder, child, ['care_tasks', 'family_messages'])
        payload.update(message_preview(link))
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda _: client.post('/family-messages', headers=_headers(elder), json=payload), range(2)))
        assert all(response.status_code == 201 for response in responses)
        assert responses[0].json()['id'] == responses[1].json()['id']
        assert len(client.get('/family-messages', headers=_headers(child)).json()) == 1
        assert client.get('/family-messages', headers=_headers(stranger)).json() == []
        reply = {'recipient_id': elder['account']['id'], 'content': '好呀！', 'client_message_id': 'reply', **message_preview(link)}
        assert client.post('/family-messages', headers=_headers(child), json=reply).status_code == 201
        assert len(client.get('/family-messages', headers=_headers(elder)).json()) == 2
        assert client.post('/family-messages', headers=_headers(elder), json={**payload, 'content': 'changed'}).status_code == 409
        client.post(f"/family-links/{link['id']}/revoke", headers=_headers(elder))
        assert client.get('/family-messages', headers=_headers(child)).json() == []
        assert client.post('/family-messages', headers=_headers(child), json=reply).status_code == 403


def test_unknown_scope_and_self_send_rejected(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'scopes.db'))) as client:
        elder = _register(client, 'elder@example.test')
        assert client.post('/family-links/invitations', headers=_headers(elder), json={'email': 'child@example.test', 'scopes': ['private_chat']}).status_code == 422
        assert client.post('/family-messages', headers=_headers(elder), json={'recipient_id': elder['account']['id'], 'content': 'hello', 'client_message_id': 'self', **message_preview({'id': 'unavailable-link', 'authorization_epoch': 1})}).status_code == 403
