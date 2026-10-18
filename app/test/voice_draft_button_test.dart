import 'dart:async';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/speech_input.dart';
import 'package:anxin_companion/src/voice_draft_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeVoice extends VoiceInputController {
  int starts = 0, stops = 0, detaches = 0;
  int generation = 0;
  ValueChanged<String>? lateCallback;
  Completer<void>? startGate;
  bool fails = false;
  @override
  Future<void> toggle({required ValueChanged<String> onTranscript}) async {
    starts++;
    final current = ++generation;
    lateCallback = onTranscript;
    await startGate?.future;
    if (current != generation) return;
    if (fails) {
      notice = 'Speech provider unavailable';
      notifyListeners();
      return;
    }
    isListening = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    ++generation;
    stops++;
    isListening = false;
  }

  @override
  void detach() {
    ++generation;
    detaches++;
    isListening = false;
  }
}

Widget harness(
        FakeVoice voice, TextEditingController draft, List<String> changes,
        {bool enabled = true, Locale locale = englishLocale}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: appSupportedLocales,
      home: Scaffold(
          body: Column(children: [
        TextField(key: const Key('draft'), controller: draft),
        VoiceDraftButton(
            voiceController: voice,
            draftController: draft,
            enabled: enabled,
            onDraftChanged: changes.add),
      ])),
    );

void main() {
  testWidgets(
      'only microphone click and disclosure approval start voice; draft never sends',
      (tester) async {
    final voice = FakeVoice();
    final draft = TextEditingController(text: 'Hello');
    final changes = <String>[];
    await tester.pumpWidget(harness(voice, draft, changes));
    expect(voice.starts, 0);
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    expect(voice.starts, 0);
    expect(find.textContaining('provider\'s data policy'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(voice.starts, 0);
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(voice.starts, 1);
    voice.lateCallback!('world');
    await tester.pump();
    expect(draft.text, 'Hello world');
    expect(changes, ['Hello world']);
    voice.lateCallback!('world again');
    await tester.pump();
    expect(draft.text, 'Hello world again');
    await tester.enterText(find.byKey(const Key('draft')), 'Edited');
    expect(draft.text, 'Edited');
    await tester.pumpWidget(const SizedBox());
    draft.dispose();
  });
  testWidgets('typing disables microphone and detaches late callbacks',
      (tester) async {
    final voice = FakeVoice();
    final draft = TextEditingController(text: 'Keep');
    final changes = <String>[];
    await tester.pumpWidget(harness(voice, draft, changes));
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(harness(voice, draft, changes, enabled: false));
    await tester.pump();
    expect(find.byKey(const Key('voice-draft-button')), findsNothing);
    voice.lateCallback!('late');
    expect(draft.text, 'Keep');
    expect(changes, isEmpty);
    expect(voice.detaches, greaterThan(0));
    await tester.enterText(find.byKey(const Key('draft')), 'Text fallback');
    expect(draft.text, 'Text fallback');
    await tester.pumpWidget(const SizedBox());
    draft.dispose();
  });
  testWidgets(
      'removal during start prevents late draft writes and cancels completion',
      (tester) async {
    final voice = FakeVoice()..startGate = Completer<void>();
    final draft = TextEditingController(text: 'Keep');
    final changes = <String>[];
    await tester.pumpWidget(harness(voice, draft, changes));
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(voice.starts, 1);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    draft.dispose();
    voice.lateCallback!('late');
    voice.startGate!.complete();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(voice.detaches, greaterThan(0));
    expect(voice.isListening, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('source failure is shown and typing remains usable',
      (tester) async {
    final voice = FakeVoice()..fails = true;
    final draft = TextEditingController();
    final changes = <String>[];
    await tester.pumpWidget(harness(voice, draft, changes));
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Speech provider unavailable'), findsOneWidget);
    expect(find.textContaining('You can still type'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('draft')), 'Still editable');
    expect(draft.text, 'Still editable');
    await tester.pumpWidget(const SizedBox());
    draft.dispose();
  });
  testWidgets('typing edits before first transcript are preserved',
      (tester) async {
    final voice = FakeVoice();
    final draft = TextEditingController(text: 'Initial');
    final changes = <String>[];
    await tester.pumpWidget(harness(voice, draft, changes));
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('draft')), 'Typed while listening');
    voice.lateCallback!('first words');
    expect(draft.text, 'Typed while listening first words');
    await tester.pumpWidget(const SizedBox());
    draft.dispose();
  });
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets('disclosure reachable at 320px 200% ${locale.languageCode}',
        (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final voice = FakeVoice();
      final draft = TextEditingController();
      await tester.pumpWidget(harness(voice, draft, [], locale: locale));
      await tester.tap(find.byKey(const Key('voice-draft-button')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester
          .tap(find.text(locale.languageCode == 'en' ? 'Cancel' : '取消'));
      await tester.pumpAndSettle();
      expect(voice.starts, 0);
      await tester.pumpWidget(const SizedBox());
      draft.dispose();
    });
  }
}
