import 'dart:async';

import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to Traditional Chinese and reloads a saved English preference',
      () async {
    final store = MemoryLocalStore();
    final first = LocaleController(store);
    await first.initialize();
    expect(first.locale, traditionalChineseLocale);
    await first.setLocale(englishLocale);
    first.dispose();
    final reopened = LocaleController(store);
    await reopened.initialize();
    expect(reopened.locale, englishLocale);
    reopened.dispose();
  });

  test('sign-out preserves device language', () async {
    final store = MemoryLocalStore();
    final controller = LocaleController(store);
    await controller.setLocale(englishLocale);
    await SessionStore(store).clearSession();
    expect(store.values[LocaleController.storageKey], 'en');
    controller.dispose();
  });

  test('late initial read does not overwrite a newer selection', () async {
    final store = DeferredReadStore();
    final controller = LocaleController(store);
    final initialization = controller.initialize();
    await controller.setLocale(englishLocale);
    store.readResult.complete('zh-Hant');
    await initialization;
    expect(controller.locale, englishLocale);
    expect(store.values[LocaleController.storageKey], 'en');
    controller.dispose();
  });

  test('rapid selections serialize persistence and leave the latest value',
      () async {
    final store = DeferredWriteStore();
    final controller = LocaleController(store);
    final first = controller.setLocale(englishLocale);
    final second = controller.setLocale(traditionalChineseLocale);
    await Future<void>.delayed(Duration.zero);
    expect(store.started, ['en']);
    store.firstWrite.complete();
    await Future.wait([first, second]);
    expect(store.started, ['en', 'zh-Hant']);
    expect(store.values[LocaleController.storageKey], 'zh-Hant');
    controller.dispose();
  });

  test('storage failure keeps chosen language and supports retry', () async {
    final store = FailingStore();
    final controller = LocaleController(store);
    await controller.initialize();
    expect(controller.loadFailed, isTrue);
    await controller.setLocale(englishLocale);
    expect(controller.locale, englishLocale);
    expect(controller.saveFailed, isTrue);
    store.fail = false;
    await controller.setLocale(englishLocale);
    expect(controller.saveFailed, isFalse);
    expect(store.values[LocaleController.storageKey], 'en');
    controller.dispose();
  });

  test('disposing while loading avoids late notifier updates', () async {
    final store = DeferredReadStore();
    final controller = LocaleController(store);
    final loading = controller.initialize();
    controller.dispose();
    store.readResult.complete('en');
    await loading;
  });

  test('invalid saved value safely falls back to Traditional Chinese',
      () async {
    final store = MemoryLocalStore()
      ..values[LocaleController.storageKey] = 'not-a-locale';
    final controller = LocaleController(store);
    await controller.initialize();
    expect(controller.locale, traditionalChineseLocale);
    controller.dispose();
  });
}

class DeferredReadStore extends MemoryLocalStore {
  final readResult = Completer<String?>();
  @override
  Future<String?> read(String key) => readResult.future;
}

class DeferredWriteStore extends MemoryLocalStore {
  final firstWrite = Completer<void>();
  final started = <String>[];
  @override
  Future<void> write(String key, String value) async {
    started.add(value);
    if (started.length == 1) await firstWrite.future;
    await super.write(key, value);
  }
}

class FailingStore extends MemoryLocalStore {
  bool fail = true;
  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('storage unavailable');
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('storage unavailable');
    await super.write(key, value);
  }
}
