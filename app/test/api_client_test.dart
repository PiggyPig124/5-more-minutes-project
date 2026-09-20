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
}
