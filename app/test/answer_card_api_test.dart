import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'answer_card_fixtures.dart';

void main() {
  test('RestApiClient exposes optional answer card capability', () {
    expect(RestApiClient(), isA<AnswerCardApi>());
  });
  test('templates list prepare and owned list use exact routes and bearer',
      () async {
    final requests = <http.Request>[];
    final api = RestApiClient(
        origin: 'http://localhost:8000',
        client: MockClient((r) async {
          requests.add(r);
          expect(r.headers['Authorization'], 'Bearer synthetic-token');
          final body = switch (r.url.path) {
            '/answer-card-templates' => [answerTemplateFixture()],
            '/answer-cards/prepare' => answerDraftFixture(),
            _ => [answerCardFixture()]
          };
          return http.Response(jsonEncode(body), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }))
      ..accessToken = 'synthetic-token';
    expect((await api.listAnswerCardTemplates()).single.language, 'zh');
    expect((await api.prepareAnswerCard('message-1')).sourceHash, answerHash);
    final cards = await api.listAnswerCards();
    expect(cards.single.id, 'card-1');
    expect(() => cards.clear(), throwsUnsupportedError);
    expect(requests.map((r) => r.method), ['GET', 'POST', 'GET']);
    expect(jsonDecode(requests[1].body), {'source_message_id': 'message-1'});
  });
  test('create patch delete preserve captured payload and operation keys',
      () async {
    final requests = <http.Request>[];
    final api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(
              jsonEncode(r.method == 'DELETE'
                  ? {'id': 'card/1', 'version': 3, 'deleted': true}
                  : (answerCardFixture()
                    ..['id'] = 'card/1'
                    ..['version'] = (r.method == 'PATCH' ? 2 : 1))),
              r.method == 'POST' ? 201 : 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    await api.createAnswerCard(answerCreateFixture());
    await api.updateAnswerCard('card/1', answerUpdateFixture());
    await api.deleteAnswerCard(
        cardId: 'card/1', expectedVersion: 2, clientOperationId: 'delete-key');
    expect(requests.map((r) => r.method), ['POST', 'PATCH', 'DELETE']);
    expect(
        requests[1].url.toString(), 'http://localhost/answer-cards/card%2F1');
    expect(jsonDecode(requests[0].body), answerCreateFixture());
    expect(jsonDecode(requests[1].body), answerUpdateFixture());
    expect(jsonDecode(requests[2].body),
        {'expected_version': 2, 'client_operation_id': 'delete-key'});
  });
  test('missing captured version rejected locally without request', () async {
    var calls = 0;
    final api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await expectLater(
        api.updateAnswerCard(
            'card-1', answerUpdateFixture()..remove('expected_version')),
        throwsA(isA<ApiException>()));
    expect(calls, 0);
  });
  test('strict malformed responses cannot report success', () async {
    for (final body in [
      null,
      {},
      answerCardFixture()..remove('version'),
      answerCardFixture()..['context'] = {},
      answerCardFixture()..['version'] = '1'
    ]) {
      final api = RestApiClient(
          client: MockClient((r) async => http.Response(jsonEncode(body), 201,
              headers: {'content-type': 'application/json; charset=utf-8'})));
      await expectLater(api.createAnswerCard(answerCreateFixture()),
          throwsA(isA<ApiException>()));
    }
  });
  test('create receipt must preserve captured origin identity and hash',
      () async {
    for (final key in ['origin_message_id', 'origin_hash']) {
      final raw = answerCardFixture();
      (raw['provenance'] as Map)[key] = key == 'origin_hash'
          ? 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
          : 'foreign-message';
      final api = RestApiClient(
          client: MockClient((r) async => http.Response(jsonEncode(raw), 201,
              headers: {'content-type': 'application/json; charset=utf-8'})));
      await expectLater(api.createAnswerCard(answerCreateFixture()),
          throwsA(isA<ApiException>()));
    }
  });
  test(
      'create receipt binds sent origin even if caller edits request while pending',
      () async {
    final request = answerCreateFixture();
    final api = RestApiClient(client: MockClient((r) async {
      expect((jsonDecode(r.body) as Map)['origin']['message_id'], 'message-1');
      (request['origin'] as Map)['message_id'] = 'foreign-message';
      final raw = answerCardFixture();
      (raw['provenance'] as Map)['origin_message_id'] = 'foreign-message';
      return http.Response(jsonEncode(raw), 201,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    await expectLater(
        api.createAnswerCard(request), throwsA(isA<ApiException>()));
  });
  test('mutation receipts must match requested card and advance version',
      () async {
    for (final raw in [
      answerCardFixture(),
      answerCardFixture()
        ..['id'] = 'foreign'
        ..['version'] = 2
    ]) {
      final api = RestApiClient(
          client: MockClient((r) async => http.Response(jsonEncode(raw), 200,
              headers: {'content-type': 'application/json; charset=utf-8'})));
      await expectLater(api.updateAnswerCard('card-1', answerUpdateFixture()),
          throwsA(isA<ApiException>()));
    }
    final api = RestApiClient(
        client: MockClient((r) async =>
            http.Response('{"id":"foreign","version":2,"deleted":true}', 200)));
    await expectLater(
        api.deleteAnswerCard(
            cardId: 'card-1', expectedVersion: 1, clientOperationId: 'key'),
        throwsA(isA<ApiException>()));
  });
  test('409 and 410 never trigger automatic refresh or retry', () async {
    for (final status in [409, 410]) {
      var calls = 0;
      final api = RestApiClient(client: MockClient((r) async {
        calls++;
        return http.Response('{"detail":"Changed"}', status);
      }));
      await expectLater(
          api.createAnswerCard(answerCreateFixture()),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', status)));
      expect(calls, 1);
    }
  });
  test('timeout remains uncertain and never retries original operation',
      () async {
    var calls = 0;
    final api = RestApiClient(
        requestTimeout: const Duration(milliseconds: 1),
        client: MockClient((r) {
          calls++;
          return Completer<http.Response>().future;
        }));
    await expectLater(
        api.createAnswerCard(answerCreateFixture()),
        throwsA(isA<ApiException>()
            .having((e) => e.cause, 'cause', isA<TimeoutException>())));
    expect(calls, 1);
  });
}
