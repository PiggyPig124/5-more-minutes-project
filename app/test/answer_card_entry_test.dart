import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anxin_companion/src/answer_card_editor.dart';
import 'answer_card_fixtures.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'memory_controls_widget_test.dart' as widgets;

AppController fixture({bool guest = false, bool caregiver = false}) {
  final c = AppController(
      api: RestApiClient(
          client: MockClient((r) async => http.Response('[]', 200))),
      sessionStore: SessionStore(MemoryLocalStore()));
  if (guest) {
    c.guestSession = const GuestSession(id: 'synthetic-guest');
  } else {
    c.session = caregiver
        ? const AuthSession(
            accessToken: 'synthetic-token',
            user: AppUser(
                id: 'caregiver',
                displayName: 'Carer',
                email: 'carer@example.invalid',
                role: UserRole.caregiver))
        : widgets.session;
  }
  return c;
}

ChatMessage message({bool user = false, bool pending = false}) => ChatMessage(
        id: 'ai-current',
        conversationId: 'conversation-current',
        body: 'Selected only from this completed answer',
        isFromUser: user,
        pending: pending,
        createdAt: null,
        metadata: const {
          'memory_sources': [
            {'content': 'Do not silently include this'}
          ]
        });

class SessionFixtureController extends AppController {
  SessionFixtureController(AnxinApi api)
      : super(api: api, sessionStore: SessionStore(MemoryLocalStore()));
  void syntheticChange(AuthSession? next, {GuestSession? guest}) {
    session = next;
    guestSession = guest;
    notifyListeners();
  }

  void ordinaryNotification() => notifyListeners();
}

void main() {
  test(
      'actual provider follows account identity but retains stable-session RAM',
      () async {
    final source = SessionFixtureController(RestApiClient(
        client: MockClient((r) async => http.Response('[]', 200))));
    source.syntheticChange(null, guest: const GuestSession(id: 'guest-a'));
    final container = ProviderContainer(
        overrides: [appControllerProvider.overrideWith((ref) => source)]);
    final cards = container.read(answerCardControllerProvider);
    cards.prepareGuestAnswer('Synthetic private guest text');
    source.ordinaryNotification();
    expect(cards.draft?.originalText, 'Synthetic private guest text');
    source.syntheticChange(widgets.session);
    expect(cards.draft, isNull);
    expect(cards.preview, isNull);
    expect(cards.cards, isEmpty);
    source.syntheticChange(null, guest: const GuestSession(id: 'guest-b'));
    expect(cards.draft, isNull);
    container.dispose();
  });
  testWidgets(
      'actual entry back cancels pending prepare and ignores its late response',
      (t) async {
    final pending = Completer<http.Response>();
    final requests = <http.Request>[];
    final source =
        SessionFixtureController(RestApiClient(client: MockClient((r) async {
      requests.add(r);
      return await pending.future;
    })));
    source.syntheticChange(widgets.session);
    await widgets.mount(t, source,
        home: Scaffold(body: MessageBubble(message: message())));
    await t.tap(find.byKey(const ValueKey('answer-card-action-ai-current')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(AnswerCardEditorScreen), findsOneWidget);
    expect(requests.single.url.path, '/answer-cards/prepare');
    expect(
        jsonDecode(requests.single.body), {'source_message_id': 'ai-current'});
    final container = ProviderScope.containerOf(
        t.element(find.byType(AnswerCardEditorScreen)));
    final cards = container.read(answerCardControllerProvider);
    await t.pageBack();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(cards.draft, isNull);
    pending.complete(http.Response(
        jsonEncode(answerDraftFixture()..['source_message_id'] = 'ai-current'),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await t.pumpAndSettle();
    expect(cards.draft, isNull);
    expect(cards.preview, isNull);
    expect(cards.busy, isFalse);
    expect(find.byType(AnswerCardEditorScreen), findsNothing);
    expect(requests, hasLength(1));
  });

  testWidgets('completed assistant exposes explicit answer-card action',
      (t) async {
    await widgets.mount(t, fixture(),
        home: Scaffold(body: MessageBubble(message: message())));
    expect(find.byKey(const ValueKey('answer-card-action-ai-current')),
        findsOneWidget);
  });
  testWidgets('guest completed assistant has the RAM answer-card action',
      (t) async {
    await widgets.mount(t, fixture(guest: true),
        home: Scaffold(body: MessageBubble(message: message())));
    expect(find.byKey(const ValueKey('answer-card-action-ai-current')),
        findsOneWidget);
  });
  for (final user in [true, false]) {
    testWidgets('user or pending answer has no card action user=$user',
        (t) async {
      await widgets.mount(t, fixture(),
          home: Scaffold(
              body:
                  MessageBubble(message: message(user: user, pending: !user))));
      expect(find.byKey(const ValueKey('answer-card-action-ai-current')),
          findsNothing);
    });
  }
  testWidgets('senior home exposes private cards and public template entrance',
      (t) async {
    await widgets.mount(t, fixture(),
        home: Scaffold(body: ElderHome(onChat: () {})));
    await t.scrollUntilVisible(find.text('Answer cards'), 240,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Answer cards'), findsOneWidget);
  });
  testWidgets('caregiver home exposes own answer-card management', (t) async {
    await widgets.mount(t, fixture(caregiver: true),
        home: const Scaffold(body: CaregiverHome()));
    expect(find.text('Answer cards'), findsOneWidget);
  });
  testWidgets('guest home exposes public answer-card templates', (t) async {
    await widgets.mount(t, fixture(guest: true), home: const GuestShell());
    expect(find.text('Answer cards'), findsOneWidget);
  });
}
