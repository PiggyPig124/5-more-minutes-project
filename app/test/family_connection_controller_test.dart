import 'dart:async';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';

const link = FamilyInvitation(
    id: 'link-1',
    email: 'caregiver@example.test',
    status: InvitationStatus.accepted,
    elderId: 'elder-1',
    caregiverId: 'caregiver-1',
    scopes: ['family_messages', 'care_tasks']);
AppController controllerFor(FakeApi api) =>
    AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
      ..session = const AuthSession(
          accessToken: 'synthetic',
          user: AppUser(
              id: 'elder-1',
              displayName: 'Elder',
              email: 'elder@example.test',
              role: UserRole.elder));

class DelayedApi extends FakeApi {
  final oldLinks = Completer<List<FamilyInvitation>>();
  final started = Completer<void>();
  @override
  Future<List<FamilyInvitation>> listLinks() {
    if (!started.isCompleted) started.complete();
    return oldLinks.future;
  }
}

class ConnectionApi extends FakeApi implements FamilyConnectionApi {
  final keys = <String>[];
  bool fail = true;
  List<FamilyConnectionRequest> requests = [];
  List<FamilyBlock> blocks = [];
  final blockKeys = <String>[];
  final approvals = <(String, int, List<String>)>[];
  @override
  Future<FamilyBlock> blockFamilyPair(
      {required String caregiverId,
      String? requestId,
      String? linkId,
      required String clientOperationId}) async {
    blockKeys.add(clientOperationId);
    if (fail) throw const ApiException('timeout');
    fakeLinks.clear();
    return FamilyBlock(
        elderId: 'elder-1', caregiverId: caregiverId, active: true, version: 1);
  }

  @override
  Future<FamilyInvitation> approveConnectionRequest(
      {required String requestId,
      required int expectedVersion,
      required List<String> scopes}) async {
    approvals.add((requestId, expectedVersion, List.of(scopes)));
    return link;
  }

  @override
  Future<FamilyBlock> unblockFamilyPair(
      {required String caregiverId,
      required int expectedVersion,
      required String clientOperationId}) async {
    return FamilyBlock(
        elderId: 'elder-1',
        caregiverId: caregiverId,
        active: false,
        version: expectedVersion + 1);
  }

  @override
  Future<FamilyConnectionRequest> rejectConnectionRequest(
          {required String requestId, required int expectedVersion}) async =>
      requests.first;
  @override
  Future<FamilyConnectionRequest> withdrawConnectionRequest(
          {required String requestId, required int expectedVersion}) async =>
      requests.first;
  @override
  Future<List<FamilyConnectionRequest>> listConnectionRequests() async =>
      List.of(requests);
  @override
  Future<List<FamilyBlock>> listFamilyBlocks() async => List.of(blocks);
  @override
  Future<List<FamilyMessage>> listSentFamilyMessages() async => [];
  @override
  Future<FamilyConnectionRequest> createConnectionRequest(
      {required String elderEmail, required String clientRequestId}) async {
    keys.add(clientRequestId);
    if (fail) throw const ApiException('timeout');
    return FamilyConnectionRequest(
        id: 'request',
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        elderEmail: elderEmail,
        status: FamilyRequestStatus.pending,
        version: 1,
        expiresAt: DateTime.now().add(const Duration(days: 1)));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FamilyConnectionRequest pending(
        {String id = 'request', int version = 1, String elder = 'elder-1'}) =>
    FamilyConnectionRequest(
        id: id,
        elderId: elder,
        caregiverId: 'caregiver-1',
        elderEmail: 'elder@example.test',
        status: FamilyRequestStatus.pending,
        version: version,
        expiresAt: DateTime.now().add(const Duration(days: 1)));

class DeferredConnectionApi extends ConnectionApi {
  Completer<FamilyBlock>? blocked;
  Completer<List<FamilyInvitation>>? oldLinkResponse;
  @override
  Future<List<FamilyInvitation>> listLinks() =>
      oldLinkResponse?.future ?? super.listLinks();
  @override
  Future<FamilyBlock> blockFamilyPair(
          {required String caregiverId,
          String? requestId,
          String? linkId,
          required String clientOperationId}) =>
      blocked?.future ??
      super.blockFamilyPair(
          caregiverId: caregiverId,
          requestId: requestId,
          linkId: linkId,
          clientOperationId: clientOperationId);
}

class CaregiverConnectionApi extends ConnectionApi {
  @override
  Future<List<FamilyBlock>> listFamilyBlocks() async =>
      throw const ApiException('elder-only', statusCode: 403);
}

class DeniedMessageApi extends ConnectionApi {
  @override
  Future<FamilyMessage> sendFamilyMessage(
          {required String recipientId,
          required String content,
          required String clientMessageId,
          String? sourceStoryId}) async =>
      throw const ApiException('revoked', statusCode: 410);
}

class DeferredTaskApi extends ConnectionApi implements TaskSharingApi {
  final detailResponses = <Completer<CareTask>>[];
  @override
  Future<CareTask> getTaskDetail(String taskId) {
    final response = Completer<CareTask>();
    detailResponses.add(response);
    return response.future;
  }
}

class DeniedFamilyReadApi extends ConnectionApi {
  @override
  Future<List<FamilyMessage>> listFamilyMessages() async =>
      throw const ApiException('access removed', statusCode: 403);
}

void main() {
  test('403 family read withdraws already rendered family cache', () async {
    final api = DeniedFamilyReadApi();
    final controller = controllerFor(api)
      ..links = [link]
      ..familyMessages = [
        const FamilyMessage(
            id: 'old',
            senderId: 'elder-1',
            recipientId: 'caregiver-1',
            content: 'private')
      ];
    await controller.refreshFamilyMessages();
    expect(controller.links, isEmpty);
    expect(controller.familyMessages, isEmpty);
    expect(controller.familyConnectionGeneration, 1);
  });

  test('old detail finally cannot clear new detail loading after pair mutation',
      () async {
    final api = DeferredTaskApi();
    final controller = controllerFor(api)..links = [link];
    final old = controller.refreshTaskDetail('task');
    expect(await controller.blockFamilyConnection(link: link), isFalse);
    final newer = controller.refreshTaskDetail('task');
    const task = CareTask(
        id: 'task',
        title: 'owner task',
        description: '',
        status: TaskStatus.pending,
        ownerId: 'elder-1',
        accessMode: 'owner');
    api.detailResponses.first.complete(task);
    await old;
    expect(controller.loadingTaskDetailIds, contains('task'));
    expect(controller.taskDetails, isEmpty);
    api.detailResponses.last.complete(task);
    await newer;
    expect(controller.taskDetails['task'], task);
  });

  test('known own historical revoked link can identify pair for blocking',
      () async {
    const historical = FamilyInvitation(
        id: 'history-link',
        email: 'caregiver@example.test',
        status: InvitationStatus.revoked,
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        scopes: ['care_tasks']);
    final api = ConnectionApi()..fail = false;
    final controller = controllerFor(api)..links = [historical];
    expect(await controller.blockFamilyConnection(link: historical), isTrue);
    expect(api.blockKeys.length, 1);
    expect(controller.familyMessageLinks, isEmpty);
  });

  test(
      'caregiver refresh avoids elder-only block endpoint while retaining requests',
      () async {
    final request = pending();
    final api = CaregiverConnectionApi()..requests = [request];
    final controller = controllerFor(api)
      ..session = const AuthSession(
          accessToken: 'synthetic',
          user: AppUser(
              id: 'caregiver-1',
              displayName: 'Caregiver',
              email: 'caregiver@example.test',
              role: UserRole.caregiver));
    await controller.refreshFamilyConnections();
    expect(controller.familyConnectionRequests, [request]);
    expect(controller.familyConnectionError, isNull);
  });
  test(
      'remote link revocation on home refresh clears cached messages and previews',
      () async {
    final api = ConnectionApi();
    final controller = controllerFor(api)
      ..links = [link]
      ..familyMessages = [
        const FamilyMessage(
            id: 'old',
            senderId: 'elder-1',
            recipientId: 'caregiver-1',
            content: 'private')
      ];
    controller.taskSharePreviews['task'] = const CareTask(
        id: 'task',
        title: 'private',
        description: '',
        status: TaskStatus.pending);
    await controller.refreshHome(silent: true);
    expect(controller.links, isEmpty);
    expect(controller.familyMessages, isEmpty);
    expect(controller.taskSharePreviews, isEmpty);
    expect(controller.familyConnectionGeneration, greaterThan(0));
  });
  test('410 send retires family authorization without an automatic retry',
      () async {
    final api = DeniedMessageApi();
    final controller = controllerFor(api)
      ..links = [link]
      ..familyMessages = [
        const FamilyMessage(
            id: 'old',
            senderId: 'elder-1',
            recipientId: 'caregiver-1',
            content: 'private')
      ];
    expect(await controller.sendFamilyMessage(link: link, content: 'new'),
        isFalse);
    expect(controller.links, isEmpty);
    expect(controller.familyMessages, isEmpty);
    expect(controller.familyConnectionGeneration, 1);
    expect(controller.loading, isFalse);
  });

  test(
      'fresh share after a new authorization epoch does not reuse revoked persistent key',
      () async {
    final api = ConnectionApi()..failFamilyMessageSend = true;
    final controller = controllerFor(api)..links = [link];
    expect(await controller.sendFamilyMessage(link: link, content: 'same body'),
        isFalse);
    final oldKey = api.lastFamilyMessageClientId;
    expect(await controller.blockFamilyConnection(link: link), isFalse);
    const next = FamilyInvitation(
        id: 'link-1',
        email: 'caregiver@example.test',
        status: InvitationStatus.accepted,
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        scopes: ['family_messages'],
        authorizationEpoch: 2);
    api.fakeLinks.add(next);
    await controller.refreshFamilyConnections();
    api.failFamilyMessageSend = false;
    expect(await controller.sendFamilyMessage(link: next, content: 'same body'),
        isTrue);
    expect(api.lastFamilyMessageClientId, isNot(oldKey));
  });
  test('unknown scopes in an otherwise accepted link cannot authorize sends',
      () async {
    const malformed = FamilyInvitation(
        id: 'bad',
        email: 'caregiver@example.test',
        status: InvitationStatus.accepted,
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        scopes: ['family_messages', 'unknown']);
    final api = ConnectionApi();
    final controller = controllerFor(api)..links = [malformed];
    expect(
        await controller.sendFamilyMessage(link: malformed, content: 'private'),
        isFalse);
    expect(api.fakeFamilyMessages, isEmpty);
  });

  test('mutation invalidates an older connection refresh response', () async {
    final api = DeferredConnectionApi()
      ..oldLinkResponse = Completer<List<FamilyInvitation>>();
    final controller = controllerFor(api)..links = [link];
    final refresh = controller.refreshFamilyConnections();
    await Future<void>.delayed(Duration.zero);
    expect(await controller.blockFamilyConnection(link: link), isFalse);
    api.oldLinkResponse!.complete([link]);
    await refresh;
    expect(controller.links, isEmpty);
    expect(controller.familyConnectionError, 'timeout');
  });
  test('late mutation success and finally cannot overwrite a new session',
      () async {
    final api = DeferredConnectionApi()..blocked = Completer<FamilyBlock>();
    final controller = controllerFor(api)..links = [link];
    final mutation = controller.blockFamilyConnection(link: link);
    expect(controller.familyConnectionBusy, isTrue);
    await controller.logout();
    controller.session = const AuthSession(
        accessToken: 'new',
        user: AppUser(
            id: 'new-elder',
            displayName: 'New',
            email: 'new@example.test',
            role: UserRole.elder));
    controller.familyConnectionBusy = true;
    controller.familyConnectionError = 'new-session-error';
    api.blocked!.complete(const FamilyBlock(
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        active: true,
        version: 1));
    expect(await mutation, isFalse);
    expect(controller.familyConnectionBusy, isTrue);
    expect(controller.familyConnectionError, 'new-session-error');
    expect(controller.links, isEmpty);
  });
  test('unknown request and missing epoch link fail closed', () async {
    final api = ConnectionApi()..fail = false;
    final request = const FamilyConnectionRequest(
        id: 'unknown',
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        elderEmail: 'elder@example.test',
        status: FamilyRequestStatus.unknown,
        version: 1);
    final malformed = FamilyInvitation.fromJson({
      'id': 'link-1',
      'elder_id': 'elder-1',
      'caregiver_id': 'caregiver-1',
      'status': 'accepted',
      'scopes': ['family_messages']
    });
    final controller = controllerFor(api)
      ..familyConnectionRequests = [request]
      ..links = [malformed];
    expect(await controller.approveFamilyConnection(request, ['care_tasks']),
        isFalse);
    expect(await controller.blockFamilyConnection(request: request), isFalse);
    expect(controller.familyMessageLinks, isEmpty);
    expect(await controller.blockFamilyConnection(link: malformed), isFalse);
    expect(api.blockKeys, isEmpty);
  });

  test(
      'block timeout hides derived access and exact link retry keeps operation key',
      () async {
    final api = ConnectionApi();
    final controller = controllerFor(api)
      ..links = [link]
      ..familyMessages = [
        const FamilyMessage(
            id: 'message',
            senderId: 'elder-1',
            recipientId: 'caregiver-1',
            content: 'shared')
      ];
    expect(await controller.blockFamilyConnection(link: link), isFalse);
    expect(controller.links, isEmpty);
    expect(controller.familyMessages, isEmpty);
    expect(controller.familyMessageLinks, isEmpty);
    expect(controller.familyConnectionGeneration, 1);
    api.fail = false;
    expect(await controller.blockFamilyConnection(link: link), isTrue);
    expect(api.blockKeys.toSet().length, 1);
    expect(controller.links, isEmpty);
  });
  test(
      'successful refresh invalidates old failed operation source when authorization changed',
      () async {
    final api = ConnectionApi();
    final controller = controllerFor(api)..links = [link];
    expect(await controller.blockFamilyConnection(link: link), isFalse);
    await controller.refreshFamilyConnections();
    api.fail = false;
    expect(await controller.blockFamilyConnection(link: link), isFalse);
    expect(api.blockKeys.length, 1);
  });
  test('approval captures exact request ID version and explicit allowed scopes',
      () async {
    final request = pending();
    final api = ConnectionApi()..requests = [request];
    final controller = controllerFor(api)..familyConnectionRequests = [request];
    expect(await controller.approveFamilyConnection(request, []), isFalse);
    expect(
        await controller
            .approveFamilyConnection(pending(elder: 'other'), ['care_tasks']),
        isFalse);
    expect(await controller.approveFamilyConnection(request, ['care_tasks']),
        isTrue);
    expect(api.approvals.single.$1, 'request');
    expect(api.approvals.single.$2, 1);
    expect(api.approvals.single.$3, ['care_tasks']);
  });
  test(
      'historical own request can block without a live link and unblock restores no link',
      () async {
    final request = FamilyConnectionRequest(
        id: 'history',
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        elderEmail: 'elder@example.test',
        status: FamilyRequestStatus.rejected,
        version: 2);
    final api = ConnectionApi()..fail = false;
    final controller = controllerFor(api)..familyConnectionRequests = [request];
    expect(await controller.blockFamilyConnection(request: request), isTrue);
    const block = FamilyBlock(
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
        active: true,
        version: 1);
    controller.familyBlocks = [block];
    expect(await controller.unblockFamilyConnection(block), isTrue);
    expect(controller.links, isEmpty);
  });
  test('legacy API capability remains optional', () async {
    final controller = controllerFor(FakeApi());
    expect(controller.supportsFamilyConnections, isFalse);
    expect(await controller.requestFamilyConnection('elder@example.test'),
        isFalse);
    await controller.refreshFamilyConnections();
    expect(controller.familyConnectionBusy, isFalse);
  });

  test('same normalized request retries with its original key after failure',
      () async {
    final api = ConnectionApi();
    final controller = controllerFor(api)
      ..session = const AuthSession(
          accessToken: 'synthetic',
          user: AppUser(
              id: 'caregiver-1',
              displayName: 'Caregiver',
              email: 'caregiver@example.test',
              role: UserRole.caregiver));
    final dynamic subject = controller;
    expect(
        await subject.requestFamilyConnection(' Elder@Example.test '), isFalse);
    api.fail = false;
    expect(await subject.requestFamilyConnection('elder@example.test'), isTrue);
    expect(api.keys.length, 2);
    expect(api.keys.toSet().length, 1);
  });

  test('revoke invalidates an older home response before network completion',
      () async {
    final api = DelayedApi();
    final controller = controllerFor(api)..links = [link];
    final refresh = controller.refreshHome(silent: true);
    await api.started.future;
    expect(await controller.revokeInvitation(link), isTrue);
    api.oldLinks.complete([link]);
    await refresh;
    expect(controller.links, isEmpty,
        reason: 'revoked authorization cannot return from an old response');
  });
}
