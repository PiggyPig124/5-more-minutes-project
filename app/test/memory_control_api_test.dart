import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('legacy writes cannot bypass snapshot', () async {
    var calls = 0;
    final api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          calls++;
          return http.Response('{"id":"m","content":"c","kind":"note"}', 200);
        }));
    await expectLater(
        api.createMemory(content: 'c', kind: 'note'),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 422)));
    await expectLater(api.createStory(title: 't', content: 'c', memoryIds: []),
        throwsA(isA<ApiException>()));
    expect(calls, 0);
  });
  test('nullable snapshot preserves zero and chat metadata', () {
    final dynamic m = MemoryRecord.fromJson({'revision': 0});
    final dynamic missing = MemoryRecord.fromJson({});
    expect(m.revision, 0);
    expect(missing.revision, isNull);
    final dynamic message = ChatMessage.fromJson({'memory_revision': 7});
    expect(message.memoryRevision, 7);
  });
  test('save uses captured header and returned revision', () async {
    late http.Request request;
    final dynamic api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          request = r;
          return http.Response(
              '{"id":"m","content":"c","kind":"note","revision":8}', 200);
        }));
    final dynamic m = await api.saveConfirmedMemoryAtRevision(
        content: 'c', kind: 'note', expectedRevision: 7);
    expect(m.revision, 8);
    expect(request.headers['X-Memory-Revision'], '7');
    expect(jsonDecode(request.body), {'content': 'c', 'kind': 'note'});
  });
  test('409 never refetches or retries obsolete operation', () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('{"detail":"stale"}', 409);
        }));
    await expectLater(
        api.confirmMemoryAtRevision('m', expectedRevision: 4),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 409)));
    expect(requests.length, 1);
    expect(requests.single.headers['X-Memory-Revision'], '4');
  });
  test('retry retains original deletion key snapshot and exact ids', () async {
    final requests = <http.Request>[];
    final dynamic api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(
              '{"request_id":"receipt","revision":9,"counts":{"memories":2,"stories":1}}',
              200);
        }));
    for (var i = 0; i < 2; i++) {
      final dynamic receipt = await api.deleteMemories(
          mode: 'selected',
          memoryIds: <String>['a', 'b'],
          expectedRevision: 8,
          idempotencyKey: 'original');
      expect(receipt.revision, 9);
      expect(receipt.counts['memories'], 2);
    }
    expect(requests.length, 2);
    expect(requests[0].body, requests[1].body);
    expect(jsonDecode(requests[0].body), {
      'mode': 'selected',
      'memory_ids': ['a', 'b'],
      'expected_revision': 8,
      'idempotency_key': 'original'
    });
  });
}
