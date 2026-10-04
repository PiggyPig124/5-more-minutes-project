import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/reminders.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'helpers.dart';

const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
const elder = AuthSession(
    accessToken: 'token',
    user: AppUser(
        id: 'elder',
        displayName: 'Owner',
        email: 'e@example.com',
        role: UserRole.elder));
const carer = AuthSession(
    accessToken: 'token',
    user: AppUser(
        id: 'caregiver',
        displayName: 'Carer',
        email: 'c@example.com',
        role: UserRole.caregiver));
const link = FamilyInvitation(
    id: 'link',
    email: 'c@example.com',
    status: InvitationStatus.accepted,
    elderId: 'elder',
    caregiverId: 'caregiver',
    caregiverName: '陳先生',
    scopes: ['care_tasks']);
Map<String, dynamic> taskJson([Map<String, dynamic> fields = const {}]) => {
      'id': 'task',
      'owner_id': 'elder',
      'access_mode': 'owner',
      'task_type': 'appointment',
      'title': 'Full title',
      'description': 'Full private task description',
      'due_at': '2026-10-08T09:00:00Z',
      'status': 'pending',
      'content_hash': 'a' * 64,
      ...fields
    };
Map<String, dynamic> shareJson([Map<String, dynamic> fields = const {}]) => {
      'id': 'share',
      'task_id': 'task',
      'family_link_id': 'link',
      'shared_by': 'elder',
      'content_hash': 'a' * 64,
      'consented_at': '2026-10-03T10:00:00Z',
      'revoked_at': null,
      'revocation_reason': null,
      'caregiver_id': 'caregiver',
      'caregiver_name': '陳先生',
      ...fields
    };
http.Response jsonResponse(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status, headers: jsonHeaders);
AppController controller(Future<http.Response> Function(http.Request) handler,
        {AuthSession session = elder}) =>
    AppController(
        api: RestApiClient(client: MockClient(handler)),
        sessionStore: SessionStore(MemoryLocalStore()))
      ..session = session
      ..tasks = [CareTask.fromJson(taskJson())]
      ..links = [link];

void main() {
  test(
      'sharing capability requires explicit elder owner metadata and optional API',
      () {
    final real =
        controller((_) async => throw StateError('No network expected'));
    addTearDown(real.dispose);
    final dynamic c = real;
    expect(c.canShareTask(real.tasks.single), true);
    expect(c.canShareTask(CareTask.fromJson(taskJson({'content_hash': null}))),
        true,
        reason: 'Entry may fetch a fresh server hash');
    expect(c.canShareTask(CareTask.fromJson(taskJson({'access_mode': null}))),
        false);
    expect(c.canShareTask(CareTask.fromJson(taskJson({'owner_id': 'other'}))),
        false);
    real.session = carer;
    expect(c.canShareTask(real.tasks.single), false);
    final unsupported = AppController(
        api: FakeApi(), sessionStore: SessionStore(MemoryLocalStore()))
      ..session = elder;
    addTearDown(unsupported.dispose);
    final dynamic legacy = unsupported;
    expect(legacy.canShareTask(CareTask.fromJson(taskJson())), false);
  });
  test(
      'recipient eligibility requires accepted scope and exact owner plus actual caregiver',
      () {
    final real =
        controller((_) async => throw StateError('No network expected'));
    addTearDown(real.dispose);
    real.links = [
      link,
      const FamilyInvitation(
          id: 'pending',
          email: '',
          status: InvitationStatus.pending,
          elderId: 'elder',
          caregiverId: 'caregiver',
          scopes: ['care_tasks']),
      const FamilyInvitation(
          id: 'scope',
          email: '',
          status: InvitationStatus.accepted,
          elderId: 'elder',
          caregiverId: 'caregiver',
          scopes: ['family_messages']),
      const FamilyInvitation(
          id: 'other-owner',
          email: '',
          status: InvitationStatus.accepted,
          elderId: 'other',
          caregiverId: 'caregiver',
          scopes: ['care_tasks']),
      const FamilyInvitation(
          id: 'missing-recipient',
          email: '',
          status: InvitationStatus.accepted,
          elderId: 'elder',
          scopes: ['care_tasks']),
    ];
    final dynamic c = real;
    expect((c.eligibleTaskSharingLinks as List).map((dynamic x) => x.id),
        ['link']);
  });
  test(
      'preview fetches fresh complete content but never POSTs until explicit confirmation',
      () async {
    final requests = <http.Request>[];
    final real = controller((r) async {
      requests.add(r);
      return jsonResponse(
          taskJson({'title': 'Fresh title', 'description': '完整內容'}));
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    final CareTask preview = await c.prepareTaskShare('task');
    expect(preview.title, 'Fresh title');
    expect(preview.description, '完整內容');
    expect(preview.dueAt, DateTime.parse('2026-10-08T09:00:00Z').toLocal());
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/tasks/task');
    expect(c.taskSharePreviews['task'], same(preview));
    expect(c.taskSharesByTask, isEmpty);
  });
  for (final invalid in [
    'missing hash',
    'wrong owner',
    'wrong mode',
    'missing task'
  ]) {
    test('fresh preview $invalid cannot authorize a POST', () async {
      final requests = <http.Request>[];
      final fields = switch (invalid) {
        'missing hash' => {'content_hash': null},
        'wrong owner' => {'owner_id': 'other'},
        'wrong mode' => {'access_mode': 'shared_readonly'},
        _ => <String, dynamic>{}
      };
      final real = controller((r) async {
        requests.add(r);
        return invalid == 'missing task'
            ? jsonResponse({'detail': 'Not found'}, 404)
            : jsonResponse(taskJson(fields));
      });
      addTearDown(real.dispose);
      final dynamic c = real;
      expect(await c.prepareTaskShare('task'), isNull);
      expect(c.taskSharePreviews, isEmpty);
      expect(requests.every((r) => r.method == 'GET'), true);
      expect(c.taskSharingError, isNotNull);
    });
  }
  test(
      'network retry preserves exact consent key and verified POST survives later history failure',
      () async {
    final posts = <Map<String, dynamic>>[];
    var attempts = 0;
    final real = controller((r) async {
      if (r.url.path == '/tasks/task') return jsonResponse(taskJson());
      if (r.method == 'POST') {
        posts.add(jsonDecode(r.body) as Map<String, dynamic>);
        attempts++;
        return attempts == 1
            ? jsonResponse({'detail': 'Try again'}, 503)
            : jsonResponse(shareJson(), 201);
      }
      return jsonResponse({'detail': 'History unavailable'}, 503);
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    final CareTask preview = await c.prepareTaskShare('task');
    expect(await c.confirmTaskShare(preview, link), false);
    expect(c.taskSharePreviews['task'], same(preview));
    expect(c.taskSharesByTask, isEmpty);
    expect(await c.confirmTaskShare(preview, link), true);
    expect(posts.length, 2);
    expect(posts[1], posts[0]);
    expect(posts[0].keys.toSet(),
        {'family_link_id', 'expected_content_hash', 'idempotency_key'});
    expect(posts[0]['idempotency_key'], isNotEmpty);
    expect(await c.refreshTaskShares('task'), false);
    expect(c.taskSharesByTask['task'].single.id, 'share');
  });
  test('409 expires old preview and new preview confirmation uses a new key',
      () async {
    final posts = <Map<String, dynamic>>[];
    var attempt = 0;
    final real = controller((r) async {
      if (r.url.path == '/tasks/task') return jsonResponse(taskJson());
      if (r.method == 'POST') {
        posts.add(jsonDecode(r.body) as Map<String, dynamic>);
        attempt++;
        return attempt == 1
            ? jsonResponse({'detail': 'Preview changed'}, 409)
            : jsonResponse(shareJson(), 201);
      }
      return jsonResponse([]);
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    final CareTask old = await c.prepareTaskShare('task');
    expect(await c.confirmTaskShare(old, link), false);
    expect(c.taskSharePreviews, isEmpty);
    expect(await c.confirmTaskShare(old, link), false);
    expect(posts.length, 1);
    final CareTask fresh = await c.prepareTaskShare('task');
    expect(await c.confirmTaskShare(fresh, link), true);
    expect(posts[1]['idempotency_key'], isNot(posts[0]['idempotency_key']));
  });
  for (final mismatch in [
    'id',
    'task_id',
    'family_link_id',
    'shared_by',
    'content_hash',
    'revoked_at'
  ]) {
    test('mismatched $mismatch receipt never becomes a successful share',
        () async {
      final real = controller((r) async {
        if (r.url.path == '/tasks/task') return jsonResponse(taskJson());
        return jsonResponse(
            shareJson({
              mismatch: mismatch == 'id'
                  ? ''
                  : mismatch == 'revoked_at'
                      ? '2026-10-03T11:00:00Z'
                      : 'wrong'
            }),
            201);
      });
      addTearDown(real.dispose);
      final dynamic c = real;
      final CareTask preview = await c.prepareTaskShare('task');
      expect(await c.confirmTaskShare(preview, link), false);
      expect(c.taskSharesByTask, isEmpty);
      expect(c.taskSharingError, isNotNull);
    });
  }
  for (final valid in [true, false]) {
    test(
        valid
            ? 'revoke records verified revoked receipt'
            : 'unrevoked DELETE receipt is failure', () async {
      final real = controller((r) async => jsonResponse(shareJson(valid
          ? {
              'revoked_at': '2026-10-03T11:00:00Z',
              'revocation_reason': 'owner_revoked'
            }
          : {})));
      addTearDown(real.dispose);
      final dynamic c = real;
      final share = TaskShare.fromJson(shareJson());
      c.taskSharesByTask['task'] = [share];
      expect(await c.revokeTaskShare(real.tasks.single, share), valid);
      expect(c.taskSharesByTask['task'].single.isActive, !valid);
    });
  }
  test(
      'late share success cannot restore receipts or drafts after account switch',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final real = controller((r) async {
      if (r.url.path == '/tasks/task') return jsonResponse(taskJson());
      if (r.method == 'POST') {
        started.complete();
        return response.future;
      }
      if (r.url.path == '/auth/logout') return jsonResponse({});
      return jsonResponse([]);
    });
    addTearDown(real.dispose);
    final dynamic c = real;
    final CareTask preview = await c.prepareTaskShare('task');
    final pending = c.confirmTaskShare(preview, link);
    await started.future;
    await real.logout();
    real.session = carer;
    response.complete(jsonResponse(shareJson(), 201));
    expect(await pending, false);
    expect(c.taskSharePreviews, isEmpty);
    expect(c.taskSharesByTask, isEmpty);
    expect(c.sharingTaskIds, isEmpty);
  });
  test(
      'caregiver refresh filters old broad service and accepts only own or explicit current share',
      () async {
    final real = controller(
        (_) async => jsonResponse([
              taskJson({'id': 'own', 'owner_id': 'caregiver'}),
              taskJson({'id': 'implicit', 'owner_id': 'elder'}),
              taskJson({
                'id': 'valid',
                'owner_id': 'elder',
                'access_mode': 'shared_readonly',
                'share_id': 'share',
                'content_hash': null
              }),
              taskJson({
                'id': 'no-share',
                'owner_id': 'elder',
                'access_mode': 'shared_readonly'
              }),
            ]),
        session: carer);
    addTearDown(real.dispose);
    final dynamic c = real;
    await c.refreshTasks();
    expect(real.tasks.map((t) => t.id), ['own', 'valid']);
  });
  test(
      'caregiver failed refresh removes shared cache at start and preserves own task',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final real = controller((_) async {
      started.complete();
      return response.future;
    }, session: carer);
    addTearDown(real.dispose);
    final dynamic c = real;
    real.tasks = [
      CareTask.fromJson(taskJson({'id': 'own', 'owner_id': 'caregiver'})),
      CareTask.fromJson(taskJson({
        'id': 'shared',
        'access_mode': 'shared_readonly',
        'share_id': 'share'
      }))
    ];
    final pending = c.refreshTasks();
    await started.future;
    final idsDuring = real.tasks.map((t) => t.id).toList();
    response.complete(jsonResponse({'detail': 'Unavailable'}, 503));
    await pending;
    expect(idsDuring, ['own']);
    expect(real.tasks.map((t) => t.id), ['own']);
    expect(real.errorMessage, isNotNull);
  });
  test(
      'new task refresh excludes revoked task and older response cannot restore it',
      () async {
    var requests = 0;
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final first = Completer<http.Response>();
    final second = Completer<http.Response>();
    final real = controller((_) async {
      requests++;
      if (requests == 1) {
        firstStarted.complete();
        return first.future;
      }
      secondStarted.complete();
      return second.future;
    }, session: carer);
    addTearDown(real.dispose);
    final dynamic c = real;
    final old = c.refreshTasks();
    await firstStarted.future;
    final fresh = c.refreshTasks();
    await secondStarted.future;
    second.complete(jsonResponse([]));
    await fresh;
    first.complete(jsonResponse([
      taskJson({'access_mode': 'shared_readonly', 'share_id': 'revoked'})
    ]));
    await old;
    expect(real.tasks, isEmpty);
  });
  test(
      'pausing invalidates pending home refresh and preserves only caregiver own tasks',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final real = controller((r) async {
      if (r.url.path == '/tasks') {
        started.complete();
        return response.future;
      }
      return jsonResponse([]);
    }, session: carer);
    addTearDown(real.dispose);
    final dynamic c = real;
    real.tasks = [
      CareTask.fromJson(taskJson({'id': 'own', 'owner_id': 'caregiver'})),
      CareTask.fromJson(taskJson({
        'id': 'shared',
        'access_mode': 'shared_readonly',
        'share_id': 'share'
      }))
    ];
    final home = real.refreshHome(silent: true);
    await started.future;
    await c.invalidateSharedTaskAccess();
    final visible = real.tasks.map((t) => t.id).toList();
    response.complete(jsonResponse([
      taskJson({
        'id': 'shared',
        'access_mode': 'shared_readonly',
        'share_id': 'share'
      })
    ]));
    await home;
    expect(visible, ['own']);
    expect(real.tasks.map((t) => t.id), ['own']);
  });
  for (final owner in [true, false]) {
    test(
        owner
            ? 'owner link revoke clears cached share receipts and preview'
            : 'caregiver link revoke immediately removes cached shared tasks',
        () async {
      final real = controller((r) async {
        if (r.url.path == '/family-links/link/revoke') return jsonResponse({});
        return jsonResponse([]);
      }, session: owner ? elder : carer);
      addTearDown(real.dispose);
      final dynamic c = real;
      if (owner) {
        c.taskSharesByTask['task'] = [TaskShare.fromJson(shareJson())];
        c.taskSharePreviews['task'] = real.tasks.single;
      } else {
        real.tasks = [
          CareTask.fromJson(taskJson({'id': 'own', 'owner_id': 'caregiver'})),
          CareTask.fromJson(
              taskJson({'access_mode': 'shared_readonly', 'share_id': 'share'}))
        ];
      }
      expect(await real.revokeInvitation(link), true);
      if (owner) {
        expect(c.taskSharesByTask, isEmpty);
        expect(c.taskSharePreviews, isEmpty);
      } else {
        expect(real.tasks.any((t) => t.isReadOnly), false);
      }
    });
  }
  test('logout hides private and shared tasks while API logout is pending', () async {
    final delayedApi = _DelayedLogoutApi();
    final real = AppController(api: delayedApi, sessionStore: SessionStore(MemoryLocalStore()))
      ..session = carer
      ..tasks = [
        CareTask.fromJson(taskJson({'id': 'own', 'owner_id': 'caregiver'})),
        CareTask.fromJson(taskJson({'id': 'shared', 'access_mode': 'shared_readonly', 'share_id': 'share'})),
      ];
    addTearDown(real.dispose);
    final pending = real.logout();
    await delayedApi.started.future;
    final tasksWhileLogoutPending = real.tasks.toList();
    delayedApi.finished.complete();
    await pending;
    expect(tasksWhileLogoutPending, isEmpty, reason: 'Task content must disappear before API logout finishes');
    expect(real.tasks, isEmpty);
  });
  test('reminder sync failure does not block task access revalidation', () async {
    final requests = <http.Request>[];
    final scheduler = _FailingTaskReminderScheduler();
    final real = AppController(
      api: RestApiClient(client: MockClient((request) async {
        requests.add(request);
        return jsonResponse([taskJson({'id': 'current-own', 'owner_id': 'caregiver'})]);
      })),
      sessionStore: SessionStore(MemoryLocalStore()), reminderScheduler: scheduler,
    )..session = carer
     ..tasks = [CareTask.fromJson(taskJson({'id': 'stale', 'access_mode': 'shared_readonly', 'share_id': 'share'}))];
    addTearDown(real.dispose);
    await real.refreshTasks();
    expect(real.tasks.map((task) => task.id), ['current-own']);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/tasks');
    expect(real.errorMessage, isNotNull, reason: 'Notification failure must remain visible without skipping task refresh');
  });

}

class _FailingTaskReminderScheduler implements ReminderScheduler {
  @override
  Future<void> syncDueTasks(String userId, List<CareTask> tasks) async {
    throw StateError('Notification plugin unavailable');
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected reminder method');
}

class _DelayedLogoutApi extends FakeApi {
  final started = Completer<void>();
  final finished = Completer<void>();
  @override
  Future<void> logout() async {
    started.complete();
    await finished.future;
  }
}
