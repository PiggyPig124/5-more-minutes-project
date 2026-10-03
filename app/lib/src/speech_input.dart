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
  ValueChanged<String>? _onTranscript;

  bool isListening = false;
  String? notice;

  Future<void> toggle({required ValueChanged<String> onTranscript}) async {
    if (isListening || _speech.isListening) {
      await stop();
      return;
    }
    await start(onTranscript: onTranscript);
  }

  Future<void> start({required ValueChanged<String> onTranscript}) async {
    notice = null;
    _onTranscript = onTranscript;
    final available = await _initialize();
    if (!available) {
      notice =
          'Cantonese voice input is not available on this device or browser.';
      notifyListeners();
      return;
    }

    final localeId = await _cantoneseLocaleId();
    if (localeId == null) {
      notice =
          'No Hong Kong Cantonese or Chinese speech-recognition language is installed on this device.';
      notifyListeners();
      return;
    }

    try {
      isListening = true;
      notifyListeners();
      await _speech.listen(
        onResult: (result) => _onTranscript?.call(result.recognizedWords),
        listenOptions: stt.SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          cancelOnError: true,
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 3),
        ),
      );
    } catch (_) {
      isListening = false;
      notice =
          'Voice input could not start. Check microphone permission and try again.';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {
      // The transcript is already in the editable composer, so a failed stop
      // should not discard it or prevent the user from sending it.
    }
    isListening = false;
    notice ??= 'Transcript ready to review and edit.';
    notifyListeners();
  }

  /// Detach a chat screen before it is disposed, so it cannot update an old
  /// draft if a browser or device reports a final result late.
  void detach() {
    _onTranscript = null;
    if (_speech.isListening) unawaited(_speech.cancel());
    isListening = false;
  }

  Future<bool> _initialize() async {
    if (_initialized) return _speech.isAvailable;
    _initialized = true;
    try {
      return await _speech.initialize(onStatus: _onStatus, onError: _onError);
    } catch (_) {
      return false;
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
    if (status == 'done' || status == 'notListening') {
      isListening = false;
      notice ??= 'Transcript ready to review and edit.';
      notifyListeners();
    }
  }

  void _onError(SpeechRecognitionError error) {
    isListening = false;
    notice = error.errorMsg == 'error_speech_timeout'
        ? 'I did not hear anything. Try again or type your message.'
        : 'Voice input stopped. Check microphone permission and try again.';
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_speech.cancel());
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
