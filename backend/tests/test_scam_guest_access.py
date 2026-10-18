"""Public scam guidance is available without creating personal history."""
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.config import Settings
from app.main import create_app
from app.models import Account, Conversation, Message
from app.scam_models import ScamLog


@pytest.fixture
def scam_client(tmp_path):
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path / 'scam.db'}",
                              auth_secret="synthetic-scam-test", demo_mode=True))
    with TestClient(app) as client:
        yield app, client


@pytest.mark.parametrize("signed_in", [False, True])
def test_public_guidance_browse_search_detail_actions_contacts(scam_client, signed_in):
    app, client = scam_client
    headers = {}
    if signed_in:
        auth = client.post('/auth/register', json={
            'email': 'scam-test@example.test', 'password': 'synthetic-test-password',
            'display_name': 'Synthetic elder', 'role': 'elder',
        })
        assert auth.status_code == 201
        headers = {'Authorization': f"Bearer {auth.json()['access_token']}"}
    resources = client.get('/scam/resources', headers=headers)
    assert resources.status_code == 200
    first = resources.json()['resources'][0]
    detail = client.get(f"/scam/resources/{first['id']}", headers=headers)
    assert detail.status_code == 200
    assert detail.json() == first
    search = client.get('/scam/resources/search', params={'query': first['title']}, headers=headers)
    assert search.status_code == 200
    assert first['id'] in [r['id'] for r in search.json()['results']]
    actions = client.get('/scam/verify-actions', headers=headers)
    assert actions.status_code == 200
    assert len(actions.json()['actions']) == 3
    contacts = client.get('/scam/contacts', headers=headers)
    assert contacts.status_code == 200
    assert contacts.json()['contacts']
    assert all(c['id'] and c['url'].startswith('https://') for c in contacts.json()['contacts'])
    assert all(bool(c['phone']) == c['callable'] for c in contacts.json()['contacts'])
    assert client.get('/scam/resources/missing', headers=headers).status_code == 404
    with app.state.session_factory() as db:
        assert db.scalar(select(func.count()).select_from(Account)) == int(signed_in)
        for model in (Conversation, Message, ScamLog):
            assert db.scalar(select(func.count()).select_from(model)) == 0


def test_standard_three_actions_include_all_required_safety_in_both_languages(scam_client):
    _, client = scam_client
    # Authentication here isolates the content regression from guest accessibility.
    auth = client.post('/auth/register', json={
        'email': 'content@example.test', 'password': 'synthetic-test-password',
        'display_name': 'Synthetic elder',
    }).json()
    actions = client.get('/scam/verify-actions', headers={
        'Authorization': f"Bearer {auth['access_token']}"}).json()['actions']
    assert [a['step'] for a in actions] == [1, 2, 3]
    english = ' '.join(a['description_en'] for a in actions).lower()
    chinese = ' '.join(a['description'] for a in actions)
    for phrase in ('pressure', 'do not transfer money', 'passwords', 'personal information',
                   'independently', 'official', 'trusted'):
        assert phrase in english
    for phrase in ('暫停', '不要轉帳', '密碼', '個人資料', '獨立', '官方', '信任'):
        assert phrase in chinese
    assert [a['action'] for a in actions] == ['pause', 'protect', 'verify']


def test_guest_cannot_read_or_write_private_guidance_history(scam_client):
    app, client = scam_client
    assert client.get('/scam/log').status_code == 401
    assert client.post('/scam/log', json={'guidance_summary': 'Synthetic only'}).status_code == 401
    with app.state.session_factory() as db:
        assert db.scalar(select(func.count()).select_from(ScamLog)) == 0


def test_signed_in_history_remains_private_and_never_notifies_family(scam_client):
    _, client = scam_client
    tokens = []
    for i in range(2):
        auth = client.post('/auth/register', json={
            'email': f'history-{i}@example.test', 'password': 'synthetic-test-password',
            'display_name': 'Synthetic elder', 'role': 'elder',
        })
        tokens.append({'Authorization': f"Bearer {auth.json()['access_token']}"})
    logged = client.post('/scam/log', json={'guidance_summary': 'Synthetic only'}, headers=tokens[0])
    assert logged.status_code == 201
    assert logged.json()['family_notified'] is False
    assert client.get('/scam/log', headers=tokens[0]).json()['count'] == 1
    assert client.get('/scam/log', headers=tokens[1]).json()['logs'] == []
