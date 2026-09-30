"""Verify confirmed-memory persistence and lasting withdrawal across processes."""
from pathlib import Path
import secrets
import tempfile

from foundation_api_acceptance import APIClient
from process_restart_acceptance import _free_port, _start_server, _stop_server, _wait_for_health


def main():
    count = 0

    def check(condition, label):
        nonlocal count
        assert condition, label
        count += 1
        print('PASS', label)

    secret, port = secrets.token_urlsafe(32), _free_port()
    base_url = f'http://127.0.0.1:{port}'
    with tempfile.TemporaryDirectory(prefix='anxin-interim-restart-') as folder:
        path = Path(folder) / 'state.db'
        process = _start_server(path, secret, port)
        api = APIClient(base_url)
        try:
            check(_wait_for_health(base_url, process), 'first process healthy')
            registered = api.post('/auth/register', {
                'email': 'restart@example.invalid', 'password': 'Interim-restart-2026!',
                'display_name': 'Fictional elder', 'role': 'elder',
            })
            check(registered.status == 201, 'fixture account created')
            api.token = registered.body['access_token']
            check(api.request('PUT', '/memories/consent', {'enabled': True}).status == 200, 'fixture explicitly enables memory')
            created = api.post('/memories', {'content': '我以前在大澳教書', 'kind': 'experience'})
            check(created.status == 201, 'memory candidate persisted')
            memory_id = created.body['id']
            check(api.post(f'/memories/{memory_id}/confirm').status == 200, 'memory confirmed')
            story = api.post('/stories', {'title': '教學生涯', 'content': '我以前在大澳教書', 'memory_ids': [memory_id]})
            check(story.status == 201, 'derived story persisted')
        finally:
            _stop_server(process)
        process = _start_server(path, secret, port)
        try:
            check(_wait_for_health(base_url, process), 'second process healthy')
            check(api.get('/auth/me').status == 200, 'old token survives restart')
            found = api.post('/memories/search', {'query': '大澳教書'})
            check(found.status == 200 and any(item['id'] == memory_id for item in found.body['items']), 'confirmed memory retrieved after restart')
            check(any(item['id'] == story.body['id'] for item in api.get('/stories').body), 'story survives restart')
            conversation = api.post('/conversations', {})
            recalled = api.post(f"/conversations/{conversation.body['id']}/messages", {'content': '大澳教書'})
            check(recalled.status == 200 and bool(recalled.body['assistant_message']['metadata_json']['memory_sources']), 'new conversation retrieves restarted memory')
            check(api.delete(f'/memories/{memory_id}').status == 204, 'memory withdrawal succeeds')
        finally:
            _stop_server(process)
        process = _start_server(path, secret, port)
        try:
            check(_wait_for_health(base_url, process), 'third process healthy')
            found = api.post('/memories/search', {'query': '大澳教書'})
            check(found.status == 200 and found.body['items'] == [], 'withdrawn memory stays absent after restart')
            check(api.get('/stories').body == [], 'derived story stays absent after restart')
            history = api.get(f"/conversations/{conversation.body['id']}")
            check(history.status == 200 and '大澳教書' not in str(history.body), 'sanitized conversation stays sanitized after restart')
        finally:
            _stop_server(process)
    print(f'\nInterim restart acceptance: {count} passed, 0 failed')


if __name__ == '__main__':
    main()
