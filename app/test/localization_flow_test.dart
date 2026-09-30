import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/settings_screen.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('English feature screens fit a phone at increased text size',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = AppController(
      api: FakeApi(role: UserRole.elder),
      sessionStore: SessionStore(MemoryLocalStore()),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appControllerProvider.overrideWith((ref) => controller),
        localeStoreProvider.overrideWithValue(MemoryLocalStore()),
      ],
      child: const AnxinApp(),
    ));
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(LoginScreen)));
    await container
        .read(localeControllerProvider)
        .setLocale(const Locale('en'));
    await controller.login(email: 'elder@example.com', password: 'password123');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final tab in ['Family', 'Community', 'Help', 'Settings', 'Home']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$tab tab overflow');
    }
    final navigator = Navigator.of(tester.element(find.byType(ShellScreen)));
    for (final screen in <Widget>[
      const MemoriesScreen(),
      const StoriesScreen(),
      const ResourcesScreen(),
      const FamilyMessagesScreen(),
      const SettingsScreen(),
    ]) {
      navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: '${screen.runtimeType} overflow');
      navigator.pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('changing language preserves session and open route',
      (tester) async {
    final store = MemoryLocalStore();
    final controller = AppController(
      api: FakeApi(role: UserRole.elder),
      sessionStore: SessionStore(MemoryLocalStore()),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appControllerProvider.overrideWith((ref) => controller),
        localeStoreProvider.overrideWithValue(store),
      ],
      child: const AnxinApp(),
    ));
    await tester.pumpAndSettle();
    await controller.login(email: 'elder@example.com', password: 'password123');
    await tester.pumpAndSettle();
    final originalUser = controller.user!.id;
    final context = tester.element(find.byType(ShellScreen));
    final container = ProviderScope.containerOf(context);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const SettingsScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();
    expect(find.text('Interface language'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
        Localizations.localeOf(tester.element(find.byType(SettingsScreen)))
            .languageCode,
        'en');
    expect(controller.user!.id, originalUser);
    expect(controller.isSignedIn, isTrue);
    expect(tester.takeException(), isNull);
    await container.read(localeControllerProvider).setLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        );
    await tester.pumpAndSettle();
    expect(
        Localizations.localeOf(tester.element(find.byType(SettingsScreen)))
            .languageCode,
        'zh');
    expect(controller.user!.id, originalUser);
  });

  testWidgets('English login renders at phone width and keeps entered fields',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(
      api: FakeApi(),
      sessionStore: SessionStore(MemoryLocalStore()),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appControllerProvider.overrideWith((ref) => controller),
        localeStoreProvider.overrideWithValue(MemoryLocalStore()),
      ],
      child: const AnxinApp(),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField).first, 'reader@example.com');
    final container =
        ProviderScope.containerOf(tester.element(find.byType(LoginScreen)));
    await container
        .read(localeControllerProvider)
        .setLocale(const Locale('en'));
    await tester.pumpAndSettle();
    expect(find.text('reader@example.com'), findsOneWidget);
    expect(
        Localizations.localeOf(tester.element(find.byType(LoginScreen)))
            .languageCode,
        'en');
    expect(tester.takeException(), isNull);
  });
}
