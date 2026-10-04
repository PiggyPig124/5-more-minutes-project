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

const caregiver = AuthSession(accessToken: 'token', user: AppUser(
  id: 'caregiver', displayName: 'Carer', email: 'c@example.com', role: UserRole.caregiver));
CareTask task(Map<String, dynamic> metadata) => CareTask.fromJson({
  'id': 'task', 'title': 'Visit the centre', 'description': 'Bring an umbrella',
  'status': 'pending', ...metadata,
});

void main() {
  test('task without share metadata defaults to private', () {
    expect(task({}).isShared, isFalse);
    expect(const CareTask(id: 'new', title: 'Private', description: '', status: TaskStatus.pending).isShared, isFalse);
  });
  test('owner task preserves server preview fingerprint and type', () {
    final dynamic owned = task({'owner_id': 'elder', 'task_type': 'appointment',
      'content_hash': 'a' * 64, 'access_mode': 'owner', 'due_at': '2026-10-08T09:00:00Z'});
    expect(owned.ownerId, 'elder');
    expect(owned.taskType, 'appointment');
    expect(owned.contentHash, 'a' * 64);
    expect(owned.accessMode, 'owner');
    expect(owned.shareId, isNull);
    expect(owned.isReadOnly, isFalse);
    expect(owned.dueAt, DateTime.parse('2026-10-08T09:00:00Z').toLocal());
    final dynamic olderService = task({'owner_id': 'elder'});
    expect(olderService.contentHash, isNull, reason: 'Never fabricate a preview hash for an old server');
  });
  test('shared readonly response is explicitly shared and has no shareable fingerprint', () {
    final dynamic shared = task({'owner_id': 'elder', 'task_type': 'reminder',
      'access_mode': 'shared_readonly', 'share_id': 'share'});
    expect(shared.isShared, isTrue);
    expect(shared.isReadOnly, isTrue);
    expect(shared.ownerId, 'elder');
    expect(shared.shareId, 'share');
    expect(shared.contentHash, isNull);
  });
  test('controller refuses shared readonly status update before issuing PATCH', () async {
    final requests = <http.Request>[];
    final api = RestApiClient(client: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode({'id': 'task', 'title': 'Visit the centre',
        'description': 'Bring an umbrella', 'owner_id': 'elder', 'status': 'completed'}), 200);
    }));
    final controller = AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
      ..session = caregiver;
    addTearDown(controller.dispose);
    final shared = task({'owner_id': 'elder', 'access_mode': 'shared_readonly', 'share_id': 'share'});
    controller.tasks = [shared];
    final updated = await controller.updateTaskStatus(shared, TaskStatus.completed);
    expect(updated, isFalse);
    expect(requests, isEmpty);
    expect(controller.tasks.single.status, TaskStatus.pending);
  });
  test('caregiver may complete their own task even when an owner view says shared', () async {
    final requests = <http.Request>[];
    final api = RestApiClient(client: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode({'id': 'task', 'title': 'Visit the centre',
        'description': 'Bring an umbrella', 'owner_id': 'caregiver', 'status': 'completed'}), 200);
    }));
    final controller = AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
      ..session = caregiver;
    addTearDown(controller.dispose);
    final owned = task({'owner_id': 'caregiver', 'is_shared': true, 'access_mode': 'owner'});
    controller.tasks = [owned];
    expect(await controller.updateTaskStatus(owned, TaskStatus.completed), isTrue);
    expect(requests.single.method, 'PATCH');
    expect(controller.tasks.single.status, TaskStatus.completed);
  });
  test('legacy shared flag is read-only unless explicit owner mode is present', () {
    expect(task({'is_shared': true}).isReadOnly, isTrue);
    expect(task({'is_shared': true, 'access_mode': 'owner'}).isReadOnly, isFalse);
  });
  test('caregiver with unknown task owner cannot complete legacy task', () async {
    final requests = <http.Request>[];
    final controller = AppController(api: RestApiClient(client: MockClient((request) async {
      requests.add(request); return http.Response('{}', 200);
    })), sessionStore: SessionStore(MemoryLocalStore())) ..session = caregiver;
    addTearDown(controller.dispose);
    final unknown = task({});
    expect(controller.canUpdateTask(unknown), isFalse);
    expect(await controller.updateTaskStatus(unknown, TaskStatus.completed), isFalse);
    expect(requests, isEmpty);
  });
  for (final shared in [true, false]) {
    testWidgets(shared ? 'shared readonly task has no Complete control' : 'caregiver owned task keeps Complete control', (tester) async {
      final controller = AppController(api: RestApiClient(client: MockClient((request) async {
        throw StateError('Rendering a task must not send a request');
      })), sessionStore: SessionStore(MemoryLocalStore())) ..session = caregiver;
      final record = task(shared ? {'owner_id': 'elder', 'access_mode': 'shared_readonly', 'share_id': 'share'}
        : {'owner_id': 'caregiver'});
      await tester.pumpWidget(ProviderScope(overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(locale: englishLocale, supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(body: TaskTile(task: record, interactive: true)))));
      await tester.pumpAndSettle();
      expect(find.text('Visit the centre'), findsOneWidget);
      expect(find.text('Complete'), shared ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
