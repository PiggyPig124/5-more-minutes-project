import 'dart:async';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'guest_privacy_lifecycle_test.dart' as guest;
import 'content_simplification_journey_test.dart' as simplify;

class HeldSimplificationApi extends guest.ControlledGuestApi
    implements ContentSimplificationApi {
  final result = Completer<SimplificationDraft>();
  int calls = 0;
  @override
  Future<SimplificationDraft> simplifyContent(
      {required String original,
      required String locale,
      required bool explicitlyRequested,
      String? guestSessionId}) {
    expect(guestSessionId, 'expiring-guest');
    expect(explicitlyRequested, isTrue);
    expect(original, simplify.original);
    calls++;
    return result.future;
  }
}

void main() {
  for (final status in [404, 410, 503]) {
    testWidgets('F10 guest $status follows current-session G1 cleanup policy',
        (t) async {
      final api = HeldSimplificationApi();
      api.starts.add(Future.value(GuestSession(
          id: 'expiring-guest',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)))));
      final c = guest.controller(api);
      expect(await c.startGuestSession(), isTrue);
      c.guestMessages.add((simplify.original, false));
      c.guestMessageMetadata[0] = {'synthetic': 'old source metadata'};
      await guest.mount(t, c, const GuestConversationScreen(),
          voice: guest.ControlledVoice());
      await t.enterText(find.byType(TextField), 'Synthetic unsent draft');
      await simplify.consent(t);
      api.result.completeError(
          ApiException('Synthetic session response', statusCode: status));
      await t.pumpAndSettle();
      if (status == 503) {
        expect(c.guestSession?.id, 'expiring-guest');
        expect(c.guestMessages, hasLength(1));
        expect(c.guestMessageMetadata, isNotEmpty);
        expect(t.widget<TextField>(find.byType(TextField)).controller!.text,
            'Synthetic unsent draft');
      } else {
        expect(c.guestSession, isNull);
        expect(c.guestMessages, isEmpty);
        expect(c.guestMessageMetadata, isEmpty);
        expect(t.widget<TextField>(find.byType(TextField)).controller!.text,
            isEmpty);
        expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      }
      expect(api.ended, isEmpty);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      api.cleanup();
    });
  }
  for (final status in [404, 410]) {
    testWidgets('late F10 $status cannot clear a newer G1 guest or its draft',
        (t) async {
      final api = HeldSimplificationApi();
      api.starts.add(Future.value(GuestSession(
          id: 'expiring-guest',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)))));
      final c = guest.controller(api);
      expect(await c.startGuestSession(), isTrue);
      c.guestMessages.add((simplify.original, false));
      await guest.mount(t, c, const GuestConversationScreen(),
          voice: guest.ControlledVoice());
      await simplify.consent(t);
      await c.endGuestSession();
      api.starts.add(Future.value(GuestSession(
          id: 'fresh-guest',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)))));
      expect(await c.startGuestSession(), isTrue);
      c.guestMessages.add(('Fresh synthetic context', false));
      c.guestMessageMetadata[0] = {'synthetic': 'fresh source metadata'};
      await t.pump();
      await t.enterText(find.byType(TextField), 'Fresh unsent draft');
      api.result.completeError(
          ApiException('Late synthetic response', statusCode: status));
      await t.pumpAndSettle();
      expect(c.guestSession?.id, 'fresh-guest');
      expect(c.guestMessages, [('Fresh synthetic context', false)]);
      expect(c.guestMessageMetadata[0], {'synthetic': 'fresh source metadata'});
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text,
          'Fresh unsent draft');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      api.cleanup();
    });
  }
  testWidgets(
      'G1 expiry removes F10 preview and late draft cannot enter a fresh guest',
      (t) async {
    final api = HeldSimplificationApi();
    api.starts.add(Future.value(GuestSession(
        id: 'expiring-guest',
        expiresAt: DateTime.now().add(const Duration(seconds: 1)))));
    final c = guest.controller(api);
    expect(await c.startGuestSession(), isTrue);
    c.guestMessages.add((simplify.original, false));
    c.guestMessageMetadata[0] = {'synthetic': 'old source metadata'};
    await guest.mount(t, c, const GuestConversationScreen(),
        voice: guest.ControlledVoice());
    await simplify.consent(t);
    expect(api.calls, 1);
    await t.pump(const Duration(seconds: 2));
    expect(c.guestSession, isNull);
    expect(c.guestMessages, isEmpty);
    expect(c.guestMessageMetadata, isEmpty);
    expect(find.text(simplify.original), findsNothing);
    api.starts.add(Future.value(GuestSession(
        id: 'fresh-guest',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)))));
    expect(await c.startGuestSession(), isTrue);
    c.guestMessages.add(('Fresh synthetic context', false));
    api.result.complete(const SimplificationDraft(
        original: simplify.original, simpler: simplify.simpler));
    await t.pumpAndSettle();
    expect(c.guestSession?.id, 'fresh-guest');
    expect(c.guestMessages, [('Fresh synthetic context', false)]);
    expect(find.text(simplify.simpler), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    api.cleanup();
  });
}
