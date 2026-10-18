import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'localization.dart';
import 'storage.dart';

enum InteractionPreference { speaking, typing, both }

final interactionPreferenceProvider =
    ChangeNotifierProvider<InteractionPreferenceController>((ref) {
  final controller =
      InteractionPreferenceController(ref.watch(localeStoreProvider));
  controller.reload();
  return controller;
});

/// Device-only preference, independent of account, Memory and chat drafts.
class InteractionPreferenceController extends ChangeNotifier {
  InteractionPreferenceController(this._store);

  static const storageKey = 'anxin.interaction_preference';
  final LocalStore _store;
  InteractionPreference preference = InteractionPreference.both;
  bool get allowsVoice => preference != InteractionPreference.typing;
  bool get prefersSpeaking => preference == InteractionPreference.speaking;
  bool loading = false;
  bool saving = false;
  bool loadFailed = false;
  bool saveFailed = false;
  bool _disposed = false;
  int _generation = 0;
  int _choiceRevision = 0;
  Future<void> _writes = Future<void>.value();

  Future<void> reload() async {
    if (_disposed) return;
    final generation = ++_generation;
    loading = true;
    loadFailed = false;
    _notify();
    // Read after preceding saves; a new choice invalidates this read.
    await _writes;
    if (_disposed || generation != _generation) return;
    if (saveFailed) {
      loading = false;
      _notify();
      return;
    }
    try {
      final saved = await _store.read(storageKey);
      if (_disposed || generation != _generation) return;
      preference = InteractionPreference.values.firstWhere(
        (value) => value.name == saved,
        orElse: () => InteractionPreference.both,
      );
    } on Object {
      if (_disposed || generation != _generation) return;
      loadFailed = true;
    }
    loading = false;
    _notify();
  }

  Future<void> setPreference(InteractionPreference value) {
    if (_disposed) return Future<void>.value();
    ++_generation;
    final revision = ++_choiceRevision;
    preference = value;
    loading = false;
    saving = true;
    loadFailed = false;
    saveFailed = false;
    _notify();
    _writes = _writes.then((_) async {
      if (_disposed) return;
      try {
        await _store.write(storageKey, value.name);
        if (_disposed || revision != _choiceRevision) return;
        saveFailed = false;
      } on Object {
        if (_disposed || revision != _choiceRevision) return;
        saveFailed = true;
      }
      saving = false;
      _notify();
    });
    return _writes;
  }

  Future<void> retry() => saveFailed ? setPreference(preference) : reload();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
