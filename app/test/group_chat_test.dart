import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/group_chat.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('human group requests stay separate from private AI chat and carry auth', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.headers['Authorization'], 'Bearer group-token');
      final path = request.url.path;
      if (path == '/groups' && request.method == 'GET') {
        return http.Response(jsonEncode([{
          'id': 'g1', 'title': 'Recipes', 'owner_id': 'a1',
          'owner_name': 'Alice', 'member_count': 2,
        }]), 200);
      }
      if (path == '/groups/invitations') {
        return http.Response(jsonEncode([{
          'id': 'i1', 'group_id': 'g1', 'group_title': 'Recipes',
          'inviter_name': 'Alice',
        }]), 200);
      }
      if (path == '/groups/invitations/i1/accept') {
        return http.Response(jsonEncode({
          'id': 'g1', 'title': 'Recipes', 'owner_id': 'a1',
          'owner_name': 'Alice', 'member_count': 2,
        }), 200);
      }
      if (path == '/groups/g1/messages' && request.method == 'POST') {
        return http.Response(jsonEncode({
          'id': 'm1', 'group_id': 'g1', 'sender_id': 'a2',
          'sender_name': 'Bob', 'ordinal': 1, 'content': 'Hello',
        }), 201);
      }
      throw StateError('Unexpected request $path');
    });
    final api = RestApiClient(
        origin: 'http://localhost:8000', client: client,
        accessToken: 'group-token');
    expect((await api.listHumanGroups()).single.title, 'Recipes');
    final invitation = (await api.listHumanGroupInvitations()).single;
    expect((await api.acceptHumanGroupInvitation(invitation.id)).id, 'g1');
    final sent = await api.sendHumanGroupMessage('g1', 'Hello', 'stable-1');
    expect(sent.senderName, 'Bob');
    expect(jsonDecode(requests.last.body), {
      'content': 'Hello', 'client_message_id': 'stable-1',
    });
    expect(requests.map((request) => request.url.path),
        isNot(contains('/conversations')));
  });

  testWidgets('group lobby explains people-only privacy boundary', (tester) async {
    final client = MockClient((request) async => http.Response('[]', 200));
    final api = RestApiClient(origin: 'http://localhost:8000',
        client: client, accessToken: 'group-token');
    await tester.pumpWidget(MaterialApp(locale: traditionalChineseLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: Scaffold(
      body: GroupLobbyScreen(api: api, accountId: 'a1'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('人與人群聊'), findsOneWidget);
    expect(find.textContaining('AI 不會閱讀或回覆群訊息'), findsOneWidget);
    expect(find.text('我的群組'), findsOneWidget);
  });
}
