import 'package:anxin_companion/src/help_search_panel.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'help_search_controller_test.dart' show ControlledHelpApi, helpController;

ResourceItem sourceItem({bool organisation = true}) => ResourceItem.fromJson({
  'id': 'swd-community-care-service-voucher',
  'title': 'Community Care Service Voucher',
  'excerpt': 'Public service guidance',
  'url': 'https://www.swd.gov.hk/en/pubsvc/elderly/',
  'verified_at': '2026-09-20',
  if (organisation) 'organisation': 'Social Welfare Department',
  'next_steps': ['Read the official service requirements.'],
});

Future<void> showSource(WidgetTester tester, {bool organisation = true,
    bool guest = true, Locale locale = englishLocale}) async {
  final api = ControlledHelpApi();
  final controller = helpController(api, guest: guest);
  addTearDown(controller.dispose);
  Widget view() => MaterialApp(
    locale: locale, supportedLocales: appSupportedLocales,
    localizationsDelegates: appLocalizationsDelegates,
    home: Scaffold(body: SingleChildScrollView(child: AnimatedBuilder(
        animation: controller, builder: (_, __) => HelpSearchPanel(controller: controller)))),
  );
  await tester.pumpWidget(view());
  await tester.pump();
  await tester.enterText(find.byType(TextField), 'community care');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  api.pending.single.result.complete(ResourceSearchResult(query: 'community care',
      retrievalMode: 'keyword', items: [sourceItem(organisation: organisation)]));
  await tester.pumpAndSettle();
}

void main() {
  for (final guest in [true, false]) {
    testWidgets('${guest ? 'guest' : 'signed-in'} Help shows supplied organisation with original date', (tester) async {
      await showSource(tester, guest: guest);
      expect(find.text('Source organisation: Social Welfare Department'), findsOneWidget);
      expect(find.text('Community Care Service Voucher'), findsOneWidget);
      expect(find.text('Verified: 2026/9/20'), findsOneWidget);
      expect(find.text('Open official source'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('legacy result does not infer an organisation from official-looking host', (tester) async {
    await showSource(tester, organisation: false);
    expect(find.text('Source organisation: Not provided'), findsOneWidget);
    expect(find.textContaining('Social Welfare Department'), findsNothing);
  });
  testWidgets('Traditional Chinese organisation fits narrow large text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await showSource(tester, locale: const Locale('zh', 'HK'));
    expect(find.text('來源機構：Social Welfare Department'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
