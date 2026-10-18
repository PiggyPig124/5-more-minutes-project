import 'dart:async';
import 'dart:collection';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:anxin_companion/src/speech_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';

class ControlledGuestApi extends FakeApi implements GuestApi {
  final starts = Queue<Future<GuestSession>>();
  final replies = <Completer<GuestReply>>[];
  final ended = <String>[];
  Completer<void>? endResult;
  @override
  Future<GuestSession> startGuestSession() => starts.removeFirst();
  @override
  Future<GuestReply> sendGuestMessage(String sessionId, String content) {
    final result = Completer<GuestReply>();
    replies.add(result);
    return result.future;
  }

  @override
  Future<void> endGuestSession(String sessionId) async {
    ended.add(sessionId);
    await endResult?.future;
  }

  void cleanup() {
    for (final reply in replies) {
      if (!reply.isCompleted) {
        reply.complete(
            const GuestReply(content: 'synthetic late reply', mode: 'test'));
      }
    }
    if (endResult != null && !endResult!.isCompleted) endResult!.complete();
  }
}

AppController controller(ControlledGuestApi api, {MemoryLocalStore? store}) =>
    AppController(
        api: api, sessionStore: SessionStore(store ?? MemoryLocalStore()));

class ControlledVoice extends VoiceInputController {
  ValueChanged<String>? transcript;
  int detaches = 0;
  @override
  Future<void> toggle({required ValueChanged<String> onTranscript}) async {
    transcript = onTranscript;
  }

  @override
  void detach() {
    detaches++;
  }
}

void seedRam(AppController c) {
  c.guestMessages.add(('SYNTHETIC_PRIVATE_GUEST_BODY', true));
  c.guestMessageMetadata[0] = {'synthetic': 'private metadata'};
}

Future<void> mount(WidgetTester t, AppController c, Widget home,
    {ControlledVoice? voice}) async {
  await t.pumpWidget(ProviderScope(
      overrides: [
        appControllerProvider.overrideWith((ref) => c),
        localeStoreProvider.overrideWithValue(MemoryLocalStore()),
        if (voice != null) voiceInputProvider.overrideWith((ref) => voice),
      ],
      child: MaterialApp(
          locale: englishLocale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: home)));
  await t.pump();
}

void pauseApp(WidgetTester t) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused
  ]) {
    t.binding.handleAppLifecycleStateChanged(state);
  }
}

void resumeApp(WidgetTester t) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed
  ]) {
    t.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('guest deadline clears RAM and metadata without another request',
      (t) async {
    final api = ControlledGuestApi();
    api.starts.add(Future.value(GuestSession(
        id: 'expiry',
        expiresAt: DateTime.now().add(const Duration(seconds: 1)))));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    expect(await c.startGuestSession(), isTrue);
    seedRam(c);
    await t.pump(const Duration(seconds: 2));
    expect(c.guestSession, isNull);
    expect(c.guestMessages, isEmpty);
    expect(c.guestMessageMetadata, isEmpty);
  });

  for (final status in [404, 410]) {
    test('server $status expires only current guest RAM', () async {
      final api = ControlledGuestApi()
        ..starts.add(Future.value(const GuestSession(id: 'server-expired')));
      final store = MemoryLocalStore()
        ..values['synthetic.saved.card'] = 'already explicitly saved';
      final c = controller(api, store: store);
      addTearDown(() {
        api.cleanup();
        c.dispose();
      });
      await c.startGuestSession();
      seedRam(c);
      final send = c.sendGuestMessage('synthetic follow-up');
      api.replies.single
          .completeError(ApiException('Expired', statusCode: status));
      expect(await send, isFalse);
      expect(c.guestSession, isNull);
      expect(c.guestMessages, isEmpty);
      expect(c.guestMessageMetadata, isEmpty);
      expect(store.values['synthetic.saved.card'], 'already explicitly saved');
    });
  }

  test('a new guest start clears previous transcript before remote result',
      () async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'old')));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    await c.startGuestSession();
    seedRam(c);
    final next = Completer<GuestSession>();
    api.starts.add(next.future);
    final start = c.startGuestSession();
    final oldCleared = c.guestMessages.isEmpty &&
        c.guestMessageMetadata.isEmpty &&
        c.guestSession == null;
    next.complete(const GuestSession(id: 'new'));
    await start;
    expect(oldCleared, isTrue);
    expect(c.guestSession?.id, 'new');
  });

  test('a pending guest send accepts no duplicate external request', () async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'busy')));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    await c.startGuestSession();
    final first = c.sendGuestMessage('synthetic question');
    final duplicate = c.sendGuestMessage('synthetic question');
    final actualCount = api.replies.length;
    api.cleanup();
    await first;
    await duplicate;
    expect(actualCount, 1);
    expect(c.guestMessages.where((m) => m.$2), hasLength(1));
  });

  testWidgets('guest waiting is visible and End remains usable', (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'ui-busy')));
    final c = controller(api);
    await c.startGuestSession();
    await mount(t, c, const GuestConversationScreen());
    await t.enterText(find.byType(TextField), 'synthetic question');
    await t.tap(find.byTooltip('Send'));
    await t.pump();
    final showedWaiting =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    final end = t.widget<IconButton>(find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'End session'));
    final couldEnd = end.onPressed != null;
    await t.tap(find.byTooltip('End session'));
    await t.pump();
    api.cleanup();
    await t.pump();
    expect(showedWaiting, isTrue);
    expect(couldEnd, isTrue);
    expect(c.guestMessages, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'application resume removes expired RAM before showing guest again',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'resume')));
    final c = controller(api)..initialized = true;
    await c.startGuestSession();
    seedRam(c);
    await mount(t, c, const RootView());
    pauseApp(t);
    // Simulate a suspended OS returning with an absolute expiry already past.
    c.guestSession = GuestSession(id: 'resume', expiresAt: DateTime.utc(2020));
    resumeApp(t);
    await t.pump();
    expect(c.guestSession, isNull);
    expect(c.guestMessages, isEmpty);
    expect(c.guestMessageMetadata, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });

  test('old expiry error cannot erase a newer guest session', () async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'old')));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    await c.startGuestSession();
    final old = c.sendGuestMessage('old synthetic');
    await c.endGuestSession();
    api.starts.add(Future.value(const GuestSession(id: 'new')));
    await c.startGuestSession();
    seedRam(c);
    api.replies.first
        .completeError(const ApiException('old expired', statusCode: 404));
    expect(await old, isFalse);
    expect(c.guestSession?.id, 'new');
    expect(c.guestMessages, hasLength(1));
    expect(c.errorMessage, isNull);
  });

  testWidgets('expiry also clears an open routed conversation input draft',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'routed')));
    final c = controller(api)..initialized = true;
    await c.startGuestSession();
    seedRam(c);
    await mount(t, c, const RootView());
    await t.tap(find.text('Start chatting'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'SYNTHETIC_UNSENT_PRIVATE_DRAFT');
    pauseApp(t);
    c.guestSession = GuestSession(id: 'routed', expiresAt: DateTime.utc(2020));
    resumeApp(t);
    await t.pump();
    final field = t.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, isEmpty);
    expect(field.enabled, isFalse);
    expect(find.text('SYNTHETIC_PRIVATE_GUEST_BODY'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'retryable guest failure restores draft without overwriting new input',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'retry')));
    final c = controller(api);
    await c.startGuestSession();
    await mount(t, c, const GuestConversationScreen());
    await t.enterText(find.byType(TextField), 'synthetic failed question');
    await t.tap(find.byTooltip('Send'));
    await t.pump();
    api.replies.first.completeError(
        const ApiException('Synthetic failure', statusCode: 503));
    await t.pump();
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text,
        'synthetic failed question');
    await t.tap(find.byTooltip('Send'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'synthetic newer draft');
    api.replies.last.completeError(
        const ApiException('Synthetic failure', statusCode: 503));
    await t.pump();
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text,
        'synthetic newer draft');
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'late speech cannot refill expired routed draft even before next frame',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'speech-expiry')));
    final c = controller(api)..initialized = true;
    final voice = ControlledVoice();
    await c.startGuestSession();
    await mount(t, c, const RootView(), voice: voice);
    await t.tap(find.text('Start chatting'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('voice-draft-button')));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(voice.transcript, isNotNull);
    pauseApp(t);
    c.guestSession =
        GuestSession(id: 'speech-expiry', expiresAt: DateTime.utc(2020));
    resumeApp(t);
    voice.transcript!('SYNTHETIC_LATE_PRIVATE_SPEECH');
    final textBeforeRebuild =
        t.widget<TextField>(find.byType(TextField).first).controller!.text;
    await t.pump();
    expect(textBeforeRebuild, isEmpty);
    expect(t.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty);
    expect(voice.detaches, greaterThan(0));
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'deadline drops pending reply and preserves explicitly saved unrelated records',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(GuestSession(
          id: 'pending-expiry',
          expiresAt: DateTime.now().add(const Duration(seconds: 1)))));
    final store = MemoryLocalStore()
      ..values['synthetic.saved.card'] = 'saved external card';
    final c = controller(api, store: store);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    c.memories = const [
      MemoryRecord(
          id: 'saved-memory',
          content: 'synthetic approved memory',
          kind: 'experience',
          status: 'confirmed')
    ];
    c.stories = const [
      StoryRecord(
          id: 'saved-story',
          title: 'synthetic saved card',
          content: 'saved composition')
    ];
    final memories = c.memories;
    final stories = c.stories;
    await c.startGuestSession();
    final send = c.sendGuestMessage('SYNTHETIC_PENDING_PRIVATE_BODY');
    await t.pump(const Duration(seconds: 2));
    api.replies.single.complete(GuestReply(
        content: 'SYNTHETIC_STALE_REPLY',
        mode: 'test',
        expiresAt: DateTime.now().add(const Duration(hours: 1))));
    expect(await send, isFalse);
    expect(c.guestSession, isNull);
    expect(c.guestMessages, isEmpty);
    expect(c.guestMessageMetadata, isEmpty);
    expect(c.guestSending, isFalse);
    expect(identical(c.memories, memories), isTrue);
    expect(identical(c.stories, stories), isTrue);
    expect(store.values, {'synthetic.saved.card': 'saved external card'});
  });

  test('old completion cannot end new guest waiting or replace new transcript',
      () async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'old-success')));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    await c.startGuestSession();
    final old = c.sendGuestMessage('old synthetic');
    await c.endGuestSession();
    api.starts.add(Future.value(const GuestSession(id: 'new-busy')));
    await c.startGuestSession();
    final next = c.sendGuestMessage('new synthetic');
    api.replies.first
        .complete(const GuestReply(content: 'old answer', mode: 'test'));
    expect(await old, isFalse);
    expect(c.guestSending, isTrue);
    expect(c.guestMessages, [('new synthetic', true)]);
    api.replies.last
        .complete(const GuestReply(content: 'new answer', mode: 'test'));
    expect(await next, isTrue);
    expect(c.guestSending, isFalse);
  });

  test('old failed DELETE cannot poison new guest state or global loading',
      () async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'ending')));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    await c.startGuestSession();
    seedRam(c);
    api.endResult = Completer<void>();
    final ending = c.endGuestSession();
    expect(c.guestMessages, isEmpty);
    api.starts.add(Future.value(const GuestSession(id: 'after-end')));
    await c.startGuestSession();
    c.loading = true;
    api.endResult!.completeError(
        const ApiException('old delete failed', statusCode: 503));
    await ending;
    expect(c.guestSession?.id, 'after-end');
    expect(c.errorMessage, isNull);
    expect(c.loading, isTrue);
  });

  testWidgets(
      'refreshed server deadline cancels old timer without changing guest identity',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(GuestSession(
          id: 'renewed',
          expiresAt: DateTime.now().add(const Duration(seconds: 1)))));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    await c.startGuestSession();
    final identity = c.guestSessionIdentity;
    final send = c.sendGuestMessage('synthetic refresh');
    api.replies.single.complete(GuestReply(
        content: 'synthetic reply',
        mode: 'test',
        expiresAt: DateTime.now().add(const Duration(seconds: 10))));
    expect(await send, isTrue);
    expect(c.guestSessionIdentity, identity);
    await t.pump(const Duration(seconds: 2));
    expect(c.guestSession?.id, 'renewed');
    await t.pump(const Duration(seconds: 10));
    expect(c.guestSession, isNull);
    expect(c.guestMessages, isEmpty);
  });

  testWidgets(
      'missing deadline uses bounded 30 minute fallback rather than infinite RAM',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'legacy-no-date')));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    await c.startGuestSession();
    seedRam(c);
    await t.pump(const Duration(minutes: 31));
    expect(c.guestSession, isNull);
    expect(c.guestMessages, isEmpty);
  });

  test('already expired create response cannot become a usable guest session',
      () async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(GuestSession(
          id: 'expired-on-arrival', expiresAt: DateTime.utc(2020))));
    final c = controller(api);
    addTearDown(() {
      api.cleanup();
      c.dispose();
    });
    expect(await c.startGuestSession(), isFalse);
    expect(c.guestSession, isNull);
    expect(c.guestStarting, isFalse);
    expect(await c.sendGuestMessage('synthetic'), isFalse);
    expect(api.replies, isEmpty);
  });

  test(
      'dispose invalidates pending create and disposes late remote session only',
      () async {
    final api = ControlledGuestApi();
    final created = Completer<GuestSession>();
    api.starts.add(created.future);
    final c = controller(api);
    final start = c.startGuestSession();
    c.dispose();
    created.complete(const GuestSession(id: 'arrived-after-dispose'));
    expect(await start, isFalse);
    expect(c.guestSession, isNull);
    expect(api.ended, ['arrived-after-dispose']);
  });

  test('dispose invalidates pending reply without any late notification',
      () async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'disposed-send')));
    final c = controller(api);
    await c.startGuestSession();
    final send = c.sendGuestMessage('synthetic pending');
    c.dispose();
    api.replies.single
        .complete(const GuestReply(content: 'after-dispose', mode: 'test'));
    expect(await send, isFalse);
    expect(c.guestMessages, isEmpty);
    expect(c.guestSession, isNull);
  });

  testWidgets(
      'unexpired app resume retains current guest text and unrelated global busy',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(GuestSession(
          id: 'valid-resume',
          expiresAt: DateTime.now().add(const Duration(hours: 1)))));
    final c = controller(api)..initialized = true;
    await c.startGuestSession();
    seedRam(c);
    c.loading = true;
    await mount(t, c, const RootView());
    pauseApp(t);
    resumeApp(t);
    await t.pump();
    expect(c.guestSession?.id, 'valid-resume');
    expect(c.guestMessages, hasLength(1));
    expect(c.loading, isTrue);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'old speech remains bound to original guest across same-frame replacement',
      (t) async {
    final api = ControlledGuestApi()
      ..starts.add(Future.value(const GuestSession(id: 'speech-old')));
    final c = controller(api);
    final voice = ControlledVoice();
    await c.startGuestSession();
    await mount(t, c, const GuestConversationScreen(), voice: voice);
    await t.tap(find.byKey(const Key('voice-draft-button')));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    final oldTranscript = voice.transcript!;
    // Keep this route mounted while two state transitions coalesce into a frame.
    await c.endGuestSession();
    api.starts.add(Future.value(const GuestSession(id: 'speech-new')));
    await c.startGuestSession();
    await t.pump();
    oldTranscript('SYNTHETIC_OLD_SESSION_SPEECH');
    expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });

  test(
      'authentication retires a still-pending guest creation without changing saved account',
      () async {
    final api = ControlledGuestApi();
    final created = Completer<GuestSession>();
    api.starts.add(created.future);
    final c = controller(api);
    addTearDown(c.dispose);
    final start = c.startGuestSession();
    expect(await c.login(email: 'elder@example.com', password: 'password123'),
        isTrue);
    final retainedStarting = c.guestStarting;
    final auth = c.session;
    created.complete(const GuestSession(id: 'guest-after-auth'));
    expect(await start, isFalse);
    expect(retainedStarting, isFalse);
    expect(identical(c.session, auth), isTrue);
    expect(c.guestSession, isNull);
    expect(c.guestMessages, isEmpty);
    expect(api.ended, ['guest-after-auth']);
  });
}
