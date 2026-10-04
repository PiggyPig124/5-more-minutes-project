import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CatalogActivity item(Map<String, dynamic> fields) => CatalogActivity.fromJson({
      'id': 'activity',
      'title': 'Community class',
      'description': 'Details',
      'verified': true,
      'url': 'https://example.org/activity',
      ...fields,
    });
Future<void> showCard(WidgetTester tester, CatalogActivity activity,
    {bool interested = false,
    Locale locale = englishLocale,
    double scale = 1,
    Future<bool> Function()? action}) async {
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: appLocalizationsDelegates,
    home: Scaffold(
        body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: SingleChildScrollView(
          child: CatalogActivityCard(
              activity: activity,
              isInterested: interested,
              onInterest: action)),
    )),
  ));
  await tester.pumpAndSettle();
}

void main() {
  test(
      'catalog parses additive availability and exact recommendation provenance',
      () {
    final dynamic activity = item({
      'available': false,
      'availability_status': 'expired',
      'recommendation_basis': 'memory',
      'recommendation_reasons': [
        {
          'memory_id': 'm1',
          'source_type': 'preference',
          'source_text': 'I enjoy gardening',
          'matched_tag': 'gardening'
        }
      ],
    });
    expect(activity.available, false);
    expect(activity.availabilityStatus, 'expired');
    expect(activity.recommendationBasis, 'memory');
    expect(activity.recommendationReasons.single.memoryId, 'm1');
    expect(
        activity.recommendationReasons.single.sourceText, 'I enjoy gardening');
    expect(activity.recommendationReasons.single.matchedTag, 'gardening');
    final dynamic old = item({});
    expect(old.available, true);
    expect(old.recommendationBasis, isNull);
    expect(old.recommendationReasons, isEmpty);
  });
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    final english = locale == englishLocale;
    testWidgets(
        'general recommendations are explicit in ${locale.languageCode}',
        (tester) async {
      await showCard(tester, item({'recommendation_basis': 'general'}),
          locale: locale);
      expect(
          find.text(english ? 'General suggestion' : '一般建議'), findsOneWidget);
      expect(find.text(english ? 'Saved preference' : '已儲存的喜好'), findsNothing);
    });
    testWidgets(
        'saved preference and confirmed skill explain matches in ${locale.languageCode}',
        (tester) async {
      await showCard(
          tester,
          item({
            'recommendation_basis': 'memory',
            'recommendation_reasons': [
              {
                'memory_id': 'p',
                'source_type': 'preference',
                'source_text': 'I enjoy gardening',
                'matched_tag': 'gardening'
              },
              {
                'memory_id': 's',
                'source_type': 'skill',
                'source_text': 'I teach cooking',
                'matched_tag': 'cooking'
              },
            ]
          }),
          locale: locale);
      expect(
          find.textContaining(english
              ? 'Saved preference: I enjoy gardening'
              : '已儲存的喜好：I enjoy gardening'),
          findsOneWidget);
      expect(
          find.textContaining(english
              ? 'Confirmed skill: I teach cooking'
              : '已確認的技能：I teach cooking'),
          findsOneWidget);
      expect(
          find.textContaining(
              english ? 'Matched topic: gardening' : '配對主題：gardening'),
          findsOneWidget);
    });
  }
  testWidgets('older metadata does not invent a personalized explanation',
      (tester) async {
    await showCard(tester, item({}));
    expect(find.text('General suggestion'), findsNothing);
    expect(find.textContaining('Saved preference'), findsNothing);
  });
  for (final status in ['expired', 'unverified', 'invalid_date']) {
    testWidgets(
        '$status history keeps withdraw available and hides source navigation',
        (tester) async {
      var calls = 0;
      final activity =
          item({'available': false, 'availability_status': status});
      await showCard(tester, activity, interested: true, action: () async {
        calls++;
        return true;
      });
      expect(find.text('Community class'), findsOneWidget);
      expect(find.text('Open source'), findsNothing);
      expect(find.text('Withdraw interest'), findsOneWidget);
      await tester.tap(find.text('Withdraw interest'));
      expect(calls, 1);
      await showCard(tester, activity, action: () async {
        calls++;
        return true;
      });
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });
  }
  testWidgets('date unknown shows warning with last checked date and source',
      (tester) async {
    await showCard(
        tester,
        item({
          'available': true,
          'availability_status': 'date_unknown',
          'verified_at': '2026-09-20'
        }));
    expect(find.textContaining('Activity dates unknown'), findsOneWidget);
    expect(find.textContaining('Last checked: 2026-09-20'), findsOneWidget);
    expect(find.textContaining('https://example.org/activity'), findsOneWidget);
  });
  testWidgets('catalog content wraps on small phone with enlarged text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await showCard(
        tester,
        item({
          'district': 'A very long district name for this community activity',
          'contribution_type': 'contribute',
          'availability_status': 'date_unknown',
          'recommendation_basis': 'memory',
          'recommendation_reasons': [
            {
              'memory_id': 'p',
              'source_type': 'preference',
              'source_text':
                  'I enjoy gardening with other people in my neighbourhood',
              'matched_tag': 'gardening'
            }
          ]
        }),
        scale: 2,
        action: () async => true);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Express interest'));
    expect(tester.takeException(), isNull);
  });
}
