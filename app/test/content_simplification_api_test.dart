import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const source = 'A fictional answer that needs clearer wording.';
Map<String, Object?> good() => {
      'status': 'draft',
      'original': source,
      'simpler': 'A clearer fictional answer.',
      'reason': null,
      'independently_verified': false
    };
void main() {
  test('independent endpoint uses existing auth and sends selected text only',
      () async {
    late http.Request request;
    final api = RestApiClient(
        origin: 'https://example.invalid',
        accessToken: 'synthetic-token',
        client: MockClient((r) async {
          request = r;
          return http.Response(jsonEncode(good()), 200);
        }));
    final result = await api.simplifyContent(
        original: source, locale: 'en', explicitlyRequested: true);
    expect(result.original, source);
    expect(request.headers['Authorization'], 'Bearer synthetic-token');
    expect(request.url.path, '/content/simplifications');
    expect(jsonDecode(request.body),
        {'text': source, 'locale': 'en', 'explicit_request': true});
  });
  test('implicit request is refused locally', () async {
    var calls = 0;
    final api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await expectLater(
        api.simplifyContent(
            original: source, locale: 'en', explicitlyRequested: false),
        throwsA(isA<ContentSimplificationException>()));
    expect(calls, 0);
  });
  for (final name in [
    'missing',
    'wrong-original',
    'verified',
    'empty',
    'overlong',
    'unknown-state',
    'raw-json',
    'unchanged'
  ]) {
    test('invalid DTO $name is never a draft', () async {
      final value = good();
      switch (name) {
        case 'missing':
          value.remove('independently_verified');
        case 'wrong-original':
          value['original'] = 'another version';
        case 'verified':
          value['independently_verified'] = true;
        case 'empty':
          value['simpler'] = '';
        case 'overlong':
          value['simpler'] = 'x' * 10000;
        case 'unknown-state':
          value['status'] = 'success';
        case 'raw-json':
          value['simpler'] = '{"text":"partial';
        case 'unchanged':
          value['simpler'] = source;
      }
      final api = RestApiClient(
          client:
              MockClient((r) async => http.Response(jsonEncode(value), 200)));
      await expectLater(
          api.simplifyContent(
              original: source, locale: 'en', explicitlyRequested: true),
          throwsA(isA<ContentSimplificationException>()));
    });
  }
  test('model unavailable remains a typed honest failure', () async {
    final value = good()
      ..['status'] = 'unavailable'
      ..['simpler'] = null
      ..['reason'] = 'model_unavailable';
    final api = RestApiClient(
        client: MockClient((r) async => http.Response(jsonEncode(value), 200)));
    await expectLater(
        api.simplifyContent(
            original: source, locale: 'en', explicitlyRequested: true),
        throwsA(isA<ContentSimplificationException>()
            .having((e) => e.reason, 'reason', 'model_unavailable')));
  });
}
