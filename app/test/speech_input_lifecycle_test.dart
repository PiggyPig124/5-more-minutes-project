import 'dart:async';

import 'package:anxin_companion/src/speech_input.dart';
import 'package:anxin_companion/src/voice_draft_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Fake at the existing SpeechToText injection boundary: no plugin/mic calls.
class DelayedSpeech implements stt.SpeechToText {
  Completer<bool>? initializeGate;
  Completer<void>? localesGate;
  Completer<void>? listenGate;
  Completer<void>? cancelGate;
  final events = <String>[];
  final results = <stt.SpeechResultListener?>[];
  bool available = false;
  bool listening = false;
  int initializations = 0;
  int get listens => results.length;
  @override
  bool get isAvailable => available;
  @override
  bool get isListening => listening;

  Future<bool> _initialize() async {
    initializations++;
    events.add('initialize');
    available = await (initializeGate?.future ?? Future.value(true));
    return available;
  }

  Future<List<stt.LocaleName>> _locales() async {
    events.add('locales');
    await localesGate?.future;
    return [stt.LocaleName('zh-HK', 'Cantonese')];
  }

  Future<void> _listen(stt.SpeechResultListener? onResult) async {
    final number = results.length + 1;
    events.add('listen-$number');
    results.add(onResult);
    await listenGate?.future;
    listening = true;
    events.add('listening-$number');
  }

  Future<void> _cancel() async {
    events.add('cancel');
    await cancelGate?.future;
    listening = false;
    events.add('cancelled');
  }

  Future<void> _stop() async {
    events.add('stop');
    listening = false;
  }

  void emit(int session, String text) =>
      results[session]?.call(SpeechRecognitionResult.fromJson({
        'alternates': [
          {'recognizedWords': text, 'confidence': 1.0}
        ],
        'resultType': 1
      }));

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #initialize:
        return _initialize();
      case #locales:
        return _locales();
      case #listen:
        return _listen(
            invocation.namedArguments[#onResult] as stt.SpeechResultListener?);
      case #cancel:
        return _cancel();
      case #stop:
        return _stop();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  for (final action in ['detach', 'stop', 'dispose']) {
    test('delayed initialize cannot listen after $action', () async {
      final speech = DelayedSpeech()..initializeGate = Completer<bool>();
      final controller = VoiceInputController(speech: speech);
      final drafts = <String>[];
      final start = controller.start(onTranscript: drafts.add);
      await flush();
      Future<void>? stopped;
      if (action == 'detach') controller.detach();
      if (action == 'stop') stopped = controller.stop();
      if (action == 'dispose') controller.dispose();
      speech.initializeGate!.complete(true);
      await start;
      await stopped;
      await flush();
      expect(speech.listens, 0);
      expect(drafts, isEmpty);
      if (action != 'dispose') controller.dispose();
    });
  }

  test('delayed locale lookup cannot listen after detach', () async {
    final speech = DelayedSpeech()..localesGate = Completer<void>();
    final controller = VoiceInputController(speech: speech);
    final start = controller.start(onTranscript: (_) {});
    await flush();
    expect(speech.events, contains('locales'));
    controller.detach();
    speech.localesGate!.complete();
    await start;
    expect(speech.listens, 0);
    controller.dispose();
  });

  test(
      'old and new requests share pending initialization but only newest listens',
      () async {
    final speech = DelayedSpeech()..initializeGate = Completer<bool>();
    final controller = VoiceInputController(speech: speech);
    final oldDrafts = <String>[], newDrafts = <String>[];
    final old = controller.start(onTranscript: oldDrafts.add);
    controller.detach();
    final next = controller.start(onTranscript: newDrafts.add);
    await flush();
    speech.initializeGate!.complete(true);
    await Future.wait([old, next]);
    expect(speech.initializations, 1);
    expect(speech.listens, 1);
    speech.emit(0, 'new draft');
    expect(oldDrafts, isEmpty);
    expect(newDrafts, ['new draft']);
    expect(controller.isListening, isTrue);
    expect(controller.notice, isNull);
    controller.dispose();
  });

  test('late old results never reach old or newer callbacks', () async {
    final speech = DelayedSpeech();
    final controller = VoiceInputController(speech: speech);
    final oldDrafts = <String>[], newDrafts = <String>[];
    await controller.start(onTranscript: oldDrafts.add);
    controller.detach();
    await controller.start(onTranscript: newDrafts.add);
    speech.emit(0, 'stale');
    speech.emit(1, 'current');
    expect(oldDrafts, isEmpty);
    expect(newDrafts, ['current']);
    controller.dispose();
    speech.emit(1, 'after dispose');
    expect(newDrafts, ['current']);
  });

  test('pending listen cleanup finishes before newer listen starts', () async {
    final speech = DelayedSpeech()
      ..listenGate = Completer<void>()
      ..cancelGate = Completer<void>();
    final controller = VoiceInputController(speech: speech);
    final oldDrafts = <String>[], newDrafts = <String>[];
    final old = controller.start(onTranscript: oldDrafts.add);
    await flush();
    expect(speech.listens, 1);
    controller.detach();
    final next = controller.start(onTranscript: newDrafts.add);
    await flush();
    expect(speech.listens, 1,
        reason: 'new listen must wait for old listen and cancellation');
    speech.listenGate!.complete();
    await flush();
    expect(speech.events, contains('cancel'));
    expect(speech.listens, 1,
        reason: 'new listen must wait for pending cancel');
    speech.cancelGate!.complete();
    await Future.wait([old, next]);
    expect(speech.listens, 2);
    expect(speech.events.indexOf('cancelled'),
        lessThan(speech.events.indexOf('listen-2')));
    expect(controller.isListening, isTrue);
    speech.emit(0, 'stale');
    speech.emit(1, 'new draft');
    expect(oldDrafts, isEmpty);
    expect(newDrafts, ['new draft']);
    controller.dispose();
  });

  test('stop suppresses late result immediately while keeping draft', () async {
    final speech = DelayedSpeech();
    final controller = VoiceInputController(speech: speech);
    final drafts = <String>[];
    await controller.start(onTranscript: drafts.add);
    speech.emit(0, 'keep');
    final stop = controller.stop();
    speech.emit(0, 'late');
    await stop;
    expect(drafts, ['keep']);
    expect(controller.isListening, isFalse);
    controller.dispose();
  });

  testWidgets(
      'old widget completion cannot stop the newer shared-controller session',
      (tester) async {
    final speech = DelayedSpeech()..initializeGate = Completer<bool>();
    final controller = VoiceInputController(speech: speech);
    final oldDraft = TextEditingController(text: 'Old');
    final newDraft = TextEditingController(text: 'New');
    final oldChanges = <String>[], newChanges = <String>[];
    Widget composer(
            int key, TextEditingController draft, List<String> changes) =>
        MaterialApp(
            home: Scaffold(
                body: Column(children: [
          TextField(controller: draft),
          VoiceDraftButton(
              key: ValueKey(key),
              voiceController: controller,
              draftController: draft,
              onDraftChanged: changes.add),
        ])));
    await tester.pumpWidget(composer(1, oldDraft, oldChanges));
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(composer(2, newDraft, newChanges));
    await tester.tap(find.byKey(const Key('voice-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    speech.initializeGate!.complete(true);
    await tester.pumpAndSettle();
    expect(speech.listens, 1);
    expect(controller.isListening, isTrue);
    speech.emit(0, 'current');
    expect(oldChanges, isEmpty);
    expect(newDraft.text, 'New current');
    expect(newChanges, ['New current']);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    oldDraft.dispose();
    newDraft.dispose();
    controller.dispose();
  });
}
