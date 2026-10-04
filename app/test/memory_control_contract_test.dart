import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('deletion receipt must advance the original captured revision',
      () async {
    for (final revision in [3, 4]) {
      final api = RestApiClient(
          origin: 'http://localhost',
          client: MockClient((request) async => http.Response(
              jsonEncode({
                'request_id': 'receipt',
                'revision': revision,
                'counts': {'memories': 1}
              }),
              200)));
      await expectLater(
          api.deleteMemories(
              mode: 'selected',
              memoryIds: ['m'],
              expectedRevision: 4,
              idempotencyKey: 'original-key'),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'uncertain outcome', isNull)));
    }
  });

  test(
      'all reference mutations send explicit snapshot including empty-source story',
      () async {
    final requests = <http.Request>[];
    final api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          requests.add(r);
          Object body = {
            'id': 'm',
            'content': 'c',
            'kind': 'note',
            'revision': 3
          };
          if (r.url.path == '/memories/consent') {
            body = {
              'enabled': false,
              'revision': 3,
              'counts': {'total': 1, 'current': 1}
            };
          }
          if (r.url.path.contains('/skills/')) {
            body = r.method == 'GET'
                ? {
                    'items': [
                      {
                        'id': 'skill',
                        'suggestion': 's',
                        'status': 'suggested',
                        'revision': 2
                      }
                    ]
                  }
                : {
                    'id': 'skill',
                    'suggestion': 's',
                    'status': 'confirmed',
                    'revision': 2
                  };
          }
          if (r.url.path == '/stories') {
            body = {'id': 'story', 'title': 't', 'content': 'c', 'revision': 3};
          }
          if (r.url.path == '/family-messages') {
            body = {'id': 'family', 'content': 't\nc'};
          }
          return http.Response(r.method == 'DELETE' ? '' : jsonEncode(body),
              r.method == 'DELETE' ? 204 : 200);
        }));
    final MemoryControlApi controls = api;
    expect(
        (await controls.setMemoryConsentAtRevision(false, expectedRevision: 2))
            .revision,
        3);
    await controls.createMemoryAtRevision(
        content: 'c', kind: 'note', expectedRevision: 2);
    await controls.updateMemoryAtRevision('m',
        content: 'new', expectedRevision: 2);
    await controls.confirmMemoryAtRevision('m', expectedRevision: 2);
    await controls.deleteMemoryAtRevision('m',
        expectedRevision: 2, idempotencyKey: 'delete-key');
    expect(
        (await controls.listSkillSuggestionsAtRevision(expectedRevision: 2))
            .single
            .revision,
        2);
    await controls.decideSkillAtRevision('skill',
        decision: 'confirm', skill: 'edited', expectedRevision: 2);
    await controls.createStoryAtRevision(
        title: 't', content: 'c', memoryIds: [], expectedRevision: 2);
    await controls.deleteStoryAtRevision('story', expectedRevision: 2);
    await api.sendFamilyMessageAtRevision(
        familyLinkId: 'captured-link',
        expectedAuthorizationEpoch: 3,
        recipientId: 'carer',
        content: 't\nc',
        clientMessageId: 'share-key',
        sourceStoryId: 'story',
        expectedRevision: 2);
    expect(requests.length, 10);
    for (final r in requests) {
      expect(r.headers['X-Memory-Revision'], '2', reason: r.url.path);
    }
    expect(requests[4].headers['Idempotency-Key'], 'delete-key');
    expect(jsonDecode(requests[7].body)['memory_ids'], isEmpty);
    expect(jsonDecode(requests.last.body)['source_story_id'], 'story');
    expect(requests.last.headers['Idempotency-Key'], 'share-key');
  });
  test(
      'control state read uses no guessed revision and ordinary family message stays compatible',
      () async {
    final requests = <http.Request>[];
    final api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(
              r.method == 'GET'
                  ? '{"enabled":true,"revision":0,"counts":{"total":0,"current":0}}'
                  : '{"id":"f","content":"hello"}',
              200);
        }));
    expect((await api.getMemoryControlState()).revision, 0);
    await api.sendFamilyMessage(
        familyLinkId: 'captured-link',
        expectedAuthorizationEpoch: 3,
        recipientId: 'carer',
        content: 'hello',
        clientMessageId: 'plain');
    expect(requests.every((r) => !r.headers.containsKey('X-Memory-Revision')),
        isTrue);
    await expectLater(
        api.sendFamilyMessage(
            recipientId: 'carer',
            content: 't\nc',
            clientMessageId: 'old',
            sourceStoryId: 's'),
        throwsA(isA<ApiException>()));
    expect(requests.length, 2);
  });
  test('invalid snapshots and delete requests never reach network', () async {
    var calls = 0;
    final api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          calls++;
          return http.Response('{}', 200);
        }));
    await expectLater(api.confirmMemoryAtRevision('m', expectedRevision: -1),
        throwsA(isA<ApiException>()));
    await expectLater(
        api.deleteMemoryAtRevision('m',
            expectedRevision: 0, idempotencyKey: ''),
        throwsA(isA<ApiException>()));
    await expectLater(
        api.deleteMemories(
            mode: 'selected', expectedRevision: 0, idempotencyKey: 'key'),
        throwsA(isA<ApiException>()));
    await expectLater(
        api.deleteMemories(
            mode: 'all',
            memoryIds: ['m'],
            expectedRevision: 0,
            idempotencyKey: 'key'),
        throwsA(isA<ApiException>()));
    expect(calls, 0);
  });
  test('missing revision in success response cannot confirm save', () async {
    final api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async =>
            http.Response('{"id":"m","content":"c","kind":"note"}', 200)));
    await expectLater(
        api.saveConfirmedMemoryAtRevision(
            content: 'c', kind: 'note', expectedRevision: 0),
        throwsA(isA<ApiException>()));
  });
  test(
      'control and deletion receipts reject absent malformed revisions and negative counts',
      () {
    for (final revision in [null, -1, '0', 0.0]) {
      expect(
          () => MemoryControlState.fromJson({
                'enabled': true,
                'revision': revision,
                'counts': {'total': 0}
              }),
          throwsFormatException);
      expect(
          () => MemoryDeletionReceipt.fromJson({
                'request_id': 'r',
                'revision': revision,
                'counts': {'memories': 0}
              }),
          throwsFormatException);
      expect(MemoryRecord.fromJson({'revision': revision}).revision, isNull);
      expect(StoryRecord.fromJson({'revision': revision}).revision, isNull);
      expect(SkillSuggestion.fromJson({'revision': revision}).revision, isNull);
    }
    expect(
        () => MemoryDeletionReceipt.fromJson({
              'request_id': 'r',
              'revision': 0,
              'counts': {'memories': -1}
            }),
        throwsFormatException);
    final receipt = MemoryDeletionReceipt.fromJson({
      'request_id': 'r',
      'revision': 0,
      'counts': {'memories': 0, 'unknown_related': 2},
      'content': 'discard'
    });
    expect(receipt.counts, {'memories': 0, 'unknown_related': 2});
    expect(MemorySuggestion.fromJson({'revision': 7}).revision, 7);
    expect(MemorySuggestion.fromJson({}).revision, isNull);
    expect(() => receipt.counts['memories'] = 1, throwsUnsupportedError);
  });
}
