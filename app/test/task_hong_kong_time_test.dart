import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/task_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_sharing_screen_test.dart' as existing;

class HongKongTimeServer extends existing.SharingServer {
  @override
  Map<String, Object?> get task => {
        ...super.task,
        'due_at': '2026-10-08T23:00:00Z',
      };
}

Future<BuildContext> localizedContext(
    WidgetTester tester, Locale locale) async {
  late BuildContext result;
  await tester.pumpWidget(MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: Builder(builder: (context) {
        result = context;
        return const SizedBox.shrink();
      })));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  for (final locale in [englishLocale, const Locale('zh', 'HK')]) {
    testWidgets(
        'equivalent offset instants display 17:00 Hong Kong independently of device zone in $locale',
        (tester) async {
      final context = await localizedContext(tester, locale);
      final outputs = [
        '2026-10-08T09:00:00Z',
        '2026-10-08T17:00:00+08:00',
        '2026-10-08T02:00:00-07:00',
        '2026-10-08T14:30:00+05:30',
      ]
          .map(
              (input) => formatTaskHongKongTime(context, DateTime.parse(input)))
          .toList();
      expect(outputs.toSet(), hasLength(1));
      expect(outputs.first, isNotEmpty);
      expect(outputs.first, contains('17:00'));
      expect(outputs.first,
          contains(locale.languageCode == 'en' ? 'Hong Kong' : '香港'));
      expect(
          outputs.first,
          contains(MaterialLocalizations.of(context)
              .formatFullDate(DateTime(2026, 10, 8))));
    });

    testWidgets(
        '23:00 UTC crosses into the next Hong Kong calendar day in $locale',
        (tester) async {
      final context = await localizedContext(tester, locale);
      final output = formatTaskHongKongTime(
          context, DateTime.parse('2026-10-08T23:00:00Z'));
      expect(output, contains('07:00'));
      expect(
          output,
          contains(MaterialLocalizations.of(context)
              .formatFullDate(DateTime(2026, 10, 9))));
      expect(
          output, contains(locale.languageCode == 'en' ? 'Hong Kong' : '香港'));
      expect(formatTaskHongKongTime(context, null),
          locale.languageCode == 'en' ? 'Not set' : '未設定');
    });

    testWidgets(
        'task due, consent and revoked receipt times all use Hong Kong dates in $locale',
        (tester) async {
      final server = HongKongTimeServer();
      server.shares.add({
        'id': 'share',
        'task_id': 'task',
        'family_link_id': 'link',
        'shared_by': 'elder',
        'caregiver_id': 'carer',
        'caregiver_name': 'Family Carer',
        'caregiver_email': 'carer@example.test',
        'content_hash': server.hash,
        'consented_at': '2026-10-08T09:00:00Z',
        'revoked_at': '2026-10-08T23:00:00Z',
        'revocation_reason': 'owner_revoked',
      });
      await existing.openSharing(tester, server,
          locale: locale, size: const Size(900, 2200));
      final context = tester.element(find.byType(Scaffold).last);
      final due = formatTaskHongKongTime(
          context, DateTime.parse('2026-10-08T23:00:00Z'));
      final consent = formatTaskHongKongTime(
          context, DateTime.parse('2026-10-08T09:00:00Z'));
      expect(find.text(due), findsOneWidget,
          reason: 'due date must use the shared Hong Kong formatter');
      final confirmedLabel = locale.languageCode == 'en' ? 'Confirmed' : '確認時間';
      final stoppedLabel = locale.languageCode == 'en' ? 'Stopped' : '停止時間';
      await tester.scrollUntilVisible(find.text('$stoppedLabel: $due'), 300,
          scrollable: find.byType(Scrollable).first, maxScrolls: 30);
      expect(find.text('$confirmedLabel: $consent'), findsOneWidget);
      expect(find.text('$stoppedLabel: $due'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(server.posts, isEmpty);
    });
  }
}
