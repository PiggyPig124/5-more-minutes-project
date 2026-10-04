import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('PATCH sends only edited text with captured revision and encoded id',
      () async {
    late http.Request request;
    final dynamic api = RestApiClient(
        origin: 'http://localhost',
        client: MockClient((r) async {
          request = r;
          return http.Response(
              jsonEncode({
                'id': 'card/a',
                'title': 'Edited',
                'content': 'New text',
                'memory_ids': ['m'],
                'revision': 8
              }),
              200);
        }));
    final story = await api.updateStoryAtRevision('card/a',
        title: 'Edited', content: 'New text', expectedRevision: 7);
    expect(request.method, 'PATCH');
    expect(request.url.path, '/stories/card%2Fa');
    expect(request.headers['X-Memory-Revision'], '7');
    expect(
        jsonDecode(request.body), {'title': 'Edited', 'content': 'New text'});
    expect(story.id, 'card/a');
    expect(story.revision, 8);
    expect(story.memoryIds, ['m']);
  });

  test('negative captured revision is rejected before HTTP', () async {
    var calls = 0;
    final dynamic api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await expectLater(
        api.updateStoryAtRevision('s',
            title: 't', content: 'c', expectedRevision: -1),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 422)));
    expect(calls, 0);
  });

  for (final status in [403, 409, 422, 500]) {
    test('$status preserves failure without refetch or retry', () async {
      final requests = <http.Request>[];
      final dynamic api = RestApiClient(client: MockClient((r) async {
        requests.add(r);
        return http.Response('{"detail":"rejected"}', status);
      }));
      await expectLater(
          api.updateStoryAtRevision('s',
              title: 't', content: 'c', expectedRevision: 7),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', status)));
      expect(requests.length, 1);
      expect(requests.single.headers['X-Memory-Revision'], '7');
    });
  }

  final invalid = <String, Object?>{
    'missing receipt': null,
    'missing id': {'title': 't', 'content': 'c', 'revision': 8},
    'different id': {
      'id': 'other',
      'title': 't',
      'content': 'c',
      'revision': 8
    },
    'missing revision': {'id': 's', 'title': 't', 'content': 'c'},
    'negative revision': {'id': 's', 'revision': -1},
    'unchanged revision': {'id': 's', 'revision': 7},
    'older revision': {'id': 's', 'revision': 6},
    'string revision': {'id': 's', 'revision': '8'},
    'fraction revision': {'id': 's', 'revision': 8.5},
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} instead of reporting edit success', () async {
      final dynamic api = RestApiClient(
          client: MockClient(
              (r) async => http.Response(jsonEncode(entry.value), 200)));
      await expectLater(
          api.updateStoryAtRevision('s',
              title: 't', content: 'c', expectedRevision: 7),
          throwsA(isA<ApiException>()));
    });
  }
  final invalidFields = <String, Map<String, Object?>>{
    'missing title': {'title': null},
    'blank title': {'title': '   '},
    'nonstring title': {'title': 42},
    'different title': {'title': 'other'},
    'untrimmed title': {'title': ' t '},
    'missing content': {'content': null},
    'blank content': {'content': '   '},
    'nonstring content': {'content': false},
    'different content': {'content': 'other'},
    'untrimmed content': {'content': ' c '},
    'missing sources': {'memory_ids': null},
    'nonlist sources': {'memory_ids': 'm'},
    'mixed sources': {
      'memory_ids': ['m', 42]
    },
    'blank source': {
      'memory_ids': ['']
    },
    'whitespace source': {
      'memory_ids': [' m ']
    },
    'duplicate sources': {
      'memory_ids': ['m', 'm']
    },
  };
  for (final entry in invalidFields.entries) {
    test('rejects receipt with ${entry.key}', () async {
      final receipt = <String, Object?>{
        'id': 's',
        'revision': 8,
        'title': 't',
        'content': 'c',
        'memory_ids': ['m'],
        ...entry.value
      };
      receipt.removeWhere((key, value) => value == null);
      final api = RestApiClient(
          client:
              MockClient((r) async => http.Response(jsonEncode(receipt), 200)));
      await expectLater(
          api.updateStoryAtRevision('s',
              title: 't', content: 'c', expectedRevision: 7),
          throwsA(isA<ApiException>()));
    });
  }
  test('accepts canonical server trim of requested text', () async {
    final api = RestApiClient(
        client: MockClient((r) async => http.Response(
            jsonEncode({
              'id': 's',
              'revision': 8,
              'title': 't',
              'content': 'c',
              'memory_ids': ['m']
            }),
            200)));
    final story = await api.updateStoryAtRevision('s',
        title: ' t ', content: ' c ', expectedRevision: 7);
    expect(story.title, 't');
    expect(story.content, 'c');
  });
}
