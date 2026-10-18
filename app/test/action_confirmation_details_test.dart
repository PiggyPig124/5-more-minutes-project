import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/reminders.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'helpers.dart';

// Dropping structured due_at, normalizing malformed dates, or enabling Confirm
// from description-only details must break these observable confirmation tests.
ActionProposal proposal(Object? due,
        {String title = 'Visit the synthetic library',
        String description = ''}) =>
    ActionProposal.fromJson({
      'id': 'synthetic-action',
      'action_type': 'reminder',
      'status': 'pending',
      'payload': {
        'type': 'reminder',
        'title': title,
        'description': description,
        'due_at': due,
        'recipient_label': 'Synthetic owner'
      }
    });

class SyntheticScheduler extends ReminderScheduler {
  int syncs = 0, permissionRequests = 0;
  @override
  Future<void> syncDueTasks(String userId, List<CareTask> tasks) async =>
      syncs++;
  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    throw StateError('A confirmation must never request OS permissions');
  }
}

AppController controller(FakeApi api, SyntheticScheduler scheduler) =>
    AppController(
        api: api,
        sessionStore: SessionStore(MemoryLocalStore()),
        reminderScheduler: scheduler)
      ..session = const AuthSession(
          accessToken: 'synthetic',
          user: AppUser(
              id: 'synthetic-owner',
              displayName: 'Synthetic owner',
              email: 'owner@example.invalid',
              role: UserRole.elder));

Widget frame(AppController c, ActionProposal action,
        {Locale locale = englishLocale, double textScale = 1}) =>
    ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => c)],
        child: MaterialApp(
            locale: locale,
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!),
            home: Scaffold(
                body:
                    SingleChildScrollView(child: ActionCard(action: action)))));

Finder confirm() => find.widgetWithText(FilledButton, 'Confirm');

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty());
  testWidgets(
      'structured payload shows exact date time zone and behaviour before saving',
      (t) async {
    final api = FakeApi();
    final scheduler = SyntheticScheduler();
    final c = controller(api, scheduler);
    await t.pumpWidget(frame(c, proposal('2099-01-02T00:15:30+08:00')));
    expect(find.textContaining('2099-01-02'), findsOneWidget);
    expect(find.textContaining('00:15:30'), findsOneWidget);
    expect(find.textContaining('UTC+08:00'), findsOneWidget);
    expect(find.textContaining('Save a pending task'), findsOneWidget);
    expect(find.textContaining('Task reminders'), findsOneWidget);
    expect(find.textContaining('09:00'), findsOneWidget);
    expect(find.textContaining('No message'), findsOneWidget);
    expect(find.textContaining('Synthetic owner'), findsOneWidget);
    expect(api.actionConfirmations, 0);
    expect(scheduler.syncs, 0);
    expect(scheduler.permissionRequests, 0);
    await t.ensureVisible(confirm());
    await t.tap(confirm());
    await t.pumpAndSettle();
    expect(c.tasks, hasLength(1));
    expect(api.actionConfirmations, 1);
    expect(scheduler.permissionRequests, 0);
  });

  final invalid = <String, Object?>{
    'missing': null,
    'no time': '2099-01-02',
    'no time zone': '2099-01-02T12:15:00',
    'ambiguous words': 'tomorrow morning',
    'impossible day': '2099-02-30T12:00:00Z',
    'overflow hour': '2099-01-02T24:00:00Z',
    'unknown offset': '2099-01-02T12:00:00-00:00',
    'invalid zone': '2099-01-02T12:00:00+25:00',
    'expired': '2000-01-02T12:00:00Z',
    'wrong type': 12345,
  };
  for (final entry in invalid.entries) {
    testWidgets('${entry.key} asks for complete details and cannot confirm',
        (t) async {
      final api = FakeApi();
      final scheduler = SyntheticScheduler();
      final c = controller(api, scheduler);
      await t.pumpWidget(frame(c,
          proposal(entry.value, description: 'Tomorrow at 10, supposedly.')));
      expect(t.widget<FilledButton>(confirm()).onPressed, isNull);
      expect(find.textContaining('Please provide'), findsOneWidget);
      expect(await c.confirmAction(proposal(entry.value)), isFalse);
      expect(c.tasks, isEmpty);
      expect(api.actionConfirmations, 0);
      expect(scheduler.syncs, 0);
      expect(scheduler.permissionRequests, 0);
      final skip = find.text('Skip for now');
      await t.ensureVisible(skip);
      await t.tap(skip);
      await t.pumpAndSettle();
    });
  }
  testWidgets('blank event cannot become a fallback task silently', (t) async {
    final api = FakeApi();
    final scheduler = SyntheticScheduler();
    final c = controller(api, scheduler);
    await t.pumpWidget(frame(c, proposal('2099-01-02T12:00:00Z', title: '  ')));
    expect(t.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(await c.confirmAction(proposal('2099-01-02T12:00:00Z', title: '  ')),
        isFalse);
    expect(api.actionConfirmations, 0);
  });

  testWidgets('non-text event cannot be coerced into an executable event',
      (t) async {
    final api = FakeApi();
    final c = controller(api, SyntheticScheduler());
    final action = ActionProposal.fromJson({
      'id': 'numeric-event',
      'action_type': 'reminder',
      'payload': {
        'type': 'reminder',
        'title': 123,
        'description': '',
        'due_at': '2099-01-02T12:00:00Z'
      }
    });
    await t.pumpWidget(frame(c, action));
    expect(t.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(await c.confirmAction(action), isFalse);
    expect(api.actionConfirmations, 0);
  });

  testWidgets('contradictory payload type cannot hide reminder details',
      (t) async {
    final api = FakeApi();
    final c = controller(api, SyntheticScheduler());
    final action = ActionProposal.fromJson({
      'id': 'type-conflict',
      'action_type': 'reminder',
      'payload': {
        'type': 'message',
        'title': 'Fictional event',
        'description': '',
        'due_at': null
      }
    });
    await t.pumpWidget(frame(c, action));
    expect(t.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(await c.confirmAction(action), isFalse);
    expect(api.actionConfirmations, 0);
  });

  testWidgets('skip and route back leave without confirming or scheduling',
      (t) async {
    final api = FakeApi();
    final scheduler = SyntheticScheduler();
    final c = controller(api, scheduler);
    final action = proposal('2099-01-02T12:00:00Z');
    c.pendingActions.add(action);
    await t.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        locale: englishLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => Scaffold(
                                appBar: AppBar(),
                                body: SingleChildScrollView(
                                    child: ActionCard(action: action))))),
                    child: const Text('Review fictional reminder')))),
      ),
    ));
    await t.tap(find.text('Review fictional reminder'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Skip for now'));
    await t.tap(find.text('Skip for now'));
    await t.pumpAndSettle();
    expect(c.pendingActions, isEmpty);
    await t.pageBack();
    await t.pumpAndSettle();
    c.pendingActions.add(action);
    await t.tap(find.text('Review fictional reminder'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('Review fictional reminder'), findsOneWidget);
    expect(c.pendingActions, hasLength(1));
    expect(c.tasks, isEmpty);
    expect(api.actionConfirmations, 0);
    expect(scheduler.syncs, 0);
    expect(scheduler.permissionRequests, 0);
  });

  testWidgets(
      'confirmation uses execution payload rather than conflicting outer preview',
      (t) async {
    final api = FakeApi();
    final c = controller(api, SyntheticScheduler());
    final action = ActionProposal.fromJson({
      'id': 'conflict',
      'action_type': 'reminder',
      'title': 'Wrong outer title',
      'due_at': '2099-12-31T23:00:00Z',
      'payload': {
        'type': 'reminder',
        'title': 'Actual saved event',
        'description': '',
        'due_at': '2099-01-02T00:15:00-05:00'
      }
    });
    await t.pumpWidget(frame(c, action));
    expect(find.text('Actual saved event'), findsOneWidget);
    expect(find.textContaining('2099-01-02'), findsOneWidget);
    expect(find.textContaining('00:15:00'), findsOneWidget);
    expect(find.textContaining('UTC-05:00'), findsOneWidget);
    expect(find.textContaining('2099-12-31'), findsNothing);
    expect(find.text('Wrong outer title'), findsNothing);
  });

  testWidgets('expiration after preview is rejected at click without saving',
      (t) async {
    final api = FakeApi();
    final scheduler = SyntheticScheduler();
    final c = controller(api, scheduler);
    final action = proposal(DateTime.now()
        .toUtc()
        .add(const Duration(seconds: 1))
        .toIso8601String());
    await t.pumpWidget(frame(c, action));
    await t.ensureVisible(confirm());
    expect(t.widget<FilledButton>(confirm()).onPressed, isNotNull);
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)));
    await t.tap(confirm());
    await t.pumpAndSettle();
    expect(api.actionConfirmations, 0);
    expect(c.tasks, isEmpty);
    expect(find.textContaining('Please provide'), findsOneWidget);
    expect(scheduler.syncs, 0);
  });

  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets(
        'confirmation remains readable at 320px 200% ${locale.languageCode}',
        (t) async {
      t.view.physicalSize = const Size(320, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c = controller(FakeApi(), SyntheticScheduler());
      await t.pumpWidget(frame(c, proposal('2099-01-02T12:15:00Z'),
          locale: locale, textScale: 2));
      await t.pumpAndSettle();
      expect(
          MediaQuery.textScalerOf(t.element(find.byType(ActionCard))).scale(10),
          20);
      expect(find.textContaining('2099-01-02'), findsOneWidget);
      expect(find.textContaining('UTC+00:00'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
