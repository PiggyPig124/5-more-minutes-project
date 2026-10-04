import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const headers = {'content-type': 'application/json; charset=utf-8'};
const session = AuthSession(
    accessToken: 'token',
    user: AppUser(
        id: 'caregiver',
        displayName: 'Carer',
        email: 'c@example.com',
        role: UserRole.caregiver));
Map<String, dynamic> shared(String body) => {
      'id': 'shared',
      'owner_id': 'elder',
      'owner_display_name': '陳婆婆',
      'access_mode': 'shared_readonly',
      'share_id': 'share',
      'task_type': 'appointment',
      'title': 'Meeting at the centre',
      'description': body,
      'status': 'pending',
      'due_at': '2026-10-08T09:00:00Z'
    };
Future<void> renderTile(
    WidgetTester tester, AppController controller, Locale locale,
    {double scale = 1}) async {
  await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
          locale: locale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: TaskTile(
                      task: controller.tasks.single, interactive: true))))));
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    final english = locale == englishLocale;
    testWidgets(
        'full shared task is readable at 320px 2x in ${locale.languageCode}',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final paragraphs = List.generate(
              18,
              (i) =>
                  'Paragraph $i: 完整任務內容。Please bring the full set of documents to the meeting.')
          .join('\n\n');
      final body = '$paragraphs\nEND OF AUTHORIZED TASK';
      final controller = AppController(
          api: RestApiClient(
              client: MockClient((r) async => http.Response(
                  jsonEncode(shared(body)), 200,
                  headers: headers))),
          sessionStore: SessionStore(MemoryLocalStore()))
        ..session = session
        ..tasks = [CareTask.fromJson(shared('Cached summary'))];
      await renderTile(tester, controller, locale, scale: 2);
      final open = find.text(english ? 'View full task' : '查看完整任務');
      expect(open, findsOneWidget);
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.text(english ? 'Full task' : '完整任務'), findsOneWidget);
      expect(find.textContaining('陳婆婆'), findsOneWidget);
      expect(find.text('Complete'), findsNothing);
      expect(find.text('完成'), findsNothing);
      final full =
          find.byWidgetPredicate((w) => w is SelectableText && w.data == body);
      expect(full, findsOneWidget);
      expect(tester.widget<SelectableText>(full).maxLines, isNull);
      final hk = find
          .textContaining(english ? 'Hong Kong time (UTC+8)' : '香港時間 (UTC+8)');
      final detailScroll = find
          .descendant(
              of: find.byType(ListView), matching: find.byType(Scrollable))
          .first;
      expect(tester.takeException(), isNull);
      final type = find.text(english ? 'Appointment' : '預約');
      await tester.scrollUntilVisible(type, 500,
          scrollable: detailScroll,
          maxScrolls: 80,
          duration: const Duration(milliseconds: 10));
      expect(type, findsOneWidget);
      await tester.scrollUntilVisible(hk, 300,
          scrollable: detailScroll,
          maxScrolls: 80,
          duration: const Duration(milliseconds: 10));
      expect(hk, findsOneWidget);
      expect(find.textContaining('17:00'), findsOneWidget);
      final status = find.text(english ? 'Current status' : '目前狀態');
      await tester.scrollUntilVisible(status, 300,
          scrollable: detailScroll,
          maxScrolls: 80,
          duration: const Duration(milliseconds: 10));
      expect(status, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -1800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
  testWidgets(
      'detail foreground recheck removes old shared body after permission denial',
      (tester) async {
    var calls = 0;
    const body = 'AUTHORIZED FULL BODY';
    final controller = AppController(
        api: RestApiClient(client: MockClient((r) async {
          calls++;
          return calls == 1
              ? http.Response(jsonEncode(shared(body)), 200, headers: headers)
              : http.Response('{"detail":"Access removed"}', 403,
                  headers: headers);
        })),
        sessionStore: SessionStore(MemoryLocalStore()))
      ..session = session
      ..tasks = [CareTask.fromJson(shared('Cached summary'))];
    await renderTile(tester, controller, englishLocale);
    final open = find.text('View full task');
    expect(open, findsOneWidget);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == body),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == body),
        findsNothing);
    expect(controller.tasks.any((t) => t.id == 'shared'), false);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
