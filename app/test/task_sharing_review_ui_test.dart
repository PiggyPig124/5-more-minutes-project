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

import 'task_sharing_screen_test.dart' as existing;

class IdentitySharingServer extends existing.SharingServer {
  String aliceEmail = 'alice@example.test';
  String bobEmail = 'bob@example.test';

  @override
  Future<http.Response> handle(http.Request request) async {
    if (request.method != 'POST') return super.handle(request);
    requests.add(request);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    posts.add(body);
    final bob = body['family_link_id'] == 'link-bob';
    final receipt = <String, dynamic>{
      'id': 'share',
      'task_id': 'task',
      'family_link_id': body['family_link_id'],
      'shared_by': 'elder',
      'caregiver_id': bob ? 'bob' : 'alice',
      'caregiver_name': 'Alex Chan',
      'caregiver_email': bob ? bobEmail : aliceEmail,
      'content_hash': body['expected_content_hash'],
      'consented_at': '2026-10-03T10:00:00Z',
      'revoked_at': null,
      'revocation_reason': null,
    };
    shares.add(receipt);
    return super.json(receipt, 201);
  }
}

FamilyInvitation connectedLink(String id, String email) =>
    FamilyInvitation.fromJson({
      'id': 'link-$id', 'status': 'active', 'scopes': ['care_tasks'],
      'authorization_epoch': 1,
      // Invitation metadata is deliberately different from the connected account.
      'email': 'invitation-metadata@example.test',
      'elder': {
        'id': 'elder',
        'email': 'elder@example.test',
        'display_name': 'Senior'
      },
      'caregiver': {'id': id, 'email': email, 'display_name': 'Alex Chan'},
    });

Future<AppController> openIdentitySharing(
    WidgetTester tester, IdentitySharingServer server,
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
    ..links = [
      connectedLink('alice', server.aliceEmail),
      connectedLink('bob', server.bobEmail)
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
      home: TaskSharingScreen(controller: controller, taskId: 'task')));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> chooseBob(
    WidgetTester tester, IdentitySharingServer server) async {
  await tester.scrollUntilVisible(
      find.byType(DropdownButtonFormField<String>), 300,
      scrollable: find.byType(Scrollable).first, maxScrolls: 50);
  await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  expect(find.textContaining(server.aliceEmail), findsWidgets);
  expect(find.textContaining(server.bobEmail), findsWidgets);
  expect(find.textContaining('invitation-metadata@example.test'), findsNothing);
  await tester.tap(find.textContaining(server.bobEmail).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'same-name family accounts are distinguished through preview, receipt and stop',
      (tester) async {
    final server = IdentitySharingServer();
    final controller = await openIdentitySharing(tester, server);
    expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        isNull);
    expect(server.posts, isEmpty);
    await chooseBob(tester, server);
    await tester.ensureVisible(find.byType(FilledButton));
    // The selected dropdown and an explicit review identity must both identify Bob.
    expect(find.textContaining(server.bobEmail).evaluate().length,
        greaterThanOrEqualTo(2));
    expect(find.text(server.description), findsOneWidget);
    expect(server.posts, isEmpty);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(server.posts.single['family_link_id'], 'link-bob');
    expect(controller.taskSharesByTask['task']!.single.caregiverId, 'bob');
    final success = find.byWidgetPredicate((widget) =>
        widget is Text &&
        (widget.data?.contains('Shared with') ?? false) &&
        (widget.data?.contains(server.bobEmail) ?? false));
    expect(success, findsOneWidget);
    await tester.scrollUntilVisible(find.text('Stop sharing'), 250,
        scrollable: find.byType(Scrollable).first, maxScrolls: 30);
    final history = find
        .ancestor(of: find.text('Stop sharing'), matching: find.byType(Card))
        .first;
    expect(
        find.descendant(
            of: history, matching: find.textContaining(server.bobEmail)),
        findsOneWidget);
    expect(
        find.descendant(
            of: history, matching: find.textContaining(server.aliceEmail)),
        findsNothing);
    await tester.tap(find.text('Stop sharing'));
    await tester.pumpAndSettle();
    expect(
        server.requests
            .where((request) => request.method == 'DELETE')
            .single
            .url
            .path,
        '/tasks/task/shares/share');
    expect(controller.taskSharesByTask['task']!.single.isActive, false);
    expect(find.textContaining(server.bobEmail), findsWidgets);
    expect(find.text('Sharing stopped'), findsOneWidget);
  });

  for (final locale in [englishLocale, const Locale('zh', 'HK')]) {
    testWidgets(
        'long connected recipient email wraps at 320px and 2x text in $locale',
        (tester) async {
      final server = IdentitySharingServer()
        ..bobEmail =
            'bob.with.a.very.long.connected.account.identity@family-example.test';
      await openIdentitySharing(tester, server,
          locale: locale, size: const Size(320, 700), scale: 2);
      await chooseBob(tester, server);
      await tester.scrollUntilVisible(find.byType(FilledButton), 250,
          scrollable: find.byType(Scrollable).first, maxScrolls: 30);
      expect(find.textContaining(server.bobEmail), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(server.posts, isEmpty);
    });
  }
}
