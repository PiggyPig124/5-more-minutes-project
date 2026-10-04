"""Live interim journeys. Use a disposable local demo database only."""
from memory_revision_helpers import http_memory_revision_headers
import argparse
import json
import uuid

from foundation_api_acceptance import APIClient


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-url', default='http://127.0.0.1:8013')
    args = parser.parse_args()
    passed = 0

    def check(ok, label):
        nonlocal passed
        if not ok:
            raise AssertionError(label)
        passed += 1
        print('PASS', label)

    def request(client, method, path, payload=None, expected=200, *, headers=None):
        result = client.request(method, path, payload, headers=headers)
        check(result.status == expected, f'{method} {path.split("/")[1]} responds {expected}')
        return result.body

    suffix = uuid.uuid4().hex
    elder, child, stranger = [APIClient(args.base_url) for _ in range(3)]
    accounts = []
    for index, client in enumerate((elder, child, stranger)):
        account = request(client, 'POST', '/auth/register', {
            'email': f'interim-{index}-{suffix}@example.invalid', 'password': 'Local-interim-check-2026',
            'display_name': f'Fictional tester {index}', 'role': 'elder' if index == 0 else 'caregiver',
        }, 201)
        client.token = account['access_token']
        accounts.append(account['account'])

    request(elder, 'PUT', '/memories/consent', {'enabled': True}, headers=http_memory_revision_headers(elder))
    conversation = request(elder, 'POST', '/conversations', {}, 201)
    candidate_reply = request(elder, 'POST', f"/conversations/{conversation['id']}/messages", {
        'content': '記住我以前在大澳教書', 'client_message_id': 'save-memory',
    })
    metadata = candidate_reply['assistant_message']['metadata_json']
    draft_revision = metadata['memory_revision']
    check(isinstance(draft_revision, int) and not isinstance(draft_revision, bool),
          'chat supplies the memory revision captured for this draft')
    suggestion = metadata.get('memory_suggestion')
    if metadata.get('mode') == 'deterministic_demo':
        check(metadata.get('demo_label') is True and suggestion is None,
              'deterministic demo is explicitly labelled and makes no automatic suggestion')
        suggestion = {'content': '我以前在大澳教書', 'kind': 'experience'}
    else:
        check(metadata.get('mode') == 'openai_compatible' and isinstance(suggestion, dict)
              and isinstance(suggestion.get('content'), str) and bool(suggestion['content'].strip())
              and suggestion.get('kind') in ('fact', 'experience', 'preference', 'emotion')
              and suggestion.get('requires_confirmation') is True
              and suggestion.get('source_message_id') == candidate_reply['user_message']['id']
              and suggestion.get('revision') == draft_revision,
              'configured model supplies a valid transient review suggestion')
    check(request(elder, 'GET', '/memories') == [],
          'chat creates no persisted candidate or memory before explicit Save')
    result = request(elder, 'POST', '/memories/search', {'query': '大澳教書'})
    check(not result['items'], 'candidate is excluded from recall')
    saved = request(elder, 'POST', '/memories/save', {
        'content': suggestion['content'], 'kind': suggestion['kind'],
        'topic_key': suggestion.get('topic_key'),
        'source_message_id': candidate_reply['user_message']['id'],
    }, 201, headers={'X-Memory-Revision': str(draft_revision)})
    memory_id = saved['id']
    second = request(elder, 'POST', '/conversations', {}, 201)
    reply = request(elder, 'POST', f"/conversations/{second['id']}/messages", {'content': '你記得我在大澳教書嗎？'})
    check(any(item['id'] == memory_id for item in reply['assistant_message']['metadata_json']['memory_sources']),
          'new conversation recalls confirmed personal evidence')
    check('大澳教書' in reply['assistant_message']['content'], 'demo reply uses recalled evidence')
    request(child, 'GET', '/memories', expected=403)
    request(stranger, 'POST', '/memories/search', {'query': '大澳'}, 403)

    request(elder, 'PATCH', f'/memories/{memory_id}', {'suppressed': True}, headers=http_memory_revision_headers(elder))
    check(not request(elder, 'POST', '/memories/search', {'query': '大澳教書'})['items'], 'suppressed memory is not retrieved')
    request(elder, 'PATCH', f'/memories/{memory_id}', {'suppressed': False}, headers=http_memory_revision_headers(elder))
    replacement = request(elder, 'PATCH', f'/memories/{memory_id}', {'content': '我以前在沙田教書'}, headers=http_memory_revision_headers(elder))
    check(replacement['id'] != memory_id and replacement['status'] == 'candidate', 'correction requires renewed confirmation')
    memory_id = replacement['id']
    request(elder, 'POST', f'/memories/{memory_id}/confirm', headers=http_memory_revision_headers(elder))
    story = request(elder, 'POST', '/stories', {'title': '教學生涯', 'content': '我以前在沙田教書', 'memory_ids': [memory_id]}, 201, headers=http_memory_revision_headers(elder))
    invitation = request(elder, 'POST', '/family-links/invitations', {
        'email': accounts[1]['email'], 'scopes': ['care_tasks', 'family_messages'],
    }, 201)
    link = request(child, 'POST', '/family-links/invitations/accept', {'token': invitation['token']}, 201)
    share = {'recipient_id': accounts[1]['id'], 'content': story['title'] + '\n' + story['content'],
             'source_story_id': story['id'], 'client_message_id': 'share-story',
             'family_link_id': link['id'], 'expected_authorization_epoch': link['authorization_epoch']}
    share_headers = http_memory_revision_headers(elder)
    sent = request(elder, 'POST', '/family-messages', share, 201, headers=share_headers)
    retry = request(elder, 'POST', '/family-messages', share, 201, headers=share_headers)
    check(sent['id'] == retry['id'], 'sharing retry does not send twice')
    check(len(request(child, 'GET', '/family-messages')) == 1, 'authorized recipient receives one story')
    check(request(stranger, 'GET', '/family-messages') == [], 'unrelated account sees no family messages')
    request(child, 'POST', '/family-messages', {
        'recipient_id': accounts[0]['id'], 'content': '多謝你分享！', 'client_message_id': 'reply',
        'family_link_id': link['id'], 'expected_authorization_epoch': link['authorization_epoch'],
    }, 201)
    check(len(request(elder, 'GET', '/family-messages')) == 2, 'elder receives family reply')
    request(elder, 'DELETE', f'/memories/{memory_id}', expected=204, headers=http_memory_revision_headers(elder, idempotency_key='interim_api_acceptance-82-delete'))
    check(request(elder, 'GET', '/stories') == [], 'deletion removes derived stories')
    copies = request(child, 'GET', '/family-messages')
    check(any(item['id'] == sent['id'] and item['content'] == '[故事已由擁有人撤回]' for item in copies), 'deletion retracts shared story copy')
    for cid in (conversation['id'], second['id']):
        history = request(elder, 'GET', f'/conversations/{cid}')
        check('大澳教書' not in json.dumps(history, ensure_ascii=False), 'deleted original is absent from history and summaries')

    resources = request(child, 'POST', '/resources/search', {'query': '醫療費用減免'})
    check(bool(resources['items']), 'verified medical assistance evidence is found')
    check(all(item['url'].startswith('http') and item['verified_at'] and len(item['next_steps']) == 3
              and item['missing_information'] for item in resources['items']), 'each result has provenance, questions and three next steps')
    check(not request(elder, 'POST', '/resources/search', {'query': 'quantum rocket fuel xyz'})['items'], 'unrelated enquiry abstains')
    welfare_reply = request(elder, 'POST', f"/conversations/{second['id']}/messages", {'content': '我想問醫療費用減免'})
    check(bool(welfare_reply['assistant_message']['metadata_json']['resource_sources']), 'chat invokes public retrieval with sources')
    request(elder, 'POST', f"/family-links/{link['id']}/revoke")
    check(request(child, 'GET', '/family-messages') == [], 'revocation blocks old message access')
    request(elder, 'POST', '/family-messages', share, 409, headers=share_headers)
    check(request(elder, 'GET', '/memories') == [], 'stale story retry cannot restore deleted memory')
    request(elder, 'POST', '/family-messages', {
        'recipient_id': accounts[1]['id'], 'content': 'Synthetic post-revocation message',
        'client_message_id': 'after-revocation',
        'family_link_id': link['id'], 'expected_authorization_epoch': link['authorization_epoch'],
    }, 403)
    print(f'\nInterim acceptance: {passed} passed, 0 failed')


if __name__ == '__main__':
    main()
