import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/care_models.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/reminders.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android 15 native plugins and merged app acceptance',
      (tester) async {
    final api = RestApiClient();
    final email = 'mumu-${DateTime.now().microsecondsSinceEpoch}@example.test';
    await api.register(
        email: email,
        password: 'mumu-test-password',
        displayName: 'MuMu Test',
        role: UserRole.elder);
    final controller = AppController(
        api: api,
        sessionStore: SessionStore(SecureLocalStore()),
        reminderScheduler: ReminderScheduler());
    await controller.logout();
    await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: const AnxinApp(),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), email);
    await tester.enterText(
        find.byType(TextFormField).at(1), 'mumu-test-password');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();
    expect(find.text('首頁'), findsOneWidget);
    expect(controller.errorMessage, isNull);
    debugPrint('MUMU_PASS login and five-area shell');
    // Flutter reinstalls the test APK. Give the host harness time to grant
    // notification/microphone permissions to this isolated test app.
    debugPrint('MUMU_PERMISSION_SETUP');
    await Future<void>.delayed(const Duration(seconds: 30));

    await tester.tap(find.byTooltip('收件匣及關懷設定'));
    await tester.pumpAndSettle();
    expect(find.text('目前沒有通知。'), findsOneWidget);
    await tester.tap(find.text('排程'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-care-schedule')), findsOneWidget);
    await api.saveCheckInSchedule(
        const CheckInSchedule(taskReminders: true, familyReplies: true));
    expect((await api.getCheckInSchedule())!.taskReminders, isTrue);
    debugPrint('MUMU_PASS cloud inbox and persisted settings');
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('開始聊天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新對話'));
    await tester.pumpAndSettle();
    final chatEditor = find.byType(TextField).first;
    await tester.tap(find.byKey(const Key('cantonese-voice-input')));
    await tester.pumpAndSettle();
    expect(find.text('繼續'), findsOneWidget);
    await tester.tap(find.text('繼續'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-notice')), findsOneWidget);
    expect(
        find.text(
            'Cantonese voice input is not available on this device or browser.'),
        findsOneWidget);
    debugPrint(
        'MUMU_PASS missing native recognizer shows notice and keeps typing available');
    await tester.enterText(
        chatEditor, 'Please remind me to drink water tomorrow');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(controller.errorMessage, isNull);
    expect(controller.pendingActions, isNotEmpty);
    final action = controller.pendingActions.first;
    expect(await controller.confirmAction(action), isTrue);
    expect(controller.tasks, isNotEmpty);
    debugPrint('MUMU_PASS real chat and confirmed task');

    await tester.enterText(chatEditor, 'I want to die');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(SafetySupportCard), findsOneWidget);
    expect(await api.listSafetyEvents(), hasLength(1));
    expect((await api.listSafetyEvents()).single.supportRequestSent, isFalse);
    debugPrint(
        'MUMU_PASS urgent intervention without automatic family delivery');
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('社區'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ShellScreen));
    Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ActivityCatalogScreen()));
    await tester.pumpAndSettle();
    expect(controller.catalogActivities, isNotEmpty);
    final activity = controller.catalogActivities.first;
    expect(await controller.expressInterest(activity), isTrue);
    expect(controller.catalogInterests.any((item) => item.id == activity.id),
        isTrue);
    expect(await controller.withdrawInterest(activity), isTrue);
    debugPrint('MUMU_PASS catalog browse and interest lifecycle');
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ScamSafetyScreen()));
    await tester.pumpAndSettle();
    expect(controller.scamResources, isNotEmpty);
    expect(controller.verifyActions, hasLength(3));
    debugPrint('MUMU_PASS scam resources and verification steps');
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    final scheduler = controller.reminderScheduler!;
    expect(await scheduler.supported, isTrue);
    expect(await scheduler.requestPermission(), isTrue);
    await scheduler.setDailyCheckIn(
        userId: controller.user!.id,
        enabled: true,
        time: const TimeOfDay(hour: 16, minute: 0),
        weekly: false,
        weekday: 1);
    final notifications = FlutterLocalNotificationsPlugin();
    expect(
        (await notifications.pendingNotificationRequests())
            .any((item) => item.id == 900000),
        isTrue);
    await scheduler.setTaskReminders(
        userId: controller.user!.id,
        enabled: true,
        // Demo chat omits due dates. Use a future-dated fixture with the
        // confirmed real task ID to exercise the native scheduler.
        tasks: [
          CareTask(
              id: controller.tasks.first.id,
              title: controller.tasks.first.title,
              description: '',
              status: controller.tasks.first.status,
              dueAt: DateTime.now().add(const Duration(days: 1)))
        ]);
    expect((await notifications.pendingNotificationRequests()).length,
        greaterThanOrEqualTo(2));
    debugPrint('MUMU_PASS Android permissions and scheduled alarms');
    await notifications.show(
        990001,
        'MuMu acceptance',
        'Anxin Android 15 notification test',
        const NotificationDetails(
            android: AndroidNotificationDetails(
                'anxin_reminders', 'Anxin reminders')));
    debugPrint('MUMU_NOTIFICATION_POSTED');
    await Future<void>.delayed(const Duration(seconds: 3));
    final active = await notifications.getActiveNotifications();
    expect(active.any((item) => item.id == 990001), isTrue);
    debugPrint('MUMU_PASS actual Android notification posted');
    await notifications.cancel(990001);
    await scheduler.setDailyCheckIn(
        userId: controller.user!.id,
        enabled: false,
        time: const TimeOfDay(hour: 16, minute: 0),
        weekly: false,
        weekday: 1);
    await scheduler.setTaskReminders(
        userId: controller.user!.id, enabled: false, tasks: []);
    expect(await notifications.pendingNotificationRequests(), isEmpty);
    debugPrint('MUMU_PASS reminder disable cancels native alarms');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
