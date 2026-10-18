"""Synthetic explicit plans; real DEMO adapter and temporary SQLite only."""
import asyncio

import pytest
from fastapi.testclient import TestClient

from app.llm import DeterministicDemoAdapter
from app.main import create_app
from tests.test_integration import _headers, _register, _settings


@pytest.mark.parametrize('text,due', [
    ('Please remind me to visit the fictional library at 2099-01-02T00:15:30+08:00.', '2099-01-02T00:15:30+08:00'),
    ('Please remind me to visit the fictional library at 2099-01-02T00:15Z.', '2099-01-02T00:15Z'),
    ('Please remind me to visit the fictional library at 2099-01-02T00:15:30.123456-05:00.', '2099-01-02T00:15:30.123456-05:00'),
    ('Please remind me to visit the fictional library at 2099-01-02T00:15:30+14:00.', '2099-01-02T00:15:30+14:00'),
    ('\u8acb\u63d0\u9192\u6211\u53bb\u865b\u69cb\u5716\u66f8\u9928 2099-01-02T00:15:30+08:00\u3002', '2099-01-02T00:15:30+08:00'),
])
def test_demo_preserves_one_explicit_future_offset_in_plan(text, due):
    reply = asyncio.run(DeterministicDemoAdapter().reply({}, text))
    assert reply.mode == 'deterministic_demo'
    assert reply.proposed_task['due_at'] == due
    assert reply.memory_actions == []


@pytest.mark.parametrize('when', [
    'tomorrow afternoon', '2099-01-02', '2099-01-02T00:15:30',
    '2099-02-30T00:15:30Z', '2099-01-02T24:00:00Z',
    '2099-01-02T00:15:30-00:00', '2099-01-02T00:15:30+14:01',
    '2099-01-02T00:15:30+25:00', '2000-01-02T00:15:30Z',
    '2099-01-02T00:15:30Z or 2099-01-03T00:15:30Z',
    '2099-01-02T00:15:30Z or 2099-01-03',
    '2099-01-02T00:15:30Zjunk', '2099-01-02T00:15:30+08:00:30',
    '2099-01-02T00:15:30+08:00.5',
    '2099-01-02T00:15:30Z_foo', '2099-01-02T00:15:30Z/P1D',
    '2099-01-02T00:15:30Z@invalid', 'P1D/2099-01-02T00:15:30Z',
    'https://example.invalid/2099-01-02T00:15:30Z',
    '-2099-01-02T00:15:30Z',
])
def test_demo_does_not_guess_unclear_invalid_or_expired_times(when):
    reply = asyncio.run(DeterministicDemoAdapter().reply(
        {}, f'Please remind me to visit the fictional library at {when}.'))
    assert reply.proposed_task['due_at'] is None


@pytest.mark.parametrize('text', [
    'I once visited a fictional library. The example date is 2099-01-02T00:15:30Z.',
    'Do not remind me to visit a fictional library at 2099-01-02T00:15:30Z.',
])
def test_iso_time_does_not_create_a_request_from_a_story_or_refusal(text):
    reply = asyncio.run(DeterministicDemoAdapter().reply({}, text))
    assert reply.proposed_task is None


def test_demo_plan_requires_confirm_and_retains_exact_instant(tmp_path):
    app = create_app(_settings(tmp_path/'fictional-demo-plan.db'))
    with TestClient(app) as client:
        owner = _register(client, 'fictional-demo-plan@example.invalid')
        headers = _headers(owner)
        conversation = client.post('/conversations', headers=headers, json={}).json()
        def propose(message_id):
            response = client.post(f'/conversations/{conversation["id"]}/messages',
                headers=headers, json={'content': 'Please remind me to visit the fictional library at 2099-01-02T00:15:30+08:00.', 'client_message_id':message_id})
            assert response.status_code == 200, response.text
            assert response.json()['mode'] == 'deterministic_demo'
            return response.json()['action']
        action = propose('explicit-plan')
        assert client.get('/tasks', headers=headers).json() == []
        assert action['payload']['due_at'] == '2099-01-02T00:15:30+08:00'
        confirmed = client.post(f'/actions/{action["id"]}/confirm', headers=headers, json={})
        assert confirmed.status_code == 200, confirmed.text
        assert confirmed.json()['task']['due_at'].startswith('2099-01-01T16:15:30')
        replay = client.post(f'/actions/{action["id"]}/confirm', headers=headers, json={})
        assert replay.json()['task']['id'] == confirmed.json()['task']['id']
        skipped = propose('skip-explicit-plan')
        assert client.post(f'/actions/{skipped["id"]}/dismiss', headers=headers).status_code == 200
        assert len(client.get('/tasks', headers=headers).json()) == 1
        assert client.post(f'/actions/{skipped["id"]}/confirm', headers=headers, json={}).status_code == 409
