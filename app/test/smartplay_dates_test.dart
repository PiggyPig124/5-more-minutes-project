import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/localization.dart';

void main() {
  const schedule =
      '2026-10-05 – 2026-10-28; Mon,Wed (Exclude 19 Oct 2026); 10:00–12:00';
  Future<void> show(WidgetTester tester, {String dateText = ''}) async {
    await tester.pumpWidget(MaterialApp(
        locale: englishLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
            body: SingleChildScrollView(
                child: CommunityListingCard(
                    title: 'Synthetic official activity',
                    summary: 'Synthetic summary',
                    organization: 'LCSD',
                    area: 'Sha Tin',
                    sourceName: 'LCSD / DATA.GOV.HK',
                    lastCheckedAt: null,
                    sourceUrl: null,
                    kind: 'activity',
                    eventStartAt: DateTime.parse('2026-10-05T00:00:00+08:00'),
                    eventEndAt: DateTime.parse('2026-10-28T23:59:59+08:00'),
                    dateText: dateText)))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'fallback official Hong Kong calendar dates do not shift to UTC previous day',
      (tester) async {
    await show(tester);
    expect(find.textContaining('2026/10/4'), findsNothing);
    expect(find.textContaining('2026/10/5'), findsOneWidget);
    expect(find.textContaining('2026/10/28'), findsOneWidget);
  });
  testWidgets(
      'full original schedule takes priority including excluded sessions and times',
      (tester) async {
    await show(tester, dateText: schedule);
    expect(find.text('Schedule: $schedule'), findsOneWidget);
    expect(find.textContaining('2026/10/4'), findsNothing);
    expect(find.textContaining('When:'), findsNothing);
  });
}
