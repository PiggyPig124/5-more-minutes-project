import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const carer = AuthSession(
    accessToken: 'token',
    user: AppUser(
        id: 'caregiver',
        displayName: 'Carer',
        email: 'c@example.com',
        role: UserRole.caregiver));
const headers = {'content-type': 'application/json; charset=utf-8'};
Map<String, dynamic> detail([Map<String, dynamic> fields = const {}]) => {
      'id': 'shared',
      'owner_id': 'elder',
      'owner_display_name': '陳婆婆',
      'access_mode': 'shared_readonly',
      'share_id': 'share',
      'task_type': 'appointment',
      'title': 'Task title',
      'description': 'Complete authorized body',
      'due_at': '2026-10-08T09:00:00Z',
      'status': 'pending',
      ...fields
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status, headers: headers);
AppController buildController(
        Future<http.Response> Function(http.Request) handler) =>
    AppController(
        api: RestApiClient(client: MockClient(handler)),
        sessionStore: SessionStore(MemoryLocalStore()))
      ..session = carer
      ..tasks = [
        CareTask.fromJson(detail()),
        CareTask.fromJson(detail({
          'id': 'own',
          'owner_id': 'caregiver',
          'access_mode': 'owner',
          'share_id': null
        }))
      ];
void main() {
  test(
      'shared detail parses senior name and minimal authorized metadata from GET',
      () async {
    final requests = <http.Request>[];
    final real = buildController((r) async {
      requests.add(r);
      return response(detail());
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    await c.refreshTaskDetail('shared');
    final dynamic item = c.taskDetails['shared'];
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/tasks/shared');
    expect(item.ownerDisplayName, '陳婆婆');
    expect(item.description, 'Complete authorized body');
    expect(item.taskType, 'appointment');
    expect(item.isReadOnly, true);
    expect(item.shareId, 'share');
    expect(item.contentHash, isNull);
    expect(c.taskDetailErrors, isEmpty);
  });
  test('pending detail GET hides prior cached body immediately', () async {
    final started = Completer<void>();
    final result = Completer<http.Response>();
    final real = buildController((_) async {
      started.complete();
      return result.future;
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    c.taskDetails['shared'] =
        CareTask.fromJson(detail({'description': 'Old cached private body'}));
    final pending = c.refreshTaskDetail('shared');
    await started.future;
    final visibleDuring = (c.taskDetails as Map).containsKey('shared');
    final loadingDuring = (c.loadingTaskDetailIds as Set).contains('shared');
    result.complete(response(detail()));
    await pending;
    expect(visibleDuring, false);
    expect(loadingDuring, true);
    expect(c.taskDetails['shared'].description, 'Complete authorized body');
  });
  for (final status in [403, 404, 503]) {
    test(
        'detail status $status removes old body and shared list row while preserving own task',
        () async {
      final real = buildController(
          (_) async => response({'detail': 'Not accessible'}, status));
      addTearDown(real.dispose);
      final dynamic c = real;
      c.taskDetails['shared'] = CareTask.fromJson(detail());
      await c.refreshTaskDetail('shared');
      expect(c.taskDetails, isEmpty);
      expect(real.tasks.map((t) => t.id), ['own']);
      expect(c.taskDetailErrors['shared'], isNotNull);
      expect(c.loadingTaskDetailIds, isEmpty);
    });
  }
  for (final change in ['pause', 'list refresh', 'account switch']) {
    test('$change prevents late detail GET from restoring private body',
        () async {
      final started = Completer<void>();
      final result = Completer<http.Response>();
      final real = buildController((r) async {
        if (r.url.path == '/tasks/shared') {
          started.complete();
          return result.future;
        }
        return response([]);
      });
      addTearDown(real.dispose);
      final dynamic c = real;
      final pending = c.refreshTaskDetail('shared');
      await started.future;
      switch (change) {
        case 'pause':
          await c.invalidateTaskDetail('shared');
        case 'list refresh':
          await real.refreshTasks();
        default:
          await real.logout();
          real.session = const AuthSession(
              accessToken: 'next',
              user: AppUser(
                  id: 'next',
                  displayName: 'Next',
                  email: 'next@example.com',
                  role: UserRole.caregiver));
      }
      result.complete(response(detail({'description': 'Late revoked body'})));
      await pending;
      expect(c.taskDetails, isEmpty);
      expect(real.tasks.any((task) => task.id == 'shared'), false);
    });
  }
  test('new detail recheck wins over older detail response', () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final first = Completer<http.Response>();
    final second = Completer<http.Response>();
    var calls = 0;
    final real = buildController((_) async {
      calls++;
      if (calls == 1) {
        firstStarted.complete();
        return first.future;
      }
      secondStarted.complete();
      return second.future;
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    final old = c.refreshTaskDetail('shared');
    await firstStarted.future;
    final fresh = c.refreshTaskDetail('shared');
    await secondStarted.future;
    second
        .complete(response(detail({'description': 'Latest authorized body'})));
    await fresh;
    first.complete(response(detail({'description': 'Old body'})));
    await old;
    expect(c.taskDetails['shared'].description, 'Latest authorized body');
  });
  test('own caregiver task returned by detail remains editable', () async {
    final requests = <http.Request>[];
    final real = buildController((r) async {
      requests.add(r);
      return response(detail({
        'id': 'own',
        'owner_id': 'caregiver',
        'access_mode': 'owner',
        'share_id': null,
        'status': r.method == 'PATCH' ? 'completed' : 'pending'
      }));
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    await c.refreshTaskDetail('own');
    final CareTask own = c.taskDetails['own'];
    expect(real.canUpdateTask(own), true);
    expect(await real.updateTaskStatus(own, TaskStatus.completed), true);
    expect(requests.map((r) => r.method), ['GET', 'PATCH']);
  });
  test(
      'shared access invalidation clears already loaded detail and preserves own detail',
      () async {
    final real = buildController((request) async => response(
        request.url.path == '/tasks/own'
            ? detail({
                'id': 'own',
                'owner_id': 'caregiver',
                'access_mode': 'owner',
                'share_id': null
              })
            : detail()));
    addTearDown(real.dispose);
    await real.refreshTaskDetail('own');
    await real.refreshTaskDetail('shared');
    expect(real.taskDetails.keys.toSet(), {'own', 'shared'});
    final ownDetail = real.taskDetails['own'];
    final pending = real.invalidateSharedTaskAccess();
    expect(real.taskDetails.keys, ['own']);
    expect(real.taskDetails['own'], same(ownDetail));
    expect(real.tasks.map((task) => task.id), ['own']);
    await pending;
    expect(real.taskDetails.keys, ['own']);
  });
  test(
      'pending list recheck clears loaded shared detail but preserves own detail',
      () async {
    final listStarted = Completer<void>();
    final listResponse = Completer<http.Response>();
    final real = buildController((request) async {
      if (request.url.path == '/tasks') {
        listStarted.complete();
        return listResponse.future;
      }
      return response(request.url.path == '/tasks/own'
          ? detail({
              'id': 'own',
              'owner_id': 'caregiver',
              'access_mode': 'owner',
              'share_id': null
            })
          : detail());
    });
    addTearDown(real.dispose);
    await real.refreshTaskDetail('own');
    await real.refreshTaskDetail('shared');
    expect(real.taskDetails.keys.toSet(), {'own', 'shared'});
    final ownDetail = real.taskDetails['own'];
    final pending = real.refreshTasks();
    await listStarted.future;
    final detailIdsDuringRecheck = real.taskDetails.keys.toList();
    final ownDuringRecheck = real.taskDetails['own'];
    listResponse.complete(response([]));
    await pending;
    expect(detailIdsDuringRecheck, ['own']);
    expect(ownDuringRecheck, same(ownDetail));
    expect(real.taskDetails.keys, ['own']);
    expect(real.taskDetails['own'], same(ownDetail));
  });
}
