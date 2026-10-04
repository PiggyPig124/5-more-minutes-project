import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> requestJson() => {
      'id': 'r/a',
      'elder_id': 'e',
      'caregiver_id': 'c',
      'elder_email': 'e@example.test',
      'status': 'pending',
      'version': 1,
      'expires_at': '2099-01-01T00:00:00Z'
    };
Map<String, dynamic> blockJson() => {
      'elder_id': 'e',
      'caregiver_id': 'c',
      'active': true,
      'version': 2,
      'operation_id': 'op',
      'operation_type': 'block'
    };
Map<String, dynamic> linkJson() => {
      'id': 'l',
      'elder_id': 'e',
      'caregiver_id': 'c',
      'status': 'active',
      'authorization_epoch': 3,
      'scopes': ['family_messages']
    };
void main() {
  test('production exposes optional captured support capability', () {
    expect(
        RestApiClient(
            client: MockClient((r) async => http.Response('{}', 200))),
        isA<FamilySupportPreviewApi>());
  });

  test('support without captured family authorization fails before transport',
      () async {
    var calls = 0;
    final api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await expectLater(
        api.sendSupportRequest(
            emergencyContactId: 'contact',
            message: 'Help',
            idempotencyKey: 'key'),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 422)));
    expect(calls, 0);
  });
  test('support sends captured link and epoch with original support key',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(client: MockClient((r) async {
      requests.add(r);
      return http.Response('{}', 200);
    }));
    await api.sendSupportRequestForPreview(
        emergencyContactId: 'contact',
        message: 'Help',
        idempotencyKey: 'stable-key',
        safetyEventId: 'event',
        familyLinkId: 'captured-link',
        expectedAuthorizationEpoch: 3);
    expect(requests.length, 1);
    expect(requests.single.url.path, '/safety/support-request');
    expect(requests.single.method, 'POST');
    expect(requests.single.headers['Idempotency-Key'], 'stable-key');
    expect(jsonDecode(requests.single.body), {
      'emergency_contact_id': 'contact',
      'message': 'Help',
      'idempotency_key': 'stable-key',
      'safety_event_id': 'event',
      'family_link_id': 'captured-link',
      'expected_authorization_epoch': 3
    });
  });
  test('stale support capture remains410 without lookup or automatic upgrade',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(client: MockClient((r) async {
      requests.add(r);
      return http.Response('{"detail":"Stale support preview"}', 410);
    }));
    await expectLater(
        api.sendSupportRequest(
            emergencyContactId: 'contact',
            message: 'Help',
            idempotencyKey: 'stable-key',
            familyLinkId: 'old-link',
            expectedAuthorizationEpoch: 1),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 410)));
    expect(requests.length, 1);
    expect(jsonDecode(requests.single.body)['family_link_id'], 'old-link');
    expect(jsonDecode(requests.single.body)['expected_authorization_epoch'], 1);
  });

  test('legacy normal send without captured link fails before transport',
      () async {
    var calls = 0;
    final api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{"id":"m"}', 200);
    }));
    await expectLater(
        api.sendFamilyMessage(
            recipientId: 'c', content: 'body', clientMessageId: 'key'),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 422)));
    expect(calls, 0);
  });
  test('legacy story send without captured link fails before transport',
      () async {
    var calls = 0;
    final api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{"id":"m"}', 200);
    }));
    await expectLater(
        api.sendFamilyMessageAtRevision(
            recipientId: 'c',
            content: 'body',
            clientMessageId: 'key',
            sourceStoryId: 's',
            expectedRevision: 4),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 422)));
    expect(calls, 0);
  });
  test('production exposes captured family message preview capability', () {
    expect(
        RestApiClient(
            client: MockClient((r) async => http.Response('{}', 200))),
        isA<FamilyMessagePreviewApi>());
  });
  test(
      'plain and story previews serialize captured link epoch key and revision',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(
        accessToken: 'token',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('{"id":"m"}', 200);
        }));
    await api.sendFamilyMessageForPreview(
        recipientId: 'c',
        content: 'Plain',
        clientMessageId: 'plain-key',
        familyLinkId: 'captured/link',
        expectedAuthorizationEpoch: 3);
    await api.sendFamilyMessageForPreview(
        recipientId: 'c',
        content: 'Story',
        clientMessageId: 'story-key',
        familyLinkId: 'captured/link',
        expectedAuthorizationEpoch: 3,
        sourceStoryId: 's',
        expectedRevision: 4);
    expect(requests.length, 2);
    expect(jsonDecode(requests[0].body), {
      'recipient_id': 'c',
      'content': 'Plain',
      'client_message_id': 'plain-key',
      'family_link_id': 'captured/link',
      'expected_authorization_epoch': 3
    });
    expect(jsonDecode(requests[1].body), {
      'recipient_id': 'c',
      'content': 'Story',
      'client_message_id': 'story-key',
      'family_link_id': 'captured/link',
      'expected_authorization_epoch': 3,
      'source_story_id': 's'
    });
    expect(requests[0].headers['X-Memory-Revision'], isNull);
    expect(requests[1].headers['X-Memory-Revision'], '4');
    expect(requests[0].headers['Idempotency-Key'], 'plain-key');
    expect(requests[1].headers['Idempotency-Key'], 'story-key');
    for (final request in requests) {
      expect(request.method, 'POST');
      expect(request.url.path, '/family-messages');
      expect(request.headers['Authorization'], 'Bearer token');
    }
  });
  test(
      'invalid preview authorization or missing story revision never queries current link',
      () async {
    var calls = 0;
    final dynamic api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{"id":"m"}', 200);
    }));
    for (final pair in [('', 1), ('l', 0), ('l', -1)]) {
      await expectLater(
          api.sendFamilyMessageForPreview(
              recipientId: 'c',
              content: 'body',
              clientMessageId: 'key',
              familyLinkId: pair.$1,
              expectedAuthorizationEpoch: pair.$2),
          throwsA(
              isA<ApiException>().having((e) => e.statusCode, 'status', 422)));
    }
    await expectLater(
        api.sendFamilyMessageForPreview(
            recipientId: 'c',
            content: 'body',
            clientMessageId: 'key',
            familyLinkId: 'l',
            expectedAuthorizationEpoch: 1,
            sourceStoryId: 's'),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 422)));
    expect(calls, 0);
  });
  test('stale captured preview is propagated without epoch lookup or retry',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(client: MockClient((r) async {
      requests.add(r);
      return http.Response('{"detail":"Expired preview"}', 410);
    }));
    await expectLater(
        api.sendFamilyMessageForPreview(
            recipientId: 'c',
            content: 'body',
            clientMessageId: 'stable-key',
            familyLinkId: 'old-link',
            expectedAuthorizationEpoch: 2),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 410)));
    expect(requests.length, 1);
    expect(jsonDecode(requests.single.body)['expected_authorization_epoch'], 2);
  });

  test('missing invitation scopes never infer care task authorization', () {
    expect(FamilyInvitation.fromJson({'id': 'l', 'status': 'accepted'}).scopes,
        isEmpty);
  });
  test('link authorization requires explicit epoch pair status and scopes', () {
    expect(FamilyInvitation.fromJson(linkJson()).actionable, isTrue);
    for (final key in [
      'id',
      'elder_id',
      'caregiver_id',
      'status',
      'authorization_epoch',
      'scopes'
    ]) {
      expect(FamilyInvitation.fromJson({...linkJson()}..remove(key)).actionable,
          isFalse,
          reason: key);
    }
    for (final value in [null, '3', 3.0, 0, -1]) {
      final link = FamilyInvitation.fromJson(
          {...linkJson(), 'authorization_epoch': value});
      expect(link.actionable, isFalse);
    }
    expect(FamilyInvitation.fromJson({'status': 'approved'}).status,
        InvitationStatus.unknown);
  });
  test('malformed invitation identity and scopes cannot authorize', () {
    for (final key in ['id', 'elder_id', 'caregiver_id']) {
      for (final value in [7, true]) {
        expect(
            FamilyInvitation.fromJson({...linkJson(), key: value}).actionable,
            isFalse,
            reason: key);
      }
    }
  });
  test('malformed or duplicate scopes cannot authorize', () {
    for (final scopes in [
      [
        {'name': 'family_messages'}
      ],
      ['family_messages', 7],
      ['family_messages', ''],
      ['family_messages', 'family_messages']
    ]) {
      expect(
          FamilyInvitation.fromJson({...linkJson(), 'scopes': scopes})
              .actionable,
          isFalse);
    }
  });
  test('request parsing preserves exact fields and fails closed', () {
    final request = FamilyConnectionRequest.fromJson({
      ...requestJson(),
      'requester_name': 'Same',
      'requester_email': 'c@example.test'
    });
    expect(request.id, 'r/a');
    expect(request.version, 1);
    expect(request.actionable, isTrue);
    expect(request.requesterEmail, 'c@example.test');
    for (final key in [
      'id',
      'elder_id',
      'caregiver_id',
      'status',
      'version',
      'expires_at'
    ]) {
      expect(
          FamilyConnectionRequest.fromJson({...requestJson()}..remove(key))
              .actionable,
          isFalse,
          reason: key);
    }
    for (final value in [null, '1', 1.0, 0, -1]) {
      expect(
          FamilyConnectionRequest.fromJson({...requestJson(), 'version': value})
              .actionable,
          isFalse);
    }
    for (final status in ['accepted', 'active', 'PENDING', 'future']) {
      expect(FamilyRequestStatus.fromJson(status), FamilyRequestStatus.unknown);
    }
    for (final status in ['approved', 'rejected', 'revoked', 'expired']) {
      expect(
          FamilyConnectionRequest.fromJson({...requestJson(), 'status': status})
              .actionable,
          isFalse);
    }
    expect(
        FamilyConnectionRequest.fromJson(
            {...requestJson(), 'expires_at': '2000-01-01'}).actionable,
        isFalse);
  });
  test('block requires explicit boolean and stable positive version', () {
    final block = FamilyBlock.fromJson(blockJson());
    expect(block.actionable, isTrue);
    expect(block.active, isTrue);
    expect(block.operationId, 'op');
    expect(FamilyBlock.fromJson({...blockJson(), 'active': false}).actionable,
        isTrue);
    for (final value in [null, 'true', 1]) {
      final block = FamilyBlock.fromJson({...blockJson(), 'active': value});
      expect(block.active, isNull);
      expect(block.actionable, isFalse);
    }
    for (final key in ['elder_id', 'caregiver_id', 'version']) {
      expect(FamilyBlock.fromJson({...blockJson()}..remove(key)).actionable,
          isFalse);
    }
  });
  test('sender history retains original and explicit withdrawal metadata', () {
    final m = FamilyMessage.fromJson({
      'id': 'm',
      'sender_id': 'e',
      'recipient_id': 'c',
      'content': 'Original',
      'link_epoch': 3,
      'access_revoked_at': '2026-01-01T00:00:00Z',
      'access_revocation_reason': 'blocked'
    });
    expect(m.content, 'Original');
    expect(m.linkEpoch, 3);
    expect(m.isAccessWithdrawn, isTrue);
    expect(m.accessRevocationReason, 'blocked');
    expect(m.recipientName, isNull);
    expect(FamilyMessage.fromJson({'link_epoch': '3'}).linkEpoch, isNull);
    expect(FamilyMessage.fromJson({}).isAccessWithdrawn, isFalse);
  });
  test('production API offers optional family interface', () {
    expect(
        RestApiClient(
            client: MockClient((r) async => http.Response('{}', 200))),
        isA<FamilyConnectionApi>());
  });
  test('all family methods use exact routes bodies token and captured ids',
      () async {
    final calls = <http.Request>[];
    final dynamic api = RestApiClient(
        origin: 'http://localhost',
        accessToken: 'token',
        client: MockClient((r) async {
          calls.add(r);
          if (r.url.path == '/family-messages/sent') {
            return http.Response(
                '[{"id":"m","content":"Original","access_revoked_at":"2026-01-01"}]',
                200);
          }
          if (r.url.path.contains('blocks')) {
            return http.Response(
                jsonEncode(r.method == 'GET' ? [blockJson()] : blockJson()),
                200);
          }
          if (jsonDecode(r.body.isEmpty ? '{}' : r.body)['decision'] ==
              'approve') {
            return http.Response(jsonEncode(linkJson()), 200);
          }
          return http.Response(
              jsonEncode(r.method == 'GET' ? [requestJson()] : requestJson()),
              200);
        }));
    expect((await api.listConnectionRequests()).single.id, 'r/a');
    await api.createConnectionRequest(
        elderEmail: 'e@example.test', clientRequestId: 'key');
    expect(
        (await api.approveConnectionRequest(
                requestId: 'r/a',
                expectedVersion: 1,
                scopes: ['family_messages']))
            .authorizationEpoch,
        3);
    await api.rejectConnectionRequest(requestId: 'r/a', expectedVersion: 1);
    await api.withdrawConnectionRequest(requestId: 'r/a', expectedVersion: 1);
    await api.listFamilyBlocks();
    await api.blockFamilyPair(
        caregiverId: 'c', requestId: 'r/a', clientOperationId: 'op');
    await api.blockFamilyPair(
        caregiverId: 'c', linkId: 'l/a', clientOperationId: 'op2');
    await api.unblockFamilyPair(
        caregiverId: 'c/a', expectedVersion: 2, clientOperationId: 'op3');
    expect(
        (await api.listSentFamilyMessages()).single.isAccessWithdrawn, isTrue);
    expect(calls.map((r) => '${r.method} ${r.url.path}').toList(), [
      'GET /family-links/requests',
      'POST /family-links/requests',
      'POST /family-links/requests/r%2Fa/decision',
      'POST /family-links/requests/r%2Fa/decision',
      'POST /family-links/requests/r%2Fa/withdraw',
      'GET /family-links/blocks',
      'POST /family-links/blocks',
      'POST /family-links/blocks',
      'POST /family-links/blocks/c%2Fa/unblock',
      'GET /family-messages/sent'
    ]);
    expect(jsonDecode(calls[1].body),
        {'elder_email': 'e@example.test', 'client_request_id': 'key'});
    expect(jsonDecode(calls[2].body), {
      'decision': 'approve',
      'expected_version': 1,
      'scopes': ['family_messages']
    });
    expect(jsonDecode(calls[3].body),
        {'decision': 'reject', 'expected_version': 1});
    expect(jsonDecode(calls[4].body), {'expected_version': 1});
    expect(jsonDecode(calls[6].body), {
      'caregiver_id': 'c',
      'request_id': 'r/a',
      'client_operation_id': 'op'
    });
    expect(jsonDecode(calls[7].body),
        {'caregiver_id': 'c', 'link_id': 'l/a', 'client_operation_id': 'op2'});
    expect(jsonDecode(calls[8].body),
        {'expected_version': 2, 'client_operation_id': 'op3'});
    for (final call in calls) {
      expect(call.headers['Authorization'], 'Bearer token');
    }
  });
  for (final status in [403, 409, 410, 422, 500]) {
    test('$status is propagated with one request and no fallback', () async {
      var calls = 0;
      final dynamic api = RestApiClient(client: MockClient((r) async {
        calls++;
        return http.Response('{"detail":"Denied"}', status);
      }));
      await expectLater(
          api.approveConnectionRequest(
              requestId: 'r', expectedVersion: 1, scopes: ['care_tasks']),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', status)));
      expect(calls, 1);
    });
  }
  test('timeout propagates without automatic retry', () async {
    var calls = 0;
    final dynamic api = RestApiClient(
        requestTimeout: const Duration(milliseconds: 1),
        client: MockClient((r) async {
          calls++;
          return Completer<http.Response>().future;
        }));
    await expectLater(
        api.createConnectionRequest(
            elderEmail: 'e@example.test', clientRequestId: 'same'),
        throwsA(isA<ApiException>()));
    expect(calls, 1);
  });
}
