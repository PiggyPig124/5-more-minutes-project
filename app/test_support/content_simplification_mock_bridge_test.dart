import 'dart:async';
import 'dart:io';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';

const origin = String.fromEnvironment('F10_MOCK_API_ORIGIN');
const original =
    'At the fictional club, people gather for friendly conversation.';
const simpler = 'People meet and chat at the fictional club.';

class LocalHttp extends HttpOverrides {}

class BridgeApi extends RestApiClient {
  BridgeApi(IOClient client) : super(origin: origin, client: client);
  final completed = Completer<void>();
  @override
  Future<SimplificationDraft> simplifyContent(
      {required String original,
      required String locale,
      required bool explicitlyRequested,
      String? guestSessionId}) async {
    try {
      return await super.simplifyContent(
          original: original,
          locale: locale,
          explicitlyRequested: explicitlyRequested,
          guestSessionId: guestSessionId);
    } finally {
      completed.complete();
    }
  }
}

void main() {
  for (final guest in [false, true]) {
    testWidgets(
        'localhost actual UI REST HTTP strict-model-mock ${guest ? 'guest' : 'signed'}',
        (t) async {
      final uri = Uri.parse(origin);
      expect(uri.scheme, 'http');
      expect(uri.host, '127.0.0.1');
      expect(uri.hasPort, isTrue);
      // This test is explicitly launched against the task-owned synthetic backend.
      // Bypass flutter_test's fake HTTP client only for that known localhost server.
      final transport = IOClient(LocalHttp().createHttpClient(null));
      addTearDown(transport.close);
      final api = BridgeApi(transport);
      final c = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()));
      await t.runAsync(() async {
        if (guest) {
          c.guestSession = await api.startGuestSession();
        } else {
          c.session = await api.register(
              email: 'bridge@example.invalid',
              password: 'synthetic-password-123',
              displayName: 'Synthetic bridge',
              role: UserRole.elder);
        }
      });
      await t.pumpWidget(ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => c)],
          child: MaterialApp(
              locale: englishLocale,
              supportedLocales: appSupportedLocales,
              localizationsDelegates: appLocalizationsDelegates,
              home: const Scaffold(
                  body: SingleChildScrollView(
                      child: MessageBubble(
                          message: ChatMessage(
                              id: 'bridge-answer',
                              conversationId: 'bridge-chat',
                              body: original,
                              isFromUser: false,
                              createdAt: null)))))));
      expect(api.completed.isCompleted, isFalse);
      await t.tap(find.byKey(const ValueKey('message-simplify')));
      await t.pumpAndSettle();
      expect(api.completed.isCompleted, isFalse);
      await t.ensureVisible(
          find.byKey(const ValueKey('simplify-consent-confirm')));
      final confirm = t.widget<FilledButton>(
          find.byKey(const ValueKey('simplify-consent-confirm')));
      await t.runAsync(() async {
        // Execute the actual button callback in a real I/O zone. Gesture
        // confirmation is covered separately by the fake-clock widget tests.
        confirm.onPressed!();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        // The marker was created on the widget fake clock. Inspect its state
        // here; awaiting that fake-clock Future would prevent the next pump.
        while (
            !api.completed.isCompleted && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(api.completed.isCompleted, isTrue);
      });
      await t.pumpAndSettle();
      expect(find.text(simpler), findsOneWidget);
      expect(find.text(original), findsNWidgets(2));
      expect(c.memories, isEmpty);
      expect(c.guestMessages, isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }
}
