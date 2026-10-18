"""Fictional proposals in temporary SQLite only; no OS reminder adapters."""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.models import ActionProposal, Conversation, Task
from app.routers import actions
from fastapi.testclient import TestClient
from app.main import create_app
from tests.test_integration import _settings, _register, _headers


@pytest.fixture
def setup(tmp_path):
    app = create_app(_settings(tmp_path / 'fictional-confirmation.db'))
    with TestClient(app) as client:
        owner = _register(client, 'fictional-reminder@example.test')
        yield app, client, owner


def seed(app, owner, due, *, title='Fictional library visit', kind='reminder', payload_type=None):
    with app.state.session_factory() as db:
        conversation = Conversation(owner_id=owner['account']['id'], title='Fictional plan')
        db.add(conversation); db.flush()
        action = ActionProposal(owner_id=owner['account']['id'], conversation_id=conversation.id,
            action_type=kind, status='pending', payload={
                'type': payload_type or kind, 'title': title, 'description': '', 'due_at': due})
        db.add(action); db.commit()
        return action.id


def confirm(client, owner, action_id):
    return client.post(f'/actions/{action_id}/confirm', headers=_headers(owner),
        json={'idempotency_key': 'fictional-confirm-'+action_id})


@pytest.mark.parametrize('due', [None, '', 'tomorrow morning', '2099-01-02',
    '2099-01-02T12:00:00', '2099-02-30T12:00:00Z', '2099-01-02T24:00:00Z',
    '2099-01-02T12:00:00-00:00', '2099-01-02T12:00:00+25:00',
    '2000-01-02T12:00:00Z', 12345])
def test_incomplete_ambiguous_or_expired_reminder_stays_pending(setup, due):
    app, client, owner = setup
    action_id = seed(app, owner, due)
    response = confirm(client, owner, action_id)
    assert response.status_code == 422, response.text
    assert 'date' in response.json()['detail'].lower()
    with app.state.session_factory() as db:
        action = db.get(ActionProposal, action_id)
        assert action.status == 'pending'
        assert action.confirmation_key is None
        assert db.scalar(select(Task).where(Task.source_action_id == action_id)) is None


@pytest.mark.parametrize('title', ['', '   ', None])
def test_scheduled_action_requires_actual_event_not_fallback_title(setup, title):
    app, client, owner = setup
    action_id = seed(app, owner, '2099-01-02T12:00:00Z', title=title)
    response = confirm(client, owner, action_id)
    assert response.status_code == 422, response.text
    assert client.get('/tasks', headers=_headers(owner)).json() == []


@pytest.mark.parametrize(('raw','expected'), [
    ('2099-01-02T00:15:30+08:00', '2099-01-01T16:15:30'),
    ('2099-01-02T00:15:00-05:00', '2099-01-02T05:15:00'),
    ('2099-01-02T12:15:00Z', '2099-01-02T12:15:00'),
])
def test_explicit_schedule_saves_exact_instant_and_idempotent_replay(setup, raw, expected):
    app, client, owner = setup
    action_id = seed(app, owner, raw, kind='care_task')
    first = confirm(client, owner, action_id)
    assert first.status_code == 200, first.text
    assert first.json()['task']['due_at'].startswith(expected)
    second = confirm(client, owner, action_id)
    assert second.status_code == 200
    assert first.json()['task']['id'] == second.json()['task']['id']
    assert len(client.get('/tasks', headers=_headers(owner)).json()) == 1


def test_expiration_at_confirmation_is_rejected_but_executed_replay_survives(setup, monkeypatch):
    app, client, owner = setup
    future = datetime.now(timezone.utc) + timedelta(minutes=2)
    pending = seed(app, owner, future.isoformat())
    executed = seed(app, owner, future.isoformat())
    assert confirm(client, owner, executed).status_code == 200

    class Later(datetime):
        @classmethod
        def now(cls, tz=None):
            return (future + timedelta(minutes=1)).astimezone(tz)
    monkeypatch.setattr(actions, 'datetime', Later)
    assert confirm(client, owner, pending).status_code == 422
    assert confirm(client, owner, executed).status_code == 200
    assert len(client.get('/tasks', headers=_headers(owner)).json()) == 1


def test_payload_cannot_hide_reminder_requirement_behind_generic_action_type(setup):
    app, client, owner = setup
    action_id = seed(app, owner, None, kind='care_task', payload_type='reminder')
    assert confirm(client, owner, action_id).status_code == 422


def test_legacy_unscheduled_task_contract_remains_distinct_from_reminder(setup):
    app, client, owner = setup
    action_id = seed(app, owner, None, kind='care_task')
    response = confirm(client, owner, action_id)
    assert response.status_code == 200, response.text
    assert response.json()['task']['due_at'] is None
