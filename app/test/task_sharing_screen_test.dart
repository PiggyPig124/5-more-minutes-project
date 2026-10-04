import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:anxin_companion/src/task_sharing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class SharingServer {
  final requests = <http.Request>[];
  final posts = <Map<String, dynamic>>[];
  final shares = <Map<String, dynamic>>[];
  String description = 'The complete private appointment details.';
  String hash = 'a' * 64;
  int? nextPostFailure;

  Map<String, Object?> get task => {
        'id': 'task',
        'owner_id': 'elder',
        'access_mode': 'owner',
        'title': 'Fresh appointment',
        'description': description,
        'task_type': 'appointment',
        'due_at': '2026-10-08T09:00:00Z',
        'status': 'pending',
        'content_hash': hash,
      };

  http.Response json(Object value, [int status = 200]) => http.Response(
        jsonEncode(value),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.method == 'GET' && request.url.path == '/tasks/task') {
      return json(task);
    }
    if (request.method == 'GET' && request.url.path == '/tasks/task/shares') {
      return json(shares);
    }
    if (request.method == 'POST' && request.url.path == '/tasks/task/shares') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      posts.add(body);
      if (nextPostFailure != null) {
        final status = nextPostFailure!;
        nextPostFailure = null;
        return json({'detail': status == 409 ? 'Preview changed' : 'Try again'},
            status);
      }
      final receipt = <String, dynamic>{
        'id': 'share',
        'task_id': 'task',
        'family_link_id': body['family_link_id'],
        'shared_by': 'elder',
        'caregiver_id': 'carer',
        'caregiver_name': 'Family Carer',
        'caregiver_email': 'carer@example.test',
        'content_hash': body['expected_content_hash'],
        'consented_at': '2026-10-03T10:00:00Z',
        'revoked_at': null,
        'revocation_reason': null,
      };
      shares.add(receipt);
      return json(receipt, 201);
    }
    if (request.method == 'DELETE' &&
        request.url.path == '/tasks/task/shares/share') {
      shares.single['revoked_at'] = '2026-10-03T11:00:00Z';
      shares.single['revocation_reason'] = 'owner_revoked';
      return json(shares.single);
    }
    throw StateError('Unexpected ${request.method} ${request.url.path}');
  }
}

Future<AppController> openSharing(WidgetTester tester, SharingServer server,
    {Locale locale = englishLocale,
    Size size = const Size(900, 1800),
    double scale = 1}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = AppController(
      api: RestApiClient(client: MockClient(server.handle)),
      sessionStore: SessionStore(MemoryLocalStore()))
    ..session = const AuthSession(
        accessToken: 'synthetic-token',
        user: AppUser(
            id: 'elder',
            displayName: 'Senior',
            email: 'elder@example.test',
            role: UserRole.elder))
    ..tasks = [CareTask.fromJson(server.task)]
    ..links = const [
      FamilyInvitation(
          id: 'link',
          email: 'carer@example.test',
          status: InvitationStatus.accepted,
          elderId: 'elder',
          caregiverId: 'carer',
          caregiverName: 'Family Carer',
          caregiverEmail: 'carer@example.test',
          scopes: ['care_tasks'])
    ];
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: appLocalizationsDelegates,
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Builder(
        builder: (context) => Scaffold(
                body: TextButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => TaskSharingScreen(
                          controller: controller, taskId: 'task'))),
              child: const Text('Open sharing'),
            ))),
  ));
  await tester.tap(find.text('Open sharing'));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> selectRecipient(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Family Carer\ncarer@example.test').last);
  await tester.pumpAndSettle();
}

Future<void> confirm(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(FilledButton));
  await tester.tap(find.byType(FilledButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fresh preview starts with no recipient and cancel never posts',
      (tester) async {
    final server = SharingServer();
    await openSharing(tester, server);
    expect(server.requests.map((r) => '${r.method} ${r.url.path}'),
        ['GET /tasks/task', 'GET /tasks/task/shares']);
    expect(find.text(server.description), findsOneWidget);
    expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.ensureVisible(find.text('Cancel / Back'));
    await tester.tap(find.text('Cancel / Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open sharing'), findsOneWidget);
    expect(server.posts, isEmpty);
  });

  testWidgets(
      'choosing and confirming shows receipt then verified stop removes future access',
      (tester) async {
    final server = SharingServer();
    await openSharing(tester, server);
    await selectRecipient(tester);
    expect(server.posts, isEmpty);
    await confirm(tester);
    expect(server.posts.single['family_link_id'], 'link');
    expect(server.posts.single['expected_content_hash'], server.hash);
    expect(find.text('Shared with Family Carer\ncarer@example.test.'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Stop sharing'));
    await tester.tap(find.text('Stop sharing'));
    await tester.pumpAndSettle();
    expect(server.requests.where((r) => r.method == 'DELETE').single.url.path,
        '/tasks/task/shares/share');
    expect(find.text('Sharing stopped'), findsOneWidget);
    expect(
        find.text(
            'Future access stopped for Family Carer\ncarer@example.test.'),
        findsOneWidget);
    expect(find.text('Stop sharing'), findsNothing);
  });

  testWidgets(
      'content conflict requires reload and fresh recipient confirmation',
      (tester) async {
    final server = SharingServer()..nextPostFailure = 409;
    await openSharing(tester, server);
    await selectRecipient(tester);
    await confirm(tester);
    expect(server.posts.length, 1);
    expect(find.byType(FilledButton), findsNothing);
    expect(
        find.text(
            'Reload the current content, then choose a recipient and confirm.'),
        findsOneWidget);
    server.description = 'Changed private appointment details to review again.';
    server.hash = 'b' * 64;
    await tester.ensureVisible(find.text('Reload content and sharing history'));
    await tester.tap(find.text('Reload content and sharing history'));
    await tester.pumpAndSettle();
    expect(find.text(server.description), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(server.posts.length, 1);
    await selectRecipient(tester);
    await confirm(tester);
    expect(server.posts.length, 2);
    expect(server.posts.last['expected_content_hash'], 'b' * 64);
    expect(server.posts.last['idempotency_key'],
        isNot(server.posts.first['idempotency_key']));
  });

  testWidgets(
      'retry after transient failure preserves the reviewed consent key',
      (tester) async {
    final server = SharingServer()..nextPostFailure = 503;
    await openSharing(tester, server);
    await selectRecipient(tester);
    await confirm(tester);
    expect(server.posts.length, 1);
    expect(find.text('Shared with Family Carer\ncarer@example.test.'),
        findsNothing);
    await confirm(tester);
    expect(server.posts.length, 2);
    expect(server.posts.last, server.posts.first);
    expect(find.text('Shared with Family Carer\ncarer@example.test.'),
        findsOneWidget);
  });

  for (final locale in [englishLocale, const Locale('zh', 'HK')]) {
    testWidgets(
        'full long description remains accessible at 320px and 2x text in $locale',
        (tester) async {
      final server = SharingServer()
        ..description = List.filled(25,
                'Long appointment detail with medication instructions. 完整預約說明及服藥指示。')
            .join('\n');
      await openSharing(tester, server,
          locale: locale, size: const Size(320, 700), scale: 2);
      final description = find.byWidgetPredicate((widget) =>
          widget is SelectableText && widget.data == server.description);
      await tester.scrollUntilVisible(description, 250,
          scrollable: find.byType(Scrollable).first, maxScrolls: 60);
      await tester.pumpAndSettle();
      expect(description, findsOneWidget);
      expect(tester.widget<SelectableText>(description).maxLines, isNull);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.byType(FilledButton), 500,
          scrollable: find.byType(Scrollable).first, maxScrolls: 60);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(tester.takeException(), isNull);
      expect(server.posts, isEmpty);
    });
  }
}
