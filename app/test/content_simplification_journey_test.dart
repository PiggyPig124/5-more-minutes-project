import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const original =
    'At the fictional club, people gather for friendly conversation.';
const simpler = 'People meet and chat at the fictional club.';
const answer = ChatMessage(
    id: 'synthetic-answer',
    conversationId: 'synthetic-conversation',
    body: original,
    isFromUser: false,
    createdAt: null);
const owner = AuthSession(
    accessToken: 'synthetic-token',
    user: AppUser(
        id: 'synthetic-owner',
        displayName: 'Synthetic',
        email: 'synthetic@example.invalid',
        role: UserRole.elder));

class BodyStreamClient extends http.BaseClient {
  final bodies = <StreamController<List<int>>>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = StreamController<List<int>>();
    bodies.add(body);
    return http.StreamedResponse(body.stream, 200,
        headers: {'content-type': 'application/json'});
  }
}

Widget frame(AppController c,
        {ChatMessage message = answer,
        bool english = true,
        bool large = false}) =>
    ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => c)],
        child: MaterialApp(
            locale: english ? englishLocale : traditionalChineseLocale,
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
                child: child!),
            home: Scaffold(
                body: SingleChildScrollView(
                    child: MessageBubble(message: message)))));
Map<String, Object?> draft({String text = simpler, String source = original}) =>
    {
      'status': 'draft',
      'original': source,
      'simpler': text,
      'reason': null,
      'independently_verified': false
    };
Future<void> consent(WidgetTester t) async {
  await t.ensureVisible(find.byKey(const ValueKey('message-simplify')));
  await t.tap(find.byKey(const ValueKey('message-simplify')));
  await t.pumpAndSettle();
  await t.ensureVisible(find.byKey(const ValueKey('simplify-consent-confirm')));
  await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
  await t.pump();
}

void main() {
  for (final guest in [false, true]) {
    testWidgets(
        'actual bubble to REST ${guest ? 'guest' : 'signed'} only sends after selected-text consent',
        (t) async {
      final requests = <http.Request>[];
      final api = RestApiClient(
          origin: 'https://example.invalid',
          accessToken: guest ? null : owner.accessToken,
          client: MockClient((r) async {
            requests.add(r);
            return http.Response(jsonEncode(draft()), 200);
          }));
      final c = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()));
      if (guest) {
        c.guestSession = const GuestSession(id: 'synthetic-guest');
      } else {
        c.session = owner;
      }
      await t.pumpWidget(frame(c));
      expect(requests, isEmpty);
      await t.tap(find.byKey(const ValueKey('message-simplify')));
      await t.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.textContaining('selected answer'), findsWidgets);
      await t.ensureVisible(
          find.byKey(const ValueKey('simplify-consent-confirm')));
      await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
      await t.pumpAndSettle();
      expect(requests.length, 1);
      expect(
          requests.single.url.path,
          guest
              ? '/guest/sessions/synthetic-guest/simplifications'
              : '/content/simplifications');
      expect(jsonDecode(requests.single.body),
          {'text': original, 'locale': 'en', 'explicit_request': true});
      expect(find.text(simpler), findsOneWidget);
      expect(find.text(original), findsNWidgets(2));
      expect(c.guestMessages, isEmpty);
      expect(c.memories, isEmpty);
    });
  }
  testWidgets('cancel consent performs no HTTP request', (t) async {
    var calls = 0;
    final api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    final c =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = owner;
    await t.pumpWidget(frame(c));
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pumpAndSettle();
    await t
        .ensureVisible(find.byKey(const ValueKey('simplify-consent-cancel')));
    await t.tap(find.byKey(const ValueKey('simplify-consent-cancel')));
    await t.pumpAndSettle();
    expect(calls, 0);
    expect(find.text(original), findsOneWidget);
  });
  testWidgets('missing model is honest and original remains complete',
      (t) async {
    final paths = <String>[];
    final api = RestApiClient(client: MockClient((r) async {
      paths.add(r.url.path);
      return http.Response(
          jsonEncode({
            'status': 'unavailable',
            'original': original,
            'simpler': null,
            'reason': 'model_unavailable',
            'independently_verified': false
          }),
          200);
    }));
    final c =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = owner;
    await t.pumpWidget(frame(c));
    await consent(t);
    await t.pumpAndSettle();
    expect(
        find.textContaining('configured model is unavailable'), findsOneWidget);
    expect(find.text(original), findsOneWidget);
    expect(find.text(simpler), findsNothing);
    expect(paths, ['/content/simplifications']);
  });
  for (final change in ['logout', 'account', 'body', 'metadata']) {
    testWidgets('late response is discarded after $change', (t) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final api = RestApiClient(client: MockClient((r) {
        calls++;
        return pending.future;
      }));
      final c = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = owner;
      await t.pumpWidget(frame(c));
      await consent(t);
      expect(calls, 1);
      var next = answer;
      switch (change) {
        case 'logout':
          await c.logout();
        case 'account':
          c.session = const AuthSession(
              accessToken: 'second-token',
              user: AppUser(
                  id: 'second',
                  displayName: 'Second',
                  email: 'second@example.invalid',
                  role: UserRole.elder));
          c.notifyListeners();
        case 'body':
          next = const ChatMessage(
              id: 'synthetic-answer',
              conversationId: 'synthetic-conversation',
              body: 'New original version',
              isFromUser: false,
              createdAt: null);
        case 'metadata':
          next = const ChatMessage(
              id: 'synthetic-answer',
              conversationId: 'synthetic-conversation',
              body: original,
              isFromUser: false,
              createdAt: null,
              metadata: {'source_revision': 2});
      }
      await t.pumpWidget(frame(c, message: next));
      pending.complete(http.Response(jsonEncode(draft()), 200));
      await t.pumpAndSettle();
      expect(find.text(simpler), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(c.memories, isEmpty);
      expect(c.guestMessages, isEmpty);
    });
  }
  testWidgets(
      'cancel then retry ignores an old error and keeps current loading',
      (t) async {
    final pending = [Completer<http.Response>(), Completer<http.Response>()];
    var calls = 0;
    final api =
        RestApiClient(client: MockClient((r) => pending[calls++].future));
    final c =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = owner;
    await t.pumpWidget(frame(c));
    await consent(t);
    await t
        .ensureVisible(find.byKey(const ValueKey('message-simplify-cancel')));
    await t.tap(find.byKey(const ValueKey('message-simplify-cancel')));
    await t.pump();
    await consent(t);
    expect(calls, 2);
    pending[0].completeError(StateError('Synthetic older failure'));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('could not be obtained'), findsNothing);
    pending[1].complete(http.Response(jsonEncode(draft()), 200));
    await t.pumpAndSettle();
    expect(find.text(simpler), findsOneWidget);
  });
  testWidgets('HTTP timeout leaves original and late output cannot appear',
      (t) async {
    final pending = Completer<http.Response>();
    final api = RestApiClient(
        requestTimeout: const Duration(milliseconds: 20),
        client: MockClient((r) => pending.future));
    final c =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = owner;
    await t.pumpWidget(frame(c));
    await consent(t);
    await t.pump(const Duration(milliseconds: 50));
    await t.pump();
    expect(find.textContaining('could not be obtained'), findsOneWidget);
    pending.complete(http.Response(jsonEncode(draft()), 200));
    await t.pumpAndSettle();
    expect(find.text(simpler), findsNothing);
    expect(find.text(original), findsOneWidget);
  });
  testWidgets(
      'logout before consent removes the selected-text panel without a call',
      (t) async {
    var calls = 0;
    final api = RestApiClient(client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    final c =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = owner;
    await t.pumpWidget(frame(c));
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pumpAndSettle();
    await c.logout();
    await t.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('simplify-selected-original')), findsNothing);
    expect(calls, 0);
  });
  for (final english in [true, false]) {
    testWidgets(
        'disclosure and confirmation stay operable at 320px 200 percent $english',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = RestApiClient(
          client:
              MockClient((r) async => http.Response(jsonEncode(draft()), 200)));
      final c = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = owner;
      await t.pumpWidget(frame(c, english: english, large: true));
      await consent(t);
      await t.pumpAndSettle();
      expect(find.text(original), findsNWidgets(2));
      expect(find.text(simpler), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
  for (final change in ['cancel', 'logout', 'metadata']) {
    testWidgets('late response BODY after $change cannot display a draft',
        (t) async {
      final transport = BodyStreamClient();
      final api = RestApiClient(client: transport);
      final c = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = owner;
      await t.pumpWidget(frame(c));
      await consent(t);
      expect(transport.bodies.length, 1);
      switch (change) {
        case 'cancel':
          await t.ensureVisible(
              find.byKey(const ValueKey('message-simplify-cancel')));
          await t.tap(find.byKey(const ValueKey('message-simplify-cancel')));
          await t.pump();
        case 'logout':
          await c.logout();
          await t.pump();
        case 'metadata':
          await t.pumpWidget(frame(c,
              message: const ChatMessage(
                  id: 'synthetic-answer',
                  conversationId: 'synthetic-conversation',
                  body: original,
                  isFromUser: false,
                  createdAt: null,
                  metadata: {'revision': 2})));
      }
      transport.bodies.single.add(utf8.encode(jsonEncode(draft())));
      await transport.bodies.single.close();
      await t.pumpAndSettle();
      expect(find.text(simpler), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  }
  testWidgets('stalled BODY times out in actual UI and late data is ignored',
      (t) async {
    final transport = BodyStreamClient();
    final api = RestApiClient(
        client: transport, requestTimeout: const Duration(milliseconds: 20));
    final c =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = owner;
    await t.pumpWidget(frame(c));
    await consent(t);
    await t.pump(const Duration(milliseconds: 50));
    await t.pump();
    expect(find.textContaining('could not be obtained'), findsOneWidget);
    expect(transport.bodies.single.hasListener, isFalse);
    transport.bodies.single.add(utf8.encode(jsonEncode(draft())));
    // A canceled controller can finish close on the fake clock's next pump.
    unawaited(transport.bodies.single.close());
    await t.pumpAndSettle();
    expect(find.text(simpler), findsNothing);
    expect(find.text(original), findsOneWidget);
  });
}
