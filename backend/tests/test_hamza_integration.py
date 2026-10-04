"""Cross-feature regressions for the merged application."""
from .memory_revision_helpers import memory_revision_headers
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import create_app
from app.care_models import CareNotification, CarePreference
from app.collaboration_models import FamilyMessage
from app.memory_models import MemoryConsent, PersonalMemory
from app.community_models import CommunitySkill
from app.models import FamilyLink, Task
from app.activity_catalog_models import CommunityActivity
from app.care_service import collect_notifications
import app.routers.check_ins as check_ins
from .test_safety_checkin_speech import _settings, _register, _headers


@pytest.fixture
def setup(tmp_path):
    app = create_app(_settings(tmp_path / 'integrated.db'))
    with TestClient(app) as client:
        elder = _register(client, 'merged@example.test')
        other = _register(client, 'other@example.test')
        caregiver = _register(client, 'caregiver@example.test', 'caregiver')
        yield app, client, elder, other, caregiver


def test_care_preferences_persist_for_both_roles_and_validate(setup):
    app, client, elder, other, caregiver = setup
    settings = dict(enabled=False, task_reminders=True, family_replies=True,
                    quiet_start='22:30', quiet_end='08:15', paused_until='2026-10-10T00:00:00Z')
    for auth in (elder, caregiver):
        response = client.put('/check-ins/schedule', headers=_headers(auth), json=settings)
        assert response.status_code == 200, response.text
        loaded = client.get('/check-ins/schedule', headers=_headers(auth)).json()
        for field in settings:
            assert loaded[field] == settings[field]
    assert client.get('/check-ins/schedule', headers=_headers(other)).json() is None
    assert client.put('/check-ins/schedule', headers=_headers(caregiver), json={'enabled': True}).status_code == 403
    assert client.put('/check-ins/schedule', headers=_headers(elder), json={'quiet_start': '29:00'}).status_code == 422


@pytest.mark.parametrize('overrides', [
    {'enabled': False}, {'paused_until': '2030-01-01T00:00:00Z'},
    {'skip_date': '2026-10-03'}, {'quiet_start': '11:00', 'quiet_end': '13:00'},
    {'check_in_time': '14:00'}, {'frequency': 'weekly', 'weekday': 7},
])
def test_cloud_checkin_respects_all_suppression_settings(setup, overrides):
    app, client, elder, *_ = setup
    headers = _headers(elder)
    client.put('/check-ins/schedule', headers=headers, json={'enabled': True, **overrides})
    with patch.object(check_ins, 'datetime') as clock:
        clock.now.return_value = datetime(2026, 10, 3, 4, 0, tzinfo=timezone.utc)
        clock.combine.side_effect = datetime.combine
        assert client.post('/check-ins/trigger', headers=headers, json={}).json()['triggered'] is False
    assert client.get('/conversations', headers=headers).json() == []


def test_skip_endpoint_and_successful_chat_suppress_cloud_greeting(setup):
    app, client, elder, *_ = setup
    headers = _headers(elder)
    client.put('/check-ins/schedule', headers=headers, json={'enabled': True})
    skip = client.post('/check-ins/skip', headers=headers)
    assert skip.status_code == 200 and skip.json()['skip_date']
    conversation = client.post('/conversations', headers=headers, json={}).json()
    assert client.post(f"/conversations/{conversation['id']}/messages", headers=headers,
                       json={'content': 'Hello', 'client_message_id': 'hello'}).status_code == 200
    with patch.object(check_ins, 'datetime') as clock:
        now = datetime.now(timezone.utc)
        clock.now.return_value = now.replace(hour=4)
        clock.combine.side_effect = datetime.combine
        assert client.post('/check-ins/trigger', headers=headers, json={}).json()['triggered'] is False


def test_task_and_family_inbox_dedup_owner_and_revoke(setup):
    app, client, elder, other, caregiver = setup
    headers = _headers(elder)
    client.put('/check-ins/schedule', headers=headers,
               json={'task_reminders': True, 'family_replies': True, 'quiet_start': '00:00', 'quiet_end': '00:00'})
    with app.state.session_factory() as db:
        from app.models import Account
        elder_id, caregiver_id = elder['account']['id'], caregiver['account']['id']
        task = Task(owner_id=elder_id, created_by=elder_id, title='Due task', due_at=datetime.now(timezone.utc)-timedelta(minutes=1))
        link = FamilyLink(elder_id=elder_id, caregiver_id=caregiver_id, scopes=['family_messages'])
        db.add_all([task, link]); db.flush()
        message = FamilyMessage(link_id=link.id, sender_id=caregiver_id, recipient_id=elder_id,
                                content='Private family message', client_message_id='family-1')
        db.add(message); db.commit()
        collect_notifications(db, db.get(Account, elder_id))
        collect_notifications(db, db.get(Account, elder_id))
    items = client.get('/notifications', headers=headers).json()['notifications']
    assert {item['kind'] for item in items} == {'task_reminder', 'family_reply'}
    assert len(items) == 2 and all('Private family message' not in item['body'] for item in items)
    item = items[0]
    assert client.patch(f"/notifications/{item['id']}", headers=_headers(other), json={'status':'handled'}).status_code == 404
    assert client.patch(f"/notifications/{item['id']}", headers=headers, json={'status':'handled'}).json()['status'] == 'handled'
    with app.state.session_factory() as db:
        db.get(FamilyLink, link.id).status = 'revoked'; db.commit()
    visible = client.get('/notifications', headers=headers).json()['notifications']
    assert len(visible) == 1 and visible[0]['kind'] == 'task_reminder'


def test_catalog_consent_skill_confirmation_and_interest(setup):
    app, client, elder, other, *_ = setup
    headers = _headers(elder)
    elder_id = elder['account']['id']
    with app.state.session_factory() as db:
        memory = PersonalMemory(owner_id=elder_id, content='calligraphy', kind='fact', status='confirmed')
        db.add(memory); db.flush()
        activity = CommunityActivity(id='integration-calligraphy', title='Calligraphy', description='Class',
            organizer='Test', district='Test', skill_tags=['calligraphy'], verified=True)
        skill = CommunitySkill(owner_id=elder_id, memory_id=memory.id, suggestion='calligraphy', status='suggested')
        db.add_all([activity, skill]); db.commit()
    assert client.get('/community/catalog/recommendations', headers=headers).json()['basis'] == 'general'
    with app.state.session_factory() as db:
        db.add(MemoryConsent(owner_id=elder_id, enabled=True)); db.commit()
    result = client.get('/community/catalog/recommendations', headers=headers).json()
    assert 'integration-calligraphy' not in [a['id'] for a in result['recommendations']]
    with app.state.session_factory() as db:
        db.get(CommunitySkill, skill.id).status='confirmed'; db.commit()
    matched = next(row for row in client.get('/community/catalog/recommendations', headers=headers).json()['recommendations'] if row['id'] == activity.id)
    assert matched['recommendation_basis'] == 'memory'
    assert matched['recommendation_reasons'] == [{'memory_id': memory.id, 'source_type': 'skill', 'source_text': 'calligraphy', 'matched_tag': 'calligraphy'}]
    assert client.post(f'/community/catalog/interest/{activity.id}', headers=headers).status_code == 201
    assert client.get('/community/catalog/interests', headers=_headers(other)).json()['count'] == 0
    assert client.delete(f'/community/catalog/interest/{activity.id}', headers=headers).status_code == 200
    with app.state.session_factory() as db:
        db.get(MemoryConsent, elder_id).enabled=False; db.commit()
    result = client.get('/community/catalog/recommendations', headers=headers).json()
    assert result['basis'] == 'general' and result['memory_matches'] == 0


def test_catalog_examples_hidden_outside_demo_and_scam_conversation_owned(setup):
    app, client, elder, other, *_ = setup
    headers = _headers(elder)
    examples = client.get('/community/catalog/activities', headers=headers).json()['activities']
    assert examples and all(not row['verified'] for row in examples)
    app.state.settings.demo_mode=False
    assert client.get('/community/catalog/activities', headers=headers).json()['activities'] == []
    conversation = client.post('/conversations', headers=_headers(other), json={}).json()
    assert client.post('/scam/log', headers=headers,
        json={'conversation_id':conversation['id'], 'scam_type':'general'}).status_code == 404
    assert client.post('/scam/log', headers=headers, json={'scam_type':'general', 'guidance_summary':'Reviewed'}).status_code == 201
    assert client.get('/scam/log', headers=headers).json()['count'] == 1


def test_checkin_rechecks_pause_after_model_response(setup):
    from app.llm import AgentReply
    app, client, elder, *_ = setup
    headers = _headers(elder)
    client.put('/check-ins/schedule', headers=headers, json={'enabled': True})

    async def reply(context, message):
        with app.state.session_factory() as db:
            pref = db.get(CarePreference, elder['account']['id'])
            pref.settings = {**pref.settings, 'paused_until': '2030-01-01T00:00:00Z'}
            db.commit()
        return AgentReply(text='A greeting', proposed_task=None, mode='deterministic_demo')

    app.state.orchestrator.run = reply
    with patch.object(check_ins, 'datetime') as clock:
        clock.now.return_value = datetime(2026, 10, 3, 4, 0, tzinfo=timezone.utc)
        clock.combine.side_effect = datetime.combine
        assert client.post('/check-ins/trigger', headers=headers, json={}).json()['triggered'] is False
    assert client.get('/notifications', headers=headers).json()['notifications'] == []


def test_memory_deletion_scrubs_checkin_and_inbox(setup, monkeypatch):
    from app.llm import AgentReply
    import app.memory_service as memory_service
    app, client, elder, *_ = setup
    headers = _headers(elder)
    elder_id = elder['account']['id']
    with app.state.session_factory() as db:
        memory = PersonalMemory(owner_id=elder_id, content='Favorite tea is jasmine', kind='preference', status='confirmed')
        db.add_all([memory, MemoryConsent(owner_id=elder_id, enabled=True)]); db.commit()

    async def retrieve(db, owner, query):
        return {'items': [{'id': memory.id, 'content': memory.content}], 'retrieval_mode': 'keyword'}

    async def reply(context, message):
        return AgentReply(text='Would you like jasmine tea?', proposed_task=None, mode='deterministic_demo')

    monkeypatch.setattr(memory_service, 'retrieve_for_chat', retrieve)
    app.state.orchestrator.run = reply
    client.put('/check-ins/schedule', headers=headers, json={'enabled': True})
    with patch.object(check_ins, 'datetime') as clock:
        clock.now.return_value = datetime(2026, 10, 3, 4, 0, tzinfo=timezone.utc)
        clock.combine.side_effect = datetime.combine
        assert client.post('/check-ins/trigger', headers=headers, json={}).json()['triggered'] is True
    assert 'jasmine' in client.get('/notifications', headers=headers).json()['notifications'][0]['body']
    assert client.delete(f'/memories/{memory.id}', headers=memory_revision_headers(client, headers, idempotency_key='test_hamza_integration-193-delete')).status_code in (200, 204)
    assert 'jasmine' not in client.get('/notifications', headers=headers).json()['notifications'][0]['body']


def test_urgent_intervention_skips_memory_provider(setup, monkeypatch):
    import app.routers.conversations as conversations
    app, client, elder, *_ = setup
    headers = _headers(elder)
    client.put('/memories/consent', headers=memory_revision_headers(client, headers), json={'enabled': True})

    async def must_not_call(*args, **kwargs):
        raise AssertionError('Urgent intervention must not wait for retrieval')

    monkeypatch.setattr(conversations, 'retrieve_for_chat', must_not_call)
    conversation = client.post('/conversations', headers=headers, json={}).json()
    response = client.post(f"/conversations/{conversation['id']}/messages", headers=headers,
        json={'content':'I want to die', 'client_message_id':'urgent'})
    assert response.status_code == 200 and response.json()['mode'] == 'safety_intervention'
