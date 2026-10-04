"""Demo attribution follows the evidence actually passed to the adapter."""
import asyncio

import pytest

from app.llm import DeterministicDemoAdapter
from tests.test_memory_controls import setup, auth, state

PUBLIC_LABEL = '以下內容參考公共資源。'
MEMORY_LABEL = '以下內容來自你的已保存記憶。'
MIXED_LABEL = '以下內容參考公共資源及你的已保存記憶。'
MEMORY_WORD = '已保存記憶'
PUBLIC_WORD = '公共資源'

MEMORY = {'id': 'synthetic-memory', 'content': 'Synthetic owner saved preference',
          'capture_method': 'owner_curated'}
RESOURCE = {'id': 'synthetic-resource', 'title': 'Synthetic public service',
            'excerpt': 'Public service guidance only.', 'missing_information': ['Confirm service details'],
            'next_steps': ['Read the official guidance'], 'url': 'https://www.swd.gov.hk/',
            'verified_at': '2026-10-03'}


@pytest.mark.parametrize('memories,resources,label', [
    ([], [RESOURCE], PUBLIC_LABEL), ([MEMORY], [], MEMORY_LABEL),
    ([MEMORY], [RESOURCE], MIXED_LABEL), ([], [], None),
])
def test_demo_attributes_only_actual_public_memory_mixed_or_no_evidence(memories, resources, label):
    reply = asyncio.run(DeterministicDemoAdapter().reply(
        {'memory_sources': memories, 'resource_sources': resources}, 'Tell me more'))
    assert reply.mode == 'deterministic_demo' and '[DEMO MODE' in reply.text
    assert reply.proposed_task is None and reply.memory_actions == []
    if label is not None:
        assert label in reply.text
    else:
        assert PUBLIC_WORD not in reply.text and MEMORY_WORD not in reply.text
    if not memories:
        assert MEMORY_WORD not in reply.text
    if not resources:
        assert PUBLIC_WORD not in reply.text
    if memories:
        assert MEMORY['content'] in reply.text
    if resources:
        assert RESOURCE['title'] in reply.text and RESOURCE['url'] in reply.text
        assert RESOURCE['verified_at'] in reply.text and RESOURCE['next_steps'][0] in reply.text


def test_metadata_binding_alone_does_not_claim_grounding_not_passed_as_evidence():
    reply = asyncio.run(DeterministicDemoAdapter().reply(
        {'memory_sources': [], 'resource_sources': [],
         'resource_source_bindings': [{'source_id': 'synthetic-resource', 'content_hash': 'a'*64}]},
        'Tell me more'))
    assert reply.mode == 'deterministic_demo' and '[DEMO MODE' in reply.text
    assert PUBLIC_WORD not in reply.text and MEMORY_WORD not in reply.text


def test_public_resource_task_preview_does_not_claim_saved_memory():
    reply = asyncio.run(DeterministicDemoAdapter().reply(
        {'memory_sources': [], 'resource_sources': [RESOURCE]}, 'Please remind me to call the service'))
    assert reply.mode == 'deterministic_demo' and '[DEMO MODE' in reply.text
    assert reply.proposed_task is not None and reply.proposed_task['title'] == 'call the service'
    assert MEMORY_WORD not in reply.text and RESOURCE['title'] in reply.text


def test_memory_off_http_public_reply_has_resource_attribution_and_real_source_binding(setup):
    _, client, (owner, _, _) = setup
    assert state(client, owner)['enabled'] is False
    conversation = client.post('/conversations', headers=auth(owner), json={'title': 'Synthetic attribution test'})
    assert conversation.status_code == 201, conversation.text
    response = client.post('/conversations/' + conversation.json()['id'] + '/messages',
        headers=auth(owner), json={'content': 'medical fee waiver', 'client_message_id': 'demo-source-test'})
    assert response.status_code == 200, response.text
    result = response.json()
    assistant = result['assistant_message']
    assert result['mode'] == 'deterministic_demo' and '[DEMO MODE' in assistant['content']
    assert assistant['metadata_json']['memory_sources'] == []
    assert assistant['metadata_json']['resource_sources']
    assert assistant['metadata_json']['resource_source_bindings']
    assert PUBLIC_LABEL in assistant['content'] and MEMORY_WORD not in assistant['content']
    assert state(client, owner)['enabled'] is False
