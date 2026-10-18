import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Keeps one platform speech-recognition session alive for the app.
///
/// This voice feature intentionally uses the device/browser recognizer:
/// it turns a short Cantonese utterance into editable draft text and does not
/// upload or retain an audio recording in Anxin's backend.
class VoiceInputController extends ChangeNotifier {
  VoiceInputController({stt.SpeechToText? speech})
      : _speech = speech ?? stt.SpeechToText();

  final stt.SpeechToText _speech;
  bool _initialized = false;
  Future<bool>? _initialization;
  Future<void> _platformOperations = Future<void>.value();
  bool _disposed = false;
  int _generation = 0;
  int? _activeGeneration;

  bool isListening = false;
  String? notice;

  Future<void> toggle({required ValueChanged<String> onTranscript}) async {
    if (_disposed) return;
    if (isListening) {
      await stop();
      return;
    }
    await start(onTranscript: onTranscript);
  }

  Future<void> start({required ValueChanged<String> onTranscript}) async {
    if (_disposed) return;
    final hadSession = _activeGeneration != null;
    final generation = ++_generation;
    _activeGeneration = null;
    isListening = false;
    notice = null;
    if (hadSession) unawaited(_cancelPlatform());
    final available = await _initialize();
    if (!_current(generation)) return;
    if (!available) {
      notice =
          'Cantonese voice input is not available on this device or browser.';
      notifyListeners();
      return;
    }

    final localeId = await _cantoneseLocaleId();
    if (!_current(generation)) return;
    if (localeId == null) {
      notice =
          'No Hong Kong Cantonese or Chinese speech-recognition language is installed on this device.';
      notifyListeners();
      return;
    }

    try {
      await _enqueuePlatform(() async {
        if (!_current(generation)) return;
        _activeGeneration = generation;
        isListening = true;
        notifyListeners();
        // A synchronous listener may detach while receiving this notification.
        if (!_current(generation)) return;
        await _speech.listen(
          onResult: (result) {
            if (_current(generation)) onTranscript(result.recognizedWords);
          },
          listenOptions: stt.SpeechListenOptions(
            localeId: localeId,
            partialResults: true,
            cancelOnError: true,
            listenFor: const Duration(seconds: 45),
            pauseFor: const Duration(seconds: 3),
          ),
        );
      });
    } catch (_) {
      if (!_current(generation)) return;
      _activeGeneration = null;
      isListening = false;
      notice =
          'Voice input could not start. Check microphone permission and try again.';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    ++_generation;
    _activeGeneration = null;
    isListening = false;
    notice ??= 'Transcript ready to review and edit.';
    notifyListeners();
    try {
      await _enqueuePlatform(_speech.stop);
    } catch (_) {
      // The transcript is already in the editable composer, so a failed stop
      // should not discard it or prevent the user from sending it.
    }
  }

  /// Detach a chat screen before it is disposed, so it cannot update an old
  /// draft if a browser or device reports a final result late.
  void detach() {
    if (_disposed) return;
    ++_generation;
    _activeGeneration = null;
    isListening = false;
    unawaited(_cancelPlatform());
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  /// Keep cleanup behind any pending listen and ahead of the next listen.
  /// The queue continues after a platform error, so text input stays usable.
  Future<void> _enqueuePlatform(Future<void> Function() operation) {
    final next = _platformOperations.then((_) => operation());
    _platformOperations = next.catchError((Object _) {});
    return next;
  }

  Future<void> _cancelPlatform() async {
    try {
      await _enqueuePlatform(_speech.cancel);
    } on Object {
      // Draft callbacks were already invalidated synchronously.
    }
  }

  Future<bool> _initialize() {
    if (_initialized) return Future<bool>.value(_speech.isAvailable);
    return _initialization ??= _initializePlatform();
  }

  Future<bool> _initializePlatform() async {
    try {
      final available =
          await _speech.initialize(onStatus: _onStatus, onError: _onError);
      _initialized = available;
      return available;
    } catch (_) {
      return false;
    } finally {
      _initialization = null;
    }
  }

  Future<String?> _cantoneseLocaleId() async {
    try {
      final locales = await _speech.locales();
      return selectCantoneseLocaleId(
        locales.map((locale) => locale.localeId),
        isWeb: kIsWeb,
      );
    } catch (_) {
      if (kIsWeb) return webCantoneseLocaleId;
    }
    return null;
  }

  void _onStatus(String status) {
    if (_disposed || _activeGeneration != _generation) return;
    if (status == 'done' || status == 'notListening') {
      isListening = false;
      notice ??= 'Transcript ready to review and edit.';
      notifyListeners();
    }
  }

  void _onError(SpeechRecognitionError error) {
    if (_disposed || _activeGeneration != _generation) return;
    isListening = false;
    notice = error.errorMsg == 'error_speech_timeout'
        ? 'I did not hear anything. Try again or type your message.'
        : 'Voice input stopped. Check microphone permission and try again.';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _activeGeneration = null;
    isListening = false;
    unawaited(_cancelPlatform());
    super.dispose();
  }
}

const webEnglishLocaleId = 'en-US';
const webCantoneseLocaleId = 'zh-HK';

/// Prefers a Hong Kong Cantonese recognizer and only falls back to another
/// Chinese locale. Chrome may return no supported locales, so the browser is
/// explicitly asked for Hong Kong Chinese rather than its system default.
String? selectCantoneseLocaleId(
  Iterable<String> localeIds, {
  required bool isWeb,
}) {
  final normalized = localeIds
      .map((locale) => locale.replaceAll('_', '-'))
      .toList(growable: false);
  for (final locale in normalized) {
    if (locale.toLowerCase() == 'yue-hk') return locale;
  }
  for (final locale in normalized) {
    if (locale.toLowerCase() == 'zh-hk') return locale;
  }
  for (final locale in normalized) {
    final lower = locale.toLowerCase();
    if (lower.startsWith('yue') || lower.startsWith('zh')) return locale;
  }
  return isWeb ? webCantoneseLocaleId : null;
}

/// Retained for callers that explicitly need an English recognizer.
String? selectEnglishLocaleId(
  Iterable<String> localeIds, {
  required bool isWeb,
}) {
  for (final localeId in localeIds) {
    if (localeId.toLowerCase().startsWith('en')) return localeId;
  }
  return isWeb ? webEnglishLocaleId : null;
}
