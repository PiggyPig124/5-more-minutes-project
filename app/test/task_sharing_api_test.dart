import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'helpers.dart';

const utf8Json = {'content-type': 'application/json; charset=utf-8'};
Map<String, dynamic> receipt({bool revoked = false}) => {
      'id': 'share',
      'task_id': 'task/1',
      'family_link_id': 'link',
      'shared_by': 'elder',
      'content_hash': 'a' * 64,
      'consented_at': '2026-10-03T10:00:00Z',
      'revoked_at': revoked ? '2026-10-03T11:00:00Z' : null,
      'revocation_reason': revoked ? 'owner_revoked' : null,
      'caregiver_id': 'caregiver',
      'caregiver_name': '照顧者陳先生',
    };
void main() {
  test(
      'optional sharing support leaves existing FakeApi implementation compatible',
      () {
    expect(FakeApi(), isA<AnxinApi>());
  });
  test(
      'GET task detail preserves current owner preview content and fingerprint',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(
        origin: 'http://local.test',
        accessToken: 'token',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
              jsonEncode({
                'id': 'task/1',
                'owner_id': 'elder',
                'access_mode': 'owner',
                'task_type': 'appointment',
                'title': '到中心見面',
                'description': '帶雨傘及詳細資料',
                'due_at': '2026-10-08T09:00:00Z',
                'content_hash': 'a' * 64,
                'status': 'pending'
              }),
              200,
              headers: utf8Json);
        }));
    final CareTask result = await api.getTaskDetail('task/1');
    expect(requests.single.method, 'GET');
    expect(requests.single.url.toString(), 'http://local.test/tasks/task%2F1');
    expect(requests.single.headers['Authorization'], 'Bearer token');
    expect(result.title, '到中心見面');
    expect(result.description, '帶雨傘及詳細資料');
    expect(result.contentHash, 'a' * 64);
    expect(result.accessMode, 'owner');
  });
  test(
      'GET shares parses active and revoked owner receipts without losing recipient identity',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(
        origin: 'http://local.test',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
              jsonEncode([receipt(), receipt(revoked: true)]), 200,
              headers: utf8Json);
        }));
    final dynamic shares = await api.listTaskShares('task/1');
    expect(requests.single.method, 'GET');
    expect(requests.single.url.toString(),
        'http://local.test/tasks/task%2F1/shares');
    expect(shares.length, 2);
    final dynamic active = shares.first;
    expect(active.id, 'share');
    expect(active.taskId, 'task/1');
    expect(active.familyLinkId, 'link');
    expect(active.sharedBy, 'elder');
    expect(active.contentHash, 'a' * 64);
    expect(active.caregiverId, 'caregiver');
    expect(active.caregiverName, '照顧者陳先生');
    expect(
        active.consentedAt, DateTime.parse('2026-10-03T10:00:00Z').toLocal());
    expect(active.revokedAt, isNull);
    expect(active.isActive, isTrue);
    expect(shares.last.revokedAt,
        DateTime.parse('2026-10-03T11:00:00Z').toLocal());
    expect(shares.last.revocationReason, 'owner_revoked');
    expect(shares.last.isActive, isFalse);
  });
  test('POST share sends only explicit recipient fingerprint and retry key',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(
        origin: 'http://local.test',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode(receipt()), 201, headers: utf8Json);
        }));
    final dynamic result = await api.createTaskShare(
        taskId: 'task/1',
        familyLinkId: 'link',
        expectedContentHash: 'a' * 64,
        idempotencyKey: 'same-confirmation-key');
    expect(requests.single.method, 'POST');
    expect(requests.single.url.toString(),
        'http://local.test/tasks/task%2F1/shares');
    expect(jsonDecode(requests.single.body), {
      'family_link_id': 'link',
      'expected_content_hash': 'a' * 64,
      'idempotency_key': 'same-confirmation-key',
    });
    expect(result.id, 'share');
    expect(result.isActive, isTrue);
  });
  test(
      'DELETE share returns verified revocation receipt with encoded identifiers',
      () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(
        origin: 'http://local.test',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
              jsonEncode({...receipt(revoked: true), 'id': 'share/1'}), 200,
              headers: utf8Json);
        }));
    final dynamic result =
        await api.revokeTaskShare(taskId: 'task/1', shareId: 'share/1');
    expect(requests.single.method, 'DELETE');
    expect(requests.single.url.toString(),
        'http://local.test/tasks/task%2F1/shares/share%2F1');
    expect(requests.single.body, isEmpty);
    expect(result.id, 'share/1');
    expect(result.taskId, 'task/1');
    expect(result.revokedAt, isNotNull);
    expect(result.isActive, isFalse);
  });
  for (final status in [403, 409]) {
    test('share status $status propagates as failure instead of receipt',
        () async {
      final dynamic api = RestApiClient(
          client: MockClient((request) async => http.Response(
              '{"detail":"Share rejected"}', status,
              headers: utf8Json)));
      await expectLater(
          () async => await api.createTaskShare(
              taskId: 'task/1',
              familyLinkId: 'link',
              expectedContentHash: 'a' * 64,
              idempotencyKey: 'key'),
          throwsA(isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', status)));
    });
  }
  test('empty successful share response is not accepted as a consent receipt',
      () async {
    final dynamic api = RestApiClient(
        client: MockClient(
            (request) async => http.Response('{}', 201, headers: utf8Json)));
    await expectLater(
        () async => await api.createTaskShare(
            taskId: 'task/1',
            familyLinkId: 'link',
            expectedContentHash: 'a' * 64,
            idempotencyKey: 'key'),
        throwsA(isA<ApiException>()));
  });
  test('malformed sharing history cannot pretend no active grants exist',
      () async {
    for (final body in ['{}', '[null]', '[42]']) {
      final api = RestApiClient(
          client: MockClient(
              (request) async => http.Response(body, 200, headers: utf8Json)));
      await expectLater(
          api.listTaskShares('task'), throwsA(isA<ApiException>()));
    }
  });
}
