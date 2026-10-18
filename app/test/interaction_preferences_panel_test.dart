import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/settings_screen.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:anxin_companion/src/interaction_preferences.dart';
import 'package:anxin_companion/src/interaction_preferences_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class RetryStore extends MemoryLocalStore {
  bool failRead = true;
  bool failWrite = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('read failed');
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('write failed');
    await super.write(key, value);
  }
}

void main() {
  testWidgets('existing Settings offers speaking typing and both',
      (tester) async {
    final controller = AppController(
        api: FakeApi(), sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appControllerProvider.overrideWith((ref) => controller),
          localeStoreProvider.overrideWithValue(MemoryLocalStore()),
        ],
        child: const MaterialApp(
            locale: englishLocale,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: appSupportedLocales,
            home: SettingsScreen())));
    await tester.pumpAndSettle();
    for (final choice in ['speaking', 'typing', 'both']) {
      await tester.scrollUntilVisible(
          find.byKey(ValueKey('interaction-$choice')), 150);
      expect(find.byKey(ValueKey('interaction-$choice')), findsOneWidget);
    }
  });
  testWidgets('panel exposes load and save failures with explicit Retry',
      (tester) async {
    final store = RetryStore();
    await tester.pumpWidget(ProviderScope(
        overrides: [localeStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(
            locale: englishLocale,
            home: Scaffold(
                body: SingleChildScrollView(
                    child: InteractionPreferencesPanel())))));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be read'), findsOneWidget);
    store.failRead = false;
    await tester.ensureVisible(find.byKey(const Key('interaction-retry')));
    await tester.tap(find.byKey(const Key('interaction-retry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be read'), findsNothing);
    store.failWrite = true;
    await tester
        .ensureVisible(find.byKey(const ValueKey('interaction-typing')));
    await tester.tap(find.byKey(const ValueKey('interaction-typing')));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be saved'), findsOneWidget);
    store.failWrite = false;
    await tester.ensureVisible(find.byKey(const Key('interaction-retry')));
    await tester.tap(find.byKey(const Key('interaction-retry')));
    await tester.pumpAndSettle();
    expect(store.values[InteractionPreferenceController.storageKey], 'typing');
    expect(find.textContaining('could not be saved'), findsNothing);
  });
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets(
        'panel autosaves all choices at 320px 200% ${locale.languageCode}',
        (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = MemoryLocalStore();
      await tester.pumpWidget(ProviderScope(
          overrides: [localeStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
              locale: locale,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: appSupportedLocales,
              home: Scaffold(
                  body: ListView(
                      padding: const EdgeInsets.all(20),
                      children: const [InteractionPreferencesPanel()])))));
      await tester.pumpAndSettle();
      for (final choice in ['speaking', 'typing', 'both']) {
        final tile = find.byKey(ValueKey('interaction-$choice'));
        await tester.scrollUntilVisible(tile.hitTestable(), 100);
        await tester.pumpAndSettle();
        await tester.tap(tile.hitTestable());
        await tester.pumpAndSettle();
        expect(
            store.values[InteractionPreferenceController.storageKey], choice);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
