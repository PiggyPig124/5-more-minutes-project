import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('auth response parses backend account shape and sends role registration', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'access_token': 'server-token',
          'token_type': 'bearer',
          'account': {
            'id': 'elder-1',
            'email': 'elder@example.com',
            'display_name': '阿明',
            'role': 'elder',
            'created_at': '2026-09-20T00:00:00Z',
          },
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = RestApiClient(origin: 'http://localhost:8000', client: client);
    final session = await api.register(email: 'elder@example.com', password: 'password123', displayName: '阿明', role: UserRole.elder);
    expect(session.accessToken, 'server-token');
    expect(session.user.role, UserRole.elder);
    expect(jsonDecode(captured.body), {
      'email': 'elder@example.com',
      'password': 'password123',
      'display_name': '阿明',
      'role': 'elder',
    });
  });

  test('message result preserves server action preview and deterministic mode', () async {
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer token');
      return http.Response(
        jsonEncode({
          'conversation': {'id': 'conversation-1', 'title': '新對話'},
          'user_message': {
            'id': 'message-1',
            'conversation_id': 'conversation-1',
            'role': 'user',
            'content': '請提醒我星期五覆診',
          },
          'assistant_message': {
            'id': 'message-2',
            'conversation_id': 'conversation-1',
            'role': 'assistant',
            'content': '我可以幫你記下，先請你確認。',
            'metadata_json': {
              'candidate_memory_id': 'memory-1',
              'memory_retrieval_mode': 'hybrid_python',
              'memory_sources': [
                {'id': 'memory-0', 'content': '我曾經提過覆診。'},
              ],
            },
          },
          'action': {
            'id': 'action-1',
            'conversation_id': 'conversation-1',
            'action_type': 'task',
            'payload': {'title': '覆診提醒', 'description': '星期五覆診'},
            'status': 'pending',
          },
          'mode': 'deterministic_demo',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = RestApiClient(origin: 'http://localhost:8000', client: client, accessToken: 'token');
    final result = await api.sendMessage(conversationId: 'conversation-1', content: '請提醒我星期五覆診', clientMessageId: 'client-message-1');
    expect(result.assistantMessage?.body, '我可以幫你記下，先請你確認。');
    expect(result.action?.title, '覆診提醒');
    expect(result.action?.conversationId, 'conversation-1');
    expect(result.demoMode, isTrue);
    expect(result.assistantMessage?.candidateMemoryId, 'memory-1');
    expect(result.assistantMessage?.retrievalMode, 'hybrid_python');
    expect(result.assistantMessage?.memorySources.single.content, '我曾經提過覆診。');
  });

  test('action confirmation sends backend idempotency key and parses task', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'action': {'id': 'action-1', 'status': 'confirmed'},
          'task': {
            'id': 'task-1',
            'title': '覆診提醒',
            'description': '星期五覆診',
            'status': 'pending',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = RestApiClient(origin: 'http://localhost:8000', client: client, accessToken: 'token');
    final task = await api.confirmAction(actionId: 'action-1', clientActionId: 'stable-key');
    expect(task?.id, 'task-1');
    expect(jsonDecode(captured.body), {'idempotency_key': 'stable-key'});
    expect(captured.headers['Idempotency-Key'], 'stable-key');
  });

  test('memory candidate and confirmation use the explicit memory routes', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' && request.url.path.endsWith('/memories')) {
        return http.Response(
          jsonEncode({'id': 'memory-1', 'content': '我喜歡飲茶', 'kind': 'conversation', 'status': 'candidate'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'id': 'memory-2', 'content': '我喜歡飲茶', 'kind': 'conversation', 'status': 'confirmed'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = RestApiClient(origin: 'http://localhost:8012', client: client, accessToken: 'token');
    final candidate = await api.createMemory(content: '我喜歡飲茶', kind: 'conversation', sourceMessageId: 'message-4');
    final confirmed = await api.confirmMemory(candidate.id);
    expect(candidate.status, 'candidate');
    expect(confirmed.status, 'confirmed');
    expect(jsonDecode(requests.first.body), {
      'content': '我喜歡飲茶',
      'kind': 'conversation',
      'source_message_id': 'message-4',
    });
    expect(requests[1].url.path, '/memories/memory-1/confirm');
  });

  test('resource search preserves retrieval metadata and family message scope/idempotency', () async {
    late http.Request resourceRequest;
    late http.Request familyRequest;
    var familyCall = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/resources/search')) {
        resourceRequest = request;
        return http.Response(
          jsonEncode({
            'query': '交通',
            'retrieval_mode': 'verified_registry',
            'items': [
              {
                'id': 'resource-1',
                'title': '長者交通優惠',
                'excerpt': '查看申請資格',
                'url': 'https://example.test/transport',
                'conditions': ['年滿六十歲'],
                'missing_information': ['住址'],
                'next_steps': ['致電查詢'],
              },
            ],
            'conflicts': ['更新日期不同'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      familyCall += 1;
      familyRequest = request;
      return http.Response(
        jsonEncode({
          'id': 'family-message-1',
          'sender_id': 'elder-1',
          'recipient_id': 'caregiver-1',
          'content': '今日食飯嗎？',
          'source_story_id': 'story-1',
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = RestApiClient(origin: 'http://localhost:8012', client: client, accessToken: 'token');
    final resources = await api.searchResources(query: '交通', limit: 4);
    final message = await api.sendFamilyMessage(recipientId: 'caregiver-1', content: '今日食飯嗎？', clientMessageId: 'family-op-1', sourceStoryId: 'story-1');
    expect(resources.retrievalMode, 'verified_registry');
    expect(resources.items.single.title, '長者交通優惠');
    expect(resources.items.single.conditions, ['年滿六十歲']);
    expect(resources.conflicts.single.summary, '更新日期不同');
    expect(jsonDecode(resourceRequest.body), {'query': '交通', 'limit': 4});
    expect(message.sourceStoryId, 'story-1');
    expect(familyCall, 1);
    expect(jsonDecode(familyRequest.body), {
      'recipient_id': 'caregiver-1',
      'content': '今日食飯嗎？',
      'client_message_id': 'family-op-1',
      'source_story_id': 'story-1',
    });
    expect(familyRequest.headers['Idempotency-Key'], 'family-op-1');
  });

  test('invitation sends only explicitly selected family message scope', () async {
    late http.Request request;
    final client = MockClient((incoming) async {
      request = incoming;
      return http.Response(
        jsonEncode({'id': 'invitation-1', 'email': 'caregiver@example.com', 'status': 'pending', 'scopes': ['care_tasks', 'family_messages']}),
        201,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = RestApiClient(origin: 'http://localhost:8012', client: client, accessToken: 'token');
    final invitation = await api.createInvitation(email: 'caregiver@example.com', scopes: const ['care_tasks', 'family_messages']);
    expect(invitation.allowsFamilyMessages, isTrue);
    expect(jsonDecode(request.body)['scopes'], ['care_tasks', 'family_messages']);
  });
}
