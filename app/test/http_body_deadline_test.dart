import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class ControlledClient extends http.BaseClient {
  final headers = Completer<http.StreamedResponse>();
  late final StreamController<List<int>> body = StreamController(onCancel: () {
    cancelled = true;
  });
  bool cancelled = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      headers.future;
  void open() => headers.complete(http.StreamedResponse(body.stream, 200,
      headers: {'content-type': 'application/json'}));
  void finish() {
    body.add(utf8.encode(
        '{"id":"synthetic","display_name":"Synthetic","email":"synthetic@example.invalid","role":"elder"}'));
    body.close();
  }
}

void main() {
  test('deadline covers stalled body after headers and cancels subscription',
      () async {
    final client = ControlledClient();
    final api = RestApiClient(
        client: client, requestTimeout: const Duration(milliseconds: 25));
    final result =
        api.currentUser().then<Object>((v) => v, onError: (Object e) => e);
    client.open();
    try {
      final outcome = await result.timeout(const Duration(milliseconds: 250),
          onTimeout: () => 'still pending');
      expect(outcome, isA<ApiException>());
      expect(client.cancelled, isTrue);
      client.finish();
      expect(await result, isA<ApiException>());
    } finally {
      if (!client.body.isClosed) {
        client.finish();
      }
      await result;
    }
  });
  test('headers and body share one budget instead of resetting at headers',
      () async {
    final client = ControlledClient();
    final api = RestApiClient(
        client: client, requestTimeout: const Duration(milliseconds: 40));
    final result =
        api.currentUser().then<Object>((v) => v, onError: (Object e) => e);
    final header = Timer(const Duration(milliseconds: 25), client.open);
    final body = Timer(const Duration(milliseconds: 65), client.finish);
    try {
      expect(await result, isA<ApiException>());
      expect(client.cancelled, isTrue);
    } finally {
      header.cancel();
      body.cancel();
      if (!client.body.isClosed) {
        client.finish();
      }
    }
  });
  test('dripping chunks cannot extend the absolute deadline', () async {
    final client = ControlledClient();
    final api = RestApiClient(
        client: client, requestTimeout: const Duration(milliseconds: 25));
    final result =
        api.currentUser().then<Object>((v) => v, onError: (Object e) => e);
    client.open();
    final drip = Timer.periodic(
        const Duration(milliseconds: 5), (_) => client.body.add([32]));
    try {
      expect(
          await result.timeout(const Duration(milliseconds: 200),
              onTimeout: () => 'still pending'),
          isA<ApiException>());
      expect(client.cancelled, isTrue);
    } finally {
      drip.cancel();
      client.finish();
      await result;
    }
  });
  test('late headers are drained/cancelled and cannot produce a late result',
      () async {
    final client = ControlledClient();
    final api = RestApiClient(
        client: client, requestTimeout: const Duration(milliseconds: 10));
    final result =
        api.currentUser().then<Object>((v) => v, onError: (Object e) => e);
    expect(await result, isA<ApiException>());
    client.open();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(client.cancelled, isTrue);
    client.finish();
    expect(await result, isA<ApiException>());
  });
}
