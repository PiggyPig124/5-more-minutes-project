import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('English catalog filters retain Chinese data keys',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
        api: FakeApi(), sessionStore: SessionStore(MemoryLocalStore()))
      ..session = AuthSession(
          accessToken: 'token',
          user: const AppUser(
              id: 'elder',
              displayName: 'Senior',
              email: 'elder@example.com',
              role: UserRole.elder))
      ..catalogActivities = const [
        CatalogActivity(
            id: 'a',
            title: 'Ink class',
            description: 'Example',
            organizer: 'Centre',
            district: '深水埗區',
            interestTags: ['書法']),
        CatalogActivity(
            id: 'b',
            title: 'Cooking class',
            description: 'Example',
            organizer: 'Centre',
            district: '觀塘區',
            interestTags: ['煮食']),
      ];
    await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
          locale: englishLocale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: const ActivityCatalogScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Ink class'), findsOneWidget);
    expect(find.text('Cooking class'), findsOneWidget);
    await tester.tap(find.text('Calligraphy'));
    await tester.pumpAndSettle();
    expect(find.text('Ink class'), findsOneWidget);
    expect(find.text('Cooking class'), findsNothing);
    await tester.tap(find.text('Calligraphy'));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sham Shui Po').last);
    await tester.pumpAndSettle();
    expect(find.text('Ink class'), findsOneWidget);
    expect(find.text('Cooking class'), findsNothing);
    expect(find.text('Example activity — details unverified'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
