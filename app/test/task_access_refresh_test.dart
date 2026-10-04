import 'dart:async';
import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:anxin_companion/src/task_access_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> taskJson(String id, {bool shared = false}) => {
      'id': id,
      'title': shared ? 'Shared private task' : 'My own task',
      'description': 'Task details',
      'status': 'pending',
      'owner_id': shared ? 'elder' : 'caregiver',
      'access_mode': shared ? 'shared_readonly' : 'owner',
      'is_shared': shared,
      if (shared) 'share_id': 'synthetic-share',
    };

http.Response tasksResponse({bool shared = true}) => http.Response(
      jsonEncode(
          [taskJson('own'), if (shared) taskJson('shared', shared: true)]),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

AppController taskController(
        Future<http.Response> Function(http.Request) handler) =>
    AppController(
        api: RestApiClient(client: MockClient((request) {
          expectSync(request.method, 'GET');
          expectSync(request.url.path, '/tasks');
          return handler(request);
        })),
        sessionStore: SessionStore(MemoryLocalStore()))
      ..session = const AuthSession(
          accessToken: 'synthetic-token',
          user: AppUser(
              id: 'caregiver',
              displayName: 'Carer',
              email: 'carer@example.test',
              role: UserRole.caregiver));

Future<void> mountTasks(WidgetTester tester, AppController controller) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    tester.binding.scheduleForcedFrame();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    controller.dispose();
  });
  await tester.pumpWidget(MaterialApp(
      home: TaskAccessRefresh(
    controller: controller,
    child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Column(
            children: [for (final task in controller.tasks) Text(task.title)])),
  )));
  await tester.pump();
}

void main() {
  testWidgets(
      'entry and foreground poll reauthorize tasks; pause clears shared access and resume refreshes',
      (tester) async {
    var requests = 0;
    final controller = taskController((_) async {
      requests++;
      return tasksResponse();
    });
    await mountTasks(tester, controller);
    await tester.pumpAndSettle();
    expect(requests, 1, reason: 'entry must fetch fresh authorization');
    expect(find.text('Shared private task'), findsOneWidget);
    expect(find.text('My own task'), findsOneWidget);
    await tester.pump(const Duration(seconds: 29));
    expect(requests, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(requests, 2, reason: 'foreground must revalidate after 30 seconds');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(controller.tasks.map((task) => task.id), ['own'],
        reason: 'pause must remove shared data immediately');
    // Paused apps do not schedule frames; force one to inspect the cleared UI.
    tester.binding.scheduleForcedFrame();
    await tester.pump();
    expect(find.text('Shared private task'), findsNothing);
    expect(find.text('My own task'), findsOneWidget);
    await tester.pump(const Duration(seconds: 90));
    expect(requests, 2, reason: 'background must not poll');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(requests, 3,
        reason: 'resume must reauthorize without waiting 30 seconds');
    expect(find.text('Shared private task'), findsOneWidget);
  });

  testWidgets(
      'a task response started before pause cannot restore shared cache',
      (tester) async {
    final oldResponse = Completer<http.Response>();
    var requests = 0;
    final controller = taskController((_) {
      requests++;
      return oldResponse.future;
    })
      ..tasks = [
        CareTask.fromJson(taskJson('own')),
        CareTask.fromJson(taskJson('shared', shared: true))
      ];
    await mountTasks(tester, controller);
    expect(requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(controller.tasks.map((task) => task.id), ['own']);
    oldResponse.complete(tasksResponse());
    await tester.pumpAndSettle();
    expect(controller.tasks.map((task) => task.id), ['own']);
    expect(find.text('Shared private task'), findsNothing);
    expect(find.text('My own task'), findsOneWidget);
  });

  testWidgets(
      'resume can revalidate while the old pre-pause request is pending',
      (tester) async {
    final oldResponse = Completer<http.Response>();
    var requests = 0;
    final controller = taskController((_) {
      requests++;
      return requests == 1
          ? oldResponse.future
          : Future.value(tasksResponse(shared: false));
    })
      ..tasks = [
        CareTask.fromJson(taskJson('own')),
        CareTask.fromJson(taskJson('shared', shared: true))
      ];
    await mountTasks(tester, controller);
    await tester.pump();
    expect(requests, 1, reason: 'the pre-pause GET must already be in flight');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(requests, 2);
    expect(controller.tasks.map((task) => task.id), ['own']);
    oldResponse.complete(tasksResponse());
    await tester.pumpAndSettle();
    expect(controller.tasks.map((task) => task.id), ['own']);
    expect(find.text('Shared private task'), findsNothing);
  });

  testWidgets(
      'disposing the task screen cancels periodic authorization refresh',
      (tester) async {
    var requests = 0;
    final controller = taskController((_) async {
      requests++;
      return tasksResponse();
    });
    await mountTasks(tester, controller);
    await tester.pumpAndSettle();
    expect(requests, 1);
    tester.binding.scheduleForcedFrame();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(seconds: 90));
    expect(requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests, 1, reason: 'disposed observer must not refresh on resume');
    expect(tester.takeException(), isNull);
  });
}
