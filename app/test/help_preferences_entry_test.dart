import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:anxin_companion/src/interaction_preferences.dart';
import 'package:anxin_companion/src/speech_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class _PublicHelpApi extends FakeApi implements GuestResourceApi {
  final queries = <String>[];
  @override
  Future<ResourceSearchResult> searchGuestResources(
      {required String query, int? limit}) async {
    queries.add(query);
    return ResourceSearchResult(query: query, retrievalMode: 'local');
  }
}

class _Voice extends VoiceInputController {
  int starts = 0;
  int detaches = 0;
  ValueChanged<String>? lateTranscript;
  @override
  Future<void> toggle({required ValueChanged<String> onTranscript}) async {
    starts++;
    lateTranscript = onTranscript;
    isListening = true;
    notifyListeners();
  }
  @override
  void detach() { detaches++; isListening = false; }
  @override
  Future<void> stop() async { isListening = false; }
}

Future<AppController> _mount(WidgetTester tester, Widget home,
    {FakeApi? api, _Voice? voice, bool signedIn = false,
     Locale locale = englishLocale}) async {
  final controller = AppController(
      api: api ?? FakeApi(), sessionStore: SessionStore(MemoryLocalStore()));
  if (home is GuestConversationScreen) {
    controller.guestSession = const GuestSession(id: 'synthetic-preferences-guest');
  }
  if (signedIn) {
    controller.session = const AuthSession(accessToken: 'synthetic',
      user: AppUser(id: 'elder-1', displayName: 'Test',
        email: 'test@example.invalid', role: UserRole.elder));
  }
  await tester.pumpWidget(ProviderScope(overrides: [
    appControllerProvider.overrideWith((ref) => controller),
    localeStoreProvider.overrideWithValue(MemoryLocalStore()),
    if (voice != null) voiceInputProvider.overrideWith((ref) => voice),
  ], child: MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: home)));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('ordinary Help opens public human help without an account',
      (tester) async {
    final api = _PublicHelpApi();
    await _mount(tester, const Scaffold(body: HelpScreen()), api: api);
    await tester.tap(find.text('Ask a person'));
    await tester.pumpAndSettle();
    expect(find.text('Ask a person'), findsOneWidget);
    expect(api.queries, isNotEmpty);
    expect(find.textContaining('Personal mode is optional'), findsOneWidget);
    expect(api.lastFamilyMessageClientId, isNull);
  });

  testWidgets('guest home reaches existing Settings and interaction choices',
      (tester) async {
    await _mount(tester, const GuestShell());
    await tester.tap(find.byKey(const Key('interaction-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Interaction preference'), findsOneWidget);
    expect(find.text('Interface language'), findsOneWidget);
    expect(find.text('Typing'), findsOneWidget);
  });

  testWidgets('signed-in human help reuses Family preview without sending',
      (tester) async {
    final api = _PublicHelpApi();
    await _mount(tester, const Scaffold(body: HelpScreen()),
        api: api, signedIn: true);
    await tester.tap(find.text('Ask a person'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Open Family messages'));
    await tester.tap(find.text('Open Family messages'));
    await tester.pumpAndSettle();
    expect(find.byType(FamilyMessagesScreen), findsOneWidget);
    expect(api.lastFamilyMessageClientId, isNull);
    expect(api.fakeFamilyMessages, isEmpty);
  });

  for (final guest in [true, false]) {
    testWidgets('${guest ? 'guest' : 'authenticated'} composer follows preference and keeps text fallback',
        (tester) async {
      final voice = _Voice();
      final api = FakeApi();
      final controller = await _mount(tester, guest
          ? const GuestConversationScreen()
          : const ChatDetailScreen(conversation: Conversation(id: 'conversation-1', title: 'Chat')),
          api: api, voice: voice, signedIn: !guest);
      final field = find.byType(TextField);
      final container = ProviderScope.containerOf(tester.element(field));
      final preference = container.read(interactionPreferenceProvider);
      expect(voice.starts, 0);
      expect(find.byKey(const Key('voice-draft-button')), findsOneWidget);
      await preference.setPreference(InteractionPreference.typing);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-draft-button')), findsNothing);
      await tester.enterText(field, 'Editable draft');
      await preference.setPreference(InteractionPreference.speaking);
      await tester.pumpAndSettle();
      expect(voice.starts, 0);
      expect(find.text('Tap the microphone to speak, or type at any time.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-draft-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      voice.lateTranscript!('recognized');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'Editable draft recognized');
      expect(api.lastMessageClientId, isNull);
      expect(controller.guestMessages, isEmpty);
      await preference.setPreference(InteractionPreference.typing);
      await tester.pumpAndSettle();
      voice.lateTranscript!('late');
      expect(tester.widget<TextField>(field).controller!.text, 'Editable draft recognized');
      expect(voice.detaches, greaterThan(0));
      await tester.enterText(field, 'Still typing');
      expect(tester.widget<TextField>(field).controller!.text, 'Still typing');
      expect(tester.takeException(), isNull);
    });
    for (final locale in [englishLocale, traditionalChineseLocale]) {
      testWidgets('${guest ? 'guest' : 'authenticated'} composer at 320px 200% ${locale.languageCode}',
          (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final voice = _Voice();
        await _mount(tester, guest
            ? const GuestConversationScreen()
            : const ChatDetailScreen(conversation: Conversation(id: 'conversation-1', title: 'Chat')),
            voice: voice, signedIn: !guest, locale: locale);
        final field = find.byType(TextField);
        final preference = ProviderScope.containerOf(tester.element(field))
            .read(interactionPreferenceProvider);
        await preference.setPreference(InteractionPreference.speaking);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('voice-draft-button')).hitTestable(), findsOneWidget);
        await tester.enterText(field, 'Editable');
        expect(tester.widget<TextField>(field).controller!.text, 'Editable');
        expect(voice.starts, 0);
      });
    }
  }
}
