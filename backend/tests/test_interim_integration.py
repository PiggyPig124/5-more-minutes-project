"""Cross-module interim journeys against the actual FastAPI application."""
import asyncio
import pytest

from fastapi.testclient import TestClient

from app.llm import AgentReply
from app.main import create_app
from .test_family_messages import link_accounts
from .test_integration import _settings, _register, _headers


def confirmed_memory(client, headers, content):
    created = client.post('/memories', headers=headers, json={'content': content, 'kind': 'experience'})
    assert created.status_code == 201, created.text
    memory_id = created.json()['id']
    assert client.post(f'/memories/{memory_id}/confirm', headers=headers).status_code == 200
    return memory_id


def test_temporary_emotion_and_unrelated_chinese_query_are_not_facts(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'recall-boundary.db'))) as client:
        elder = _register(client, 'recall-boundary@example.test')
        headers = _headers(elder)
        confirmed_memory(client, headers, '我以前在大澳教書')
        assert client.post('/memories/search', headers=headers, json={'query': '你記得我喜歡食什麼'}).json()['items'] == []
        emotion = client.post('/memories', headers=headers, json={'content': '今天很孤單', 'kind': 'emotion'}).json()
        assert client.post(f"/memories/{emotion['id']}/confirm", headers=headers).status_code == 200
        assert client.post('/memories/search', headers=headers, json={'query': '今天很孤單'}).json()['items'] == []


def test_explicit_candidate_and_cross_conversation_recall(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'journey.db'))) as client:
        elder = _register(client, 'memory-owner@example.test')
        headers = _headers(elder)
        first = client.post('/conversations', headers=headers, json={}).json()['id']
        saved = client.post(f'/conversations/{first}/messages', headers=headers, json={
            'content': '記住我以前在大澳教書', 'client_message_id': 'remember',
        })
        assert saved.status_code == 200, saved.text
        candidate = saved.json()['assistant_message']['metadata_json']['candidate_memory_id']
        assert client.post('/memories/search', headers=headers, json={'query': '大澳教書'}).json()['items'] == []
        client.post(f'/memories/{candidate}/confirm', headers=headers)
        second = client.post('/conversations', headers=headers, json={}).json()['id']
        recalled = client.post(f'/conversations/{second}/messages', headers=headers, json={'content': '你記得我在大澳教書嗎？'})
        assert recalled.status_code == 200, recalled.text
        assistant = recalled.json()['assistant_message']
        assert any(item['id'] == candidate for item in assistant['metadata_json']['memory_sources'])
        assert '大澳教書' in assistant['content']
        assert client.delete(f'/memories/{candidate}', headers=headers).status_code == 204
        for cid in (first, second):
            history = client.get(f'/conversations/{cid}', headers=headers).json()
            assert '大澳教書' not in str(history)
        assert client.post('/memories/search', headers=headers, json={'query': '大澳教書'}).json()['items'] == []


def test_story_sharing_uses_current_authorization_and_retracts_copies(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'story-share.db'))) as client:
        elder = _register(client, 'story-owner@example.test')
        child = _register(client, 'child@example.test', 'caregiver')
        headers = _headers(elder)
        memory_id = confirmed_memory(client, headers, '我以前在大澳教書')
        story = client.post('/stories', headers=headers, json={
            'title': '我的教學生涯', 'content': '我以前在大澳教書', 'memory_ids': [memory_id],
        })
        assert story.status_code == 201, story.text
        story_id = story.json()['id']
        payload = {'recipient_id': child['account']['id'], 'content': '我的教學生涯\n我以前在大澳教書',
                   'source_story_id': story_id, 'client_message_id': 'story-share'}
        assert client.post('/family-messages', headers=headers, json=payload).status_code == 403
        link_accounts(client, elder, child, ['family_messages'])
        assert client.post('/family-messages', headers=headers, json=payload).status_code == 201
        assert client.get('/stories', headers=_headers(child)).status_code == 403
        assert client.post('/memories/search', headers=_headers(child), json={'query': '大澳'}).status_code == 403
        assert client.delete(f'/memories/{memory_id}', headers=headers).status_code == 204
        assert client.get('/stories', headers=headers).json() == []
        copies = client.get('/family-messages', headers=_headers(child)).json()
        assert len(copies) == 1
        assert copies[0]['content'] == '[故事已由擁有人撤回]'
        assert client.post('/family-messages', headers=headers, json=payload).status_code == 409


@pytest.mark.parametrize('from_recent_context', [False, True])
def test_withdrawal_during_generation_cannot_resurrect_memory(tmp_path, from_recent_context):
    app = create_app(_settings(tmp_path / 'in-flight.db'))
    with TestClient(app) as client:
        elder = _register(client, 'race@example.test')
        headers = _headers(elder)
        memory_id = confirmed_memory(client, headers, 'I taught mathematics in Tai O')
        conversation = client.post('/conversations', headers=headers, json={}).json()['id']
        if from_recent_context:
            assert client.post(f'/conversations/{conversation}/messages', headers=headers,
                               json={'content': 'Tai O mathematics'}).status_code == 200

        class WithdrawDuringReply:
            async def run(self, context, user_message):
                assert bool(context['memory_sources']) is not from_recent_context
                response = await asyncio.to_thread(client.delete, f'/memories/{memory_id}', headers=headers)
                assert response.status_code == 204
                return AgentReply(text='I taught mathematics in Tai O', proposed_task=None, mode='deterministic_demo')

        app.state.orchestrator = WithdrawDuringReply()
        response = client.post(f'/conversations/{conversation}/messages', headers=headers,
                               json={'content': 'zzq' if from_recent_context else 'Tai O mathematics', 'client_message_id': 'race'})
        assert response.status_code == 409, response.text
        history = client.get(f'/conversations/{conversation}/messages', headers=headers).json()
        assert len(history) == (2 if from_recent_context else 0)
        assert 'Tai O' not in str(history)
