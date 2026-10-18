import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// One absolute budget for send, headers and the entire body. Never close the
/// shared client: abort only this request and cancel its body subscription.
Future<http.Response> requestWithinDeadline(
    http.Client client, String method, Uri uri,
    {required Map<String, String> headers,
    required String body,
    required Duration timeout}) {
  final result = Completer<http.Response>();
  final abort = Completer<void>();
  StreamSubscription<List<int>>? subscription;
  final bytes = BytesBuilder(copy: false);
  late final Timer deadline;
  void cancel(StreamSubscription<List<int>>? value) {
    try {
      final pending = value?.cancel();
      if (pending != null) unawaited(pending.catchError((Object _) {}));
    } catch (_) {/* Cancellation must not extend or mask the deadline. */}
  }

  void fail(Object error, [StackTrace? stack]) {
    if (result.isCompleted) return;
    deadline.cancel();
    result.completeError(error, stack);
    if (!abort.isCompleted) abort.complete();
    cancel(subscription);
  }

  deadline = Timer(timeout,
      () => fail(TimeoutException('HTTP request deadline exceeded', timeout)));
  Future<void> receive() async {
    try {
      final request =
          http.AbortableRequest(method, uri, abortTrigger: abort.future)
            ..headers.addAll(headers)
            ..body = body;
      final response = await client.send(request);
      if (result.isCompleted) {
        cancel(response.stream.listen((_) {}));
        return;
      }
      subscription = response.stream.listen(
          (chunk) {
            if (!result.isCompleted) bytes.add(chunk);
          },
          onError: (Object error, StackTrace stack) => fail(error, stack),
          onDone: () {
            if (result.isCompleted) return;
            deadline.cancel();
            result.complete(http.Response.bytes(
                bytes.takeBytes(), response.statusCode,
                request: response.request,
                headers: response.headers,
                isRedirect: response.isRedirect,
                persistentConnection: response.persistentConnection,
                reasonPhrase: response.reasonPhrase));
          },
          cancelOnError: true);
    } catch (error, stack) {
      fail(error, stack);
    }
  }

  unawaited(receive());
  return result.future;
}
