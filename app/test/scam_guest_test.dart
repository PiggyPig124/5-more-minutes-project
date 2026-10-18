import 'dart:async';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const resource = ScamResource(
    id: 'public', title: 'Public guidance', excerpt: 'Synthetic guidance');
const action = VerifyAction(
    step: 2,
    action: 'protect',
    title: 'Protect',
    description:
        'Do not transfer money or provide passwords or personal information.');
const contact = ScamContact(name: 'Approved contact fixture', phone: '18222');
const session = AuthSession(
    accessToken: 'synthetic',
    user: AppUser(
        id: 'elder-test',
        displayName: 'Synthetic elder',
        email: 'synthetic@example.test',
        role: UserRole.elder));

class ScamApi extends FakeApi implements CatalogScamApi {
  bool fail = false;
  int privateReads = 0;
  int privateWrites = 0;
  Completer<List<ScamResource>>? pendingResources;
  Completer<List<VerifyAction>>? pendingActions;
  Completer<List<ScamContact>>? pendingContacts;
  Completer<List<ScamLogEntry>>? pendingLogs;

  @override
  Future<List<ScamResource>> listScamResources({String? scamType}) async {
    if (fail) throw const ApiException('Guidance unavailable', statusCode: 503);
    if (pendingResources != null) return await pendingResources!.future;
    return [resource];
  }

  @override
  Future<List<ScamResource>> searchScamResources(String query) async =>
      query == 'missing' ? [] : [resource];
  @override
  Future<List<VerifyAction>> getVerifyActions() async {
    if (fail) throw const ApiException('Guidance unavailable', statusCode: 503);
    if (pendingActions != null) return await pendingActions!.future;
    return [action];
  }

  @override
  Future<List<ScamContact>> getScamContacts() async {
    if (fail) throw const ApiException('Guidance unavailable', statusCode: 503);
    if (pendingContacts != null) return await pendingContacts!.future;
    return [contact];
  }

  @override
  Future<List<ScamLogEntry>> listScamLogs() async {
    privateReads++;
    if (pendingLogs != null) return await pendingLogs!.future;
    return [];
  }

  @override
  Future<void> logScamGuidance(
      {required String scamType,
      required String guidanceSummary,
      String? scamResourceId,
      String? conversationId}) async {
    privateWrites++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppController makeController(ScamApi api, {bool signedIn = false}) =>
    AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
      ..session = signedIn ? session : null;

Future<void> mount(WidgetTester tester, AppController controller) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [appControllerProvider.overrideWith((ref) => controller)],
    child: MaterialApp(
        locale: englishLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const ScamSafetyScreen())),
                    child: const Text('Open guidance'))))),
  ));
  await tester.tap(find.text('Open guidance'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'leaving guidance during a slow load does not block session controls',
      (tester) async {
    final pending = Completer<List<ScamResource>>();
    final api = ScamApi()..pendingResources = pending;
    final controller = makeController(api);
    await mount(tester, controller);
    await tester.pageBack();
    await tester.pumpAndSettle();
    final loadingAfterExit = controller.loading;
    pending.complete([resource]);
    await tester.pumpAndSettle();
    expect(find.text('Open guidance'), findsOneWidget);
    expect(loadingAfterExit, isFalse);
    expect(api.privateWrites, 0);
    expect(tester.takeException(), isNull);
  });

  test('late load after logout cannot end a new guest load', () async {
    final previous = Completer<List<ScamResource>>();
    final current = Completer<List<ScamResource>>();
    final api = ScamApi()..pendingResources = previous;
    final controller = makeController(api, signedIn: true);
    final staleLoad = controller.refreshScamResources();
    await controller.logout();
    api.pendingResources = current;
    final currentLoad = controller.refreshScamResources();
    expect(controller.loading, isTrue);
    previous.complete([resource]);
    await staleLoad;
    final stillLoading = controller.loading;
    current.complete([resource]);
    await currentLoad;
    expect(stillLoading, isTrue);
    expect(controller.loading, isFalse);
    expect(controller.scamResources.single.id, 'public');
  });

  for (final signedIn in [false, true]) {
    test('public guidance loads in ${signedIn ? 'personal' : 'guest'} mode',
        () async {
      final api = ScamApi();
      final controller = makeController(api, signedIn: signedIn);
      await Future.wait([
        controller.refreshScamResources(),
        controller.refreshVerifyActions(),
        controller.refreshScamContacts(),
        controller.refreshScamLogs()
      ]);
      expect(controller.scamResources.single.id, 'public');
      expect(
          controller.verifyActions.single.description, contains('passwords'));
      expect(controller.scamContacts.single.phone, '18222');
      expect((await controller.searchScamResources('Synthetic')).single.id,
          'public');
      if (!signedIn) {
        expect(
            await controller.logScamGuidance(
                scamType: 'general', guidanceSummary: 'Synthetic'),
            isFalse);
        expect(api.privateReads, 0);
        expect(api.privateWrites, 0);
      }
    });

    testWidgets(
        'guidance content and back exit in ${signedIn ? 'personal' : 'guest'} mode',
        (tester) async {
      final api = ScamApi();
      await mount(tester, makeController(api, signedIn: signedIn));
      expect(find.text(action.description), findsOneWidget);
      expect(find.text('Public guidance'), findsOneWidget);
      // This legacy fixture has no approval metadata and must remain visible as unavailable.
      expect(find.text('Call unavailable'), findsOneWidget);
      expect(find.textContaining('automatically'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Open guidance'), findsOneWidget);
      expect(api.privateWrites, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed guidance is visible and can retry without signing in',
      (tester) async {
    final api = ScamApi()..fail = true;
    await mount(tester, makeController(api));
    expect(find.text('Guidance unavailable'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text(action.description), findsOneWidget);
    expect(find.text('Public guidance'), findsOneWidget);
    expect(find.text('Guidance unavailable'), findsNothing);
    expect(api.privateReads, 0);
    expect(api.privateWrites, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('action or contact failure alone is visible and retryable',
      (tester) async {
    for (final actionsFail in [true, false]) {
      final api = ScamApi();
      if (actionsFail) {
        api.pendingActions = Completer();
      } else {
        api.pendingContacts = Completer();
      }
      final controller = makeController(api, signedIn: true);
      await mount(tester, controller);
      if (actionsFail) {
        api.pendingActions!
            .completeError(const ApiException('Partial failure'));
      } else {
        api.pendingContacts!
            .completeError(const ApiException('Partial failure'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Partial failure'), findsOneWidget);
      api.pendingActions = null;
      api.pendingContacts = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(action.description), findsOneWidget);
      expect(find.text('Call unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  test('logout fences late public and private guidance results', () async {
    final api = ScamApi()
      ..pendingResources = Completer()
      ..pendingActions = Completer()
      ..pendingContacts = Completer()
      ..pendingLogs = Completer();
    final controller = makeController(api, signedIn: true);
    final pending = Future.wait([
      controller.refreshScamResources(),
      controller.refreshVerifyActions(),
      controller.refreshScamContacts(),
      controller.refreshScamLogs()
    ]);
    await controller.logout();
    api.pendingResources!.complete([resource]);
    api.pendingActions!.complete([action]);
    api.pendingContacts!.complete([contact]);
    api.pendingLogs!.complete([
      const ScamLogEntry(
          id: 'private', scamType: 'private', guidanceSummary: 'Private')
    ]);
    await pending;
    expect(controller.scamResources, isEmpty);
    expect(controller.verifyActions, isEmpty);
    expect(controller.scamContacts, isEmpty);
    expect(controller.scamLogs, isEmpty);
    api.pendingResources = null;
    await controller.refreshScamResources();
    expect(controller.scamResources.single.id, 'public');
  });
}
