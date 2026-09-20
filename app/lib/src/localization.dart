import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'storage.dart';

const traditionalChineseLocale =
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
const englishLocale = Locale('en');
const appSupportedLocales = [traditionalChineseLocale, englishLocale];
const appLocalizationsDelegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

String tr(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'en' ? en : zh;

final localeStoreProvider = Provider<LocalStore>((ref) => SecureLocalStore());
final localeControllerProvider =
    ChangeNotifierProvider<LocaleController>((ref) {
  final controller = LocaleController(ref.watch(localeStoreProvider));
  controller.initialize();
  return controller;
});

/// Device preference, deliberately independent of authentication and account data.
class LocaleController extends ChangeNotifier {
  LocaleController(this._store);

  static const storageKey = 'anxin.interface_locale';
  final LocalStore _store;
  Locale _locale = traditionalChineseLocale;
  Locale get locale => _locale;
  bool loadFailed = false;
  bool saveFailed = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void>? _initialization;
  Future<void> _writes = Future<void>.value();

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    final revision = _revision;
    try {
      final saved = await _store.read(storageKey);
      if (_disposed || revision != _revision) return;
      _locale = saved == 'en' ? englishLocale : traditionalChineseLocale;
      loadFailed = false;
    } on Object {
      if (_disposed || revision != _revision) return;
      loadFailed = true;
    }
    _notify();
  }

  Future<void> setLocale(Locale value) {
    if (_disposed) return Future<void>.value();
    final selected =
        value.languageCode == 'en' ? englishLocale : traditionalChineseLocale;
    final revision = ++_revision;
    _locale = selected;
    loadFailed = false;
    saveFailed = false;
    _notify();
    // Serialize saves so an older, slower write cannot replace a newer choice.
    _writes = _writes.then((_) async {
      try {
        await _store.write(
            storageKey, selected.languageCode == 'en' ? 'en' : 'zh-Hant');
        if (revision == _revision) saveFailed = false;
      } on Object {
        if (revision == _revision) saveFailed = true;
      }
      _notify();
    });
    return _writes;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
