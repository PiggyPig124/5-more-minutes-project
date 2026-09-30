"""Live interim journeys. Use a disposable local demo database only."""
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

    def request(client, method, path, payload=None, expected=200):
        result = client.request(method, path, payload)
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

    request(elder, 'PUT', '/memories/consent', {'enabled': True})
    conversation = request(elder, 'POST', '/conversations', {}, 201)
    candidate_reply = request(elder, 'POST', f"/conversations/{conversation['id']}/messages", {
        'content': '記住我以前在大澳教書', 'client_message_id': 'save-memory',
    })
    suggestion = candidate_reply['assistant_message']['metadata_json']['memory_suggestion']
    check(bool(suggestion), 'explicit remember request produces a transient review suggestion')
    result = request(elder, 'POST', '/memories/search', {'query': '大澳教書'})
    check(not result['items'], 'candidate is excluded from recall')
    saved = request(elder, 'POST', '/memories/save', {
        **suggestion, 'source_message_id': candidate_reply['user_message']['id'],
    }, 201)
    memory_id = saved['id']
    second = request(elder, 'POST', '/conversations', {}, 201)
    reply = request(elder, 'POST', f"/conversations/{second['id']}/messages", {'content': '你記得我在大澳教書嗎？'})
    check(any(item['id'] == memory_id for item in reply['assistant_message']['metadata_json']['memory_sources']),
          'new conversation recalls confirmed personal evidence')
    check('大澳教書' in reply['assistant_message']['content'], 'demo reply uses recalled evidence')
    request(child, 'GET', '/memories', expected=403)
    request(stranger, 'POST', '/memories/search', {'query': '大澳'}, 403)

    request(elder, 'PATCH', f'/memories/{memory_id}', {'suppressed': True})
    check(not request(elder, 'POST', '/memories/search', {'query': '大澳教書'})['items'], 'suppressed memory is not retrieved')
    request(elder, 'PATCH', f'/memories/{memory_id}', {'suppressed': False})
    replacement = request(elder, 'PATCH', f'/memories/{memory_id}', {'content': '我以前在沙田教書'})
    check(replacement['id'] != memory_id and replacement['status'] == 'candidate', 'correction requires renewed confirmation')
    memory_id = replacement['id']
    request(elder, 'POST', f'/memories/{memory_id}/confirm')
    story = request(elder, 'POST', '/stories', {'title': '教學生涯', 'content': '我以前在沙田教書', 'memory_ids': [memory_id]}, 201)
    invitation = request(elder, 'POST', '/family-links/invitations', {
        'email': accounts[1]['email'], 'scopes': ['care_tasks', 'family_messages'],
    }, 201)
    link = request(child, 'POST', '/family-links/invitations/accept', {'token': invitation['token']}, 201)
    share = {'recipient_id': accounts[1]['id'], 'content': story['title'] + '\n' + story['content'],
             'source_story_id': story['id'], 'client_message_id': 'share-story'}
    sent = request(elder, 'POST', '/family-messages', share, 201)
    retry = request(elder, 'POST', '/family-messages', share, 201)
    check(sent['id'] == retry['id'], 'sharing retry does not send twice')
    check(len(request(child, 'GET', '/family-messages')) == 1, 'authorized recipient receives one story')
    check(request(stranger, 'GET', '/family-messages') == [], 'unrelated account sees no family messages')
    request(child, 'POST', '/family-messages', {
        'recipient_id': accounts[0]['id'], 'content': '多謝你分享！', 'client_message_id': 'reply',
    }, 201)
    check(len(request(elder, 'GET', '/family-messages')) == 2, 'elder receives family reply')
    request(elder, 'DELETE', f'/memories/{memory_id}', expected=204)
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
    request(elder, 'POST', '/family-messages', share, 403)
    print(f'\nInterim acceptance: {passed} passed, 0 failed')


if __name__ == '__main__':
    main()
