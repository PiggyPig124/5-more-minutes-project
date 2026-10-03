import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/care_controls_screen.dart';
import 'package:anxin_companion/src/care_models.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

http.Response _json(Object? value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json'},
    );

AppController _controller(AnxinApi api,
        {UserRole role = UserRole.elder, SessionStore? store}) =>
    AppController(
        api: api, sessionStore: store ?? SessionStore(MemoryLocalStore()))
      ..session = AuthSession(
        accessToken: 'token',
        user: AppUser(
            id: role.name,
            displayName: 'Test user',
            email: 'test@example.com',
            role: role),
      );

Future<void> _pump(WidgetTester tester, AppController controller,
    {int tab = 0, Locale locale = englishLocale}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: appLocalizationsDelegates,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
    home: CareControlsScreen(controller: controller, initialTab: tab),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _prepareSupport(WidgetTester tester,
    {String contact = 'Daughter · Alex',
    String message = 'Please call me this evening.'}) async {
  await _tapVisible(
      tester, find.byKey(const Key('preview-designated-support')));
  final review = tester
      .widget<FilledButton>(find.byKey(const Key('review-designated-support')));
  expect(review.onPressed, isNull);
  await tester.tap(find.byKey(const Key('support-contact-picker')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(contact).last);
  await tester.pumpAndSettle();
  await tester.enterText(
      find.byKey(const Key('support-message-editor')), message);
  await _tapVisible(tester, find.byKey(const Key('review-designated-support')));
  expect(find.byKey(const Key('support-recipient-preview')), findsOneWidget);
  expect(find.text(message), findsOneWidget);
}

class _CareServer {
  final requests = <http.Request>[];
  bool failSupport = false;
  Map<String, Object?> schedule = const CheckInSchedule().toJson();
  String notificationStatus = 'sent';

  late final api = RestApiClient(client: MockClient((request) async {
    requests.add(request);
    switch (request.url.path) {
      case '/check-ins/schedule':
        if (request.method == 'PUT') {
          schedule = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        }
        return _json({'id': 'schedule-1', ...schedule});
      case '/check-ins/trigger':
        return _json({
          'triggered': false,
          'assistant_text': '',
          'message_id': null,
          'conversation_id': null
        });
      case '/check-ins/skip':
        schedule['skip_date'] = '2026-10-02';
        return _json(schedule);
      case '/notifications':
        return _json([
          {
            'id': 'notice-1',
            'kind': 'task_due',
            'body': 'Your appointment is due',
            'status': notificationStatus,
            'created_at': '2026-10-02T08:00:00Z'
          }
        ]);
      case '/notifications/notice-1':
        notificationStatus =
            (jsonDecode(request.body) as Map)['status'] as String;
        return _json({
          'id': 'notice-1',
          'kind': 'task_due',
          'body': 'Your appointment is due',
          'status': notificationStatus,
          'created_at': '2026-10-02T08:00:00Z'
        });
      case '/safety/emergency-contacts':
        return _json([
          {
            'id': 'contact-1',
            'label': 'Daughter',
            'caregiver_name': 'Alex',
            'is_enabled': true
          },
          {
            'id': 'contact-2',
            'label': 'Son',
            'caregiver_name': 'Sam',
            'is_enabled': true
          },
          {
            'id': 'contact-disabled',
            'label': 'Disabled',
            'caregiver_name': 'Taylor',
            'is_enabled': false
          },
        ]);
      case '/family-links':
        return _json([
          {
            'id': 'link-1',
            'status': 'accepted',
            'email': 'alex@example.com',
            'caregiver_name': 'Alex',
            'scopes': ['family_messages']
          }
        ]);
      case '/safety/events':
        return _json([
          {
            'id': 'event-1',
            'trigger_message_id': 'message-reference-1',
            'trigger_text': 'PRIVATE RAW TEXT',
            'created_at': '2026-10-02T08:00:00Z',
            'resolved_at': null,
            'support_request_sent': false
          }
        ]);
      case '/safety/support-request':
        return _json(
            failSupport ? {'detail': 'Temporary failure'} : {'delivered': true},
            failSupport ? 503 : 201);
      default:
        return _json({'detail': 'Unexpected route'}, 404);
    }
  }));

  List<Map<String, dynamic>> get supportBodies => requests
      .where((request) => request.url.path == '/safety/support-request')
      .map((request) => jsonDecode(request.body) as Map<String, dynamic>)
      .toList();
}

void main() {
  testWidgets('unchanged FakeApi gets graceful fallback in both languages',
      (tester) async {
    final controller = _controller(FakeApi());
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    expect(find.text('Inbox and care settings'), findsOneWidget);
    expect(find.text('Feature unavailable'), findsOneWidget);
    expect(
        find.textContaining('There are no push notifications'), findsOneWidget);
    expect(find.text('Save cloud settings'), findsNothing);
    expect(tester.takeException(), isNull);
    await _pump(tester, controller, locale: traditionalChineseLocale);
    expect(find.text('收件匣及關懷設定'), findsOneWidget);
    expect(find.text('功能尚未提供'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shell inbox button opens care without changing FakeApi',
      (tester) async {
    final controller = _controller(FakeApi());
    await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
          locale: englishLocale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: const ShellScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Inbox and care settings'));
    await tester.pumpAndSettle();
    expect(find.byType(CareControlsScreen), findsOneWidget);
    expect(find.text('Feature unavailable'), findsOneWidget);
  });

  testWidgets('local chat safety card can navigate to designated support',
      (tester) async {
    final controller = _controller(FakeApi());
    await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
          locale: englishLocale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: const Scaffold(
              body:
                  SingleChildScrollView(child: SafetySupportCard(links: [])))),
    ));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const Key('open-designated-support')));
    expect(find.byType(CareControlsScreen), findsOneWidget);
    expect(find.text('Feature unavailable'), findsOneWidget);
  });

  testWidgets(
      'caregiver saves preferences with greetings disabled and no safety calls',
      (tester) async {
    final server = _CareServer()..schedule['enabled'] = true;
    final controller = _controller(server.api, role: UserRole.caregiver);
    addTearDown(controller.dispose);
    await _pump(tester, controller, tab: 1);
    expect(find.text('Enable check-in greetings'), findsNothing);
    expect(find.text('Support'), findsNothing);
    await _tapVisible(tester, find.text('Task reminders'));
    await _tapVisible(tester, find.text('Family replies'));
    await _tapVisible(tester, find.byKey(const Key('save-care-schedule')));
    expect(server.schedule['enabled'], isFalse);
    expect(server.schedule['task_reminders'], isTrue);
    expect(server.schedule['family_replies'], isTrue);
    expect(server.schedule['quiet_start'], '21:00');
    expect(server.schedule['quiet_end'], '09:00');
    expect(
        server.requests
            .any((request) => request.url.path.startsWith('/safety/')),
        isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'elder saves weekly schedule and due check never claims forced send',
      (tester) async {
    final server = _CareServer();
    final controller = _controller(server.api);
    addTearDown(controller.dispose);
    await _pump(tester, controller, tab: 1);
    await _tapVisible(tester, find.text('Enable check-in greetings'));
    await _tapVisible(
        tester, find.byType(DropdownButtonFormField<CheckInFrequency>));
    await tester.tap(find.text('Weekly').last);
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.text('Sunday').last);
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const Key('save-care-schedule')));
    expect(server.schedule['frequency'], 'weekly');
    expect(server.schedule['weekday'], 7);
    expect(server.schedule['enabled'], isTrue);
    await _tapVisible(tester, find.text('Check for a due greeting'));
    await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(find.text('No check-in is due. Nothing was forced or sent.'),
        findsOneWidget);
    await _tapVisible(tester, find.text('Skip today’s check-in'));
    expect(server.schedule['skip_date'], '2026-10-02');
    expect(tester.takeException(), isNull);
  });

  testWidgets('inbox acknowledgement and handling wait for API response',
      (tester) async {
    final server = _CareServer();
    final controller = _controller(server.api);
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    expect(find.text('Your appointment is due'), findsOneWidget);
    await _tapVisible(tester, find.text('Acknowledge'));
    expect(server.notificationStatus, 'acknowledged');
    expect(find.text('Acknowledge'), findsNothing);
    await _tapVisible(tester, find.text('Mark handled'));
    expect(server.notificationStatus, 'handled');
    expect(find.text('Mark handled'), findsNothing);
  });

  testWidgets(
      'designated support needs explicit edited preview; cancel never sends',
      (tester) async {
    final server = _CareServer();
    final controller = _controller(server.api);
    addTearDown(controller.dispose);
    await _pump(tester, controller, tab: 2);
    expect(server.supportBodies, isEmpty);
    expect(find.textContaining('PRIVATE RAW TEXT'), findsNothing);
    await _prepareSupport(tester);
    expect(server.supportBodies, isEmpty);
    expect(find.text('Only recipient: Daughter · Alex'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('support-message-editor')), 'A revised message');
    await _tapVisible(
        tester, find.byKey(const Key('review-designated-support')));
    expect(find.text('A revised message'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.supportBodies, isEmpty);
  });

  testWidgets(
      'support retry ID survives recreation and is scoped to contact and content',
      (tester) async {
    final server = _CareServer()..failSupport = true;
    final store = SessionStore(MemoryLocalStore());
    final firstController = _controller(server.api, store: store);
    addTearDown(firstController.dispose);
    await _pump(tester, firstController, tab: 2);
    await _prepareSupport(tester);
    await _tapVisible(
        tester, find.byKey(const Key('confirm-designated-support')));
    expect(server.supportBodies, hasLength(1));
    final first = server.supportBodies.single;
    expect(first['emergency_contact_id'], 'contact-1');
    expect(first['message'], 'Please call me this evening.');
    expect(first['safety_event_id'], isNull);
    expect(
        await store.readFamilyMessageClientId(
            recipientId: 'safety:contact-1',
            content: first['message'] as String,
            userId: 'elder'),
        first['idempotency_key']);
    expect(find.textContaining('Delivered IN APP'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    server.failSupport = false;
    final secondController = _controller(server.api, store: store);
    addTearDown(secondController.dispose);
    await _pump(tester, secondController, tab: 2);
    await _prepareSupport(tester);
    await _tapVisible(
        tester, find.byKey(const Key('confirm-designated-support')));
    expect(
        server.supportBodies[1]['idempotency_key'], first['idempotency_key']);
    expect(find.textContaining('Delivered IN APP to the chosen contact'),
        findsOneWidget);
    await _prepareSupport(tester, contact: 'Son · Sam');
    await _tapVisible(
        tester, find.byKey(const Key('confirm-designated-support')));
    expect(server.supportBodies.last['emergency_contact_id'], 'contact-2');
    expect(server.supportBodies.last['idempotency_key'],
        isNot(first['idempotency_key']));
    await _prepareSupport(tester, message: 'Different content');
    await _tapVisible(
        tester, find.byKey(const Key('confirm-designated-support')));
    expect(server.supportBodies.last['idempotency_key'],
        isNot(first['idempotency_key']));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unsupported server route offers retry without false empty success',
      (tester) async {
    final controller = _controller(RestApiClient(
        client: MockClient((_) async => _json({'detail': 'Not found'}, 404))));
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    expect(find.textContaining('does not support this feature yet'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No notifications yet.'), findsNothing);
  });
}
