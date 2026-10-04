import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

FamilyInvitation link(int epoch) => FamilyInvitation(
    id: 'preview-link',
    email: 'care@example.invalid',
    status: InvitationStatus.accepted,
    elderId: 'elder',
    caregiverId: 'care',
    authorizationEpoch: epoch,
    scopes: ['family_messages']);
void main() {
  for (final story in [false, true]) {
    test(
        'delayed ${story ? 'story' : 'normal'} preview sends captured epoch and 410 does not upgrade or retry',
        () async {
      final calls = <Map<String, dynamic>>[];
      final blocked = Completer<http.Response>();
      final api = RestApiClient(client: MockClient((r) async {
        if (r.url.path == '/memories/control-state') {
          return http.Response(
              '{"enabled":true,"revision":5,"counts":{}}', 200);
        }
        if (r.url.path == '/family-messages' && r.method == 'POST') {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          calls.add(body);
          if (calls.length == 1) {
            expect(r.headers['X-Memory-Revision'], story ? '5' : isNull);
            return blocked.future;
          }
          return http.Response(
              jsonEncode({
                'id': 'fresh',
                'sender_id': 'elder',
                'recipient_id': 'care',
                'content': body['content']
              }),
              201);
        }
        return http.Response('[]', 200);
      }));
      final c = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = const AuthSession(
            accessToken: 'synthetic',
            user: AppUser(
                id: 'elder',
                displayName: 'Senior',
                email: 'elder@example.invalid',
                role: UserRole.elder));
      await c.refreshMemoryControlState();
      final old = link(1);
      c.links = [old];
      const card = StoryRecord(
          id: 'card', title: 'Title', content: 'Source body', revision: 5);
      final content = story ? 'Title\nSource body' : 'Old complete preview';
      final pending = c.sendFamilyMessage(
          link: old, content: content, sourceStory: story ? card : null);
      for (var i = 0; i < 20 && calls.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(calls, hasLength(1));
      expect(calls.single['family_link_id'], 'preview-link');
      expect(calls.single['expected_authorization_epoch'], 1);
      final current = link(3);
      c.links = [current];
      blocked.complete(
          http.Response('{"detail":"Preview authorization has ended"}', 410));
      expect(await pending, isFalse);
      expect(calls, hasLength(1));
      expect(c.familyMessages, isEmpty);
      // A user explicitly opens a fresh preview; the old immutable DTO remains refused.
      c.links = [current];
      expect(
          await c.sendFamilyMessage(
              link: old, content: content, sourceStory: story ? card : null),
          isFalse);
      expect(calls, hasLength(1));
      await c.refreshFamilyConnections();
      c.links = [current];
      expect(
          await c.sendFamilyMessage(
              link: current,
              content: content,
              sourceStory: story ? card : null),
          isTrue);
      expect(calls, hasLength(2));
      expect(calls.last['expected_authorization_epoch'], 3);
      expect(calls.last['client_message_id'],
          isNot(calls.first['client_message_id']));
    });
  }
}
