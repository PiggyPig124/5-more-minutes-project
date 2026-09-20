import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'helpers.dart';

void main() {
  test('failed send preserves local draft and retry reuses message id', () async {
    final api = FakeApi();
    final store = MemoryLocalStore();
    final controller = AppController(api: api, sessionStore: SessionStore(store));
    expect(await controller.login(email: 'elder@example.com', password: 'password123'), isTrue);
    final conversation = await controller.startConversation();
    expect(conversation, isNotNull);
    await controller.saveDraft(conversation!.id, '我今晚想早一點休息');

    api.failSend = true;
    expect(await controller.sendMessage(conversationId: conversation.id, content: '我今晚想早一點休息'), isFalse);
    final firstClientId = api.lastMessageClientId;
    expect(firstClientId, isNotNull);
    expect(await controller.readDraft(conversation.id), '我今晚想早一點休息');

    api.failSend = false;
    expect(await controller.sendMessage(conversationId: conversation.id, content: '我今晚想早一點休息'), isTrue);
    expect(api.lastMessageClientId, firstClientId);
    expect(await controller.readDraft(conversation.id), isNull);
  });

  test('sending the same text again after success creates a new operation id', () async {
    final api = FakeApi();
    final controller = AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(await controller.login(email: 'elder@example.com', password: 'password123'), isTrue);
    final conversation = await controller.startConversation();
    expect(conversation, isNotNull);

    expect(await controller.sendMessage(conversationId: conversation!.id, content: '早晨好'), isTrue);
    final firstId = api.lastMessageClientId;
    expect(await controller.sendMessage(conversationId: conversation.id, content: '早晨好'), isTrue);
    expect(api.lastMessageClientId, isNot(firstId));
  });

  test('a failed draft retry after controller recreation keeps its client id', () async {
    final store = MemoryLocalStore();
    final firstApi = FakeApi();
    final first = AppController(api: firstApi, sessionStore: SessionStore(store));
    expect(await first.login(email: 'elder@example.com', password: 'password123'), isTrue);
    final conversation = await first.startConversation();
    expect(conversation, isNotNull);
    await first.saveDraft(conversation!.id, '請提醒我覆診');
    firstApi.failSend = true;
    expect(await first.sendMessage(conversationId: conversation.id, content: '請提醒我覆診'), isFalse);
    final originalId = firstApi.lastMessageClientId;

    final secondApi = FakeApi()..failSend = true;
    final second = AppController(api: secondApi, sessionStore: SessionStore(store));
    await second.initialize();
    expect(await second.readDraft(conversation.id), '請提醒我覆診');
    expect(await second.sendMessage(conversationId: conversation.id, content: '請提醒我覆診'), isFalse);
    expect(secondApi.lastMessageClientId, originalId);
  });

  test('confirming the same action through the controller removes preview only after success', () async {
    final api = FakeApi()..fakeAction = const ActionProposal(id: 'action-1', kind: ActionKind.task, title: '提醒覆診', description: '星期五上午十時');
    final controller = AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(await controller.login(email: 'elder@example.com', password: 'password123'), isTrue);
    final conversation = await controller.startConversation();
    expect(conversation, isNotNull);
    expect(await controller.sendMessage(conversationId: conversation!.id, content: '請記住覆診'), isTrue);
    expect(controller.pendingActions, hasLength(1));
    final action = controller.pendingActions.single;
    expect(await controller.confirmAction(action), isTrue);
    expect(controller.pendingActions, isEmpty);
    expect(api.actionConfirmations, 1);
    expect(api.lastActionClientId, isNotNull);
  });

  test('stored token is validated before restoring an authenticated screen', () async {
    final store = MemoryLocalStore();
    final sessionStore = SessionStore(store);
    await sessionStore.saveSession(
      const AuthSession(
        accessToken: 'expired-token',
        user: AppUser(id: 'old', displayName: '舊帳戶', email: 'old@example.com', role: UserRole.elder),
      ),
    );
    final controller = AppController(api: _ExpiredApi(), sessionStore: sessionStore);
    await controller.initialize();
    expect(controller.session, isNull);
    expect(await store.read(SessionStore.tokenKey), isNull);
  });

  test('a response from a previous account cannot repopulate the next account', () async {
    final api = _GenerationApi();
    final controller = AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(await controller.login(email: 'elder@example.com', password: 'password123'), isTrue);
    api.fakeTasks.add(const CareTask(id: 'elder-only', title: '長者私有項目', description: '', status: TaskStatus.pending));
    api.blockNextTaskLoad = true;
    final staleRefresh = controller.refreshHome();
    await Future<void>.delayed(Duration.zero);

    await controller.logout();
    api.fakeTasks.clear();
    api.role = UserRole.caregiver;
    expect(await controller.login(email: 'caregiver@example.com', password: 'password123'), isTrue);
    api.releaseBlockedTaskLoad();
    await staleRefresh;

    expect(controller.user?.role, UserRole.caregiver);
    expect(controller.tasks.where((task) => task.id == 'elder-only'), isEmpty);
  });

  test('memories remain explicit candidates and destructive changes retract local stories', () async {
    final api = FakeApi();
    final controller = AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(await controller.login(email: 'elder@example.com', password: 'password123'), isTrue);
    expect(api.fakeMemories, isEmpty);
    expect(await controller.sendMessage(conversationId: (await controller.startConversation())!.id, content: '我今日心情很好'), isTrue);
    expect(api.fakeMemories, isEmpty);

    expect(await controller.createMemory(content: '我喜歡在公園散步', kind: 'conversation'), isTrue);
    final candidate = controller.memories.single;
    expect(candidate.isCandidate, isTrue);
    expect(await controller.confirmMemory(candidate), isTrue);
    expect(controller.memories.single.isConfirmed, isTrue);

    final story = await api.createStory(title: '我的習慣', content: '我喜歡在公園散步', memoryIds: [controller.memories.single.id]);
    controller.stories = [story];
    expect(await controller.editMemory(controller.memories.single, '我喜歡早上在公園散步'), isTrue);
    expect(controller.stories, isEmpty);
    expect(await controller.deleteMemory(controller.memories.single), isTrue);
    expect(controller.memories, isEmpty);
  });

  test('family message review operation retries with the same id then clears it after success', () async {
    final store = MemoryLocalStore();
    final api = FakeApi()
      ..fakeLinks.add(
        const FamilyInvitation(
          id: 'link-1',
          email: 'caregiver@example.com',
          status: InvitationStatus.accepted,
          scopes: ['care_tasks', 'family_messages'],
          elderId: 'elder-1',
          caregiverId: 'caregiver-1',
          name: '照顧者',
        ),
      );
    final controller = AppController(api: api, sessionStore: SessionStore(store));
    expect(await controller.login(email: 'elder@example.com', password: 'password123'), isTrue);
    final link = controller.familyMessageLinks.single;
    api.failFamilyMessageSend = true;
    expect(await controller.sendFamilyMessage(link: link, content: '記得飲水'), isFalse);
    final firstId = api.lastFamilyMessageClientId;
    expect(firstId, isNotNull);

    api.failFamilyMessageSend = false;
    expect(await controller.sendFamilyMessage(link: link, content: '記得飲水'), isTrue);
    expect(api.lastFamilyMessageClientId, firstId);
    expect(controller.familyMessages, hasLength(1));

    expect(await controller.sendFamilyMessage(link: link, content: '記得飲水'), isTrue);
    expect(api.lastFamilyMessageClientId, isNot(firstId));
    expect(controller.familyMessages, hasLength(2));
  });

  test('a delayed family message storage read cannot send after account switch', () async {
    final store = _DelayedFamilyStore();
    final api = FakeApi()
      ..fakeLinks.add(
        const FamilyInvitation(
          id: 'link-1',
          email: 'caregiver@example.com',
          status: InvitationStatus.accepted,
          scopes: ['care_tasks', 'family_messages'],
          elderId: 'elder-1',
          caregiverId: 'caregiver-1',
        ),
      );
    final controller = AppController(api: api, sessionStore: SessionStore(store));
    expect(await controller.login(email: 'elder@example.com', password: 'password123'), isTrue);
    final pending = controller.sendFamilyMessage(link: controller.familyMessageLinks.single, content: '只應該屬於舊帳戶');
    await Future<void>.delayed(Duration.zero);
    await controller.logout();
    api.role = UserRole.caregiver;
    expect(await controller.login(email: 'caregiver@example.com', password: 'password123'), isTrue);
    store.releaseFamilyRead();
    expect(await pending, isFalse);
    expect(api.lastFamilyMessageClientId, isNull);
  });
}

class _ExpiredApi extends FakeApi {
  @override
  Future<AppUser> currentUser() async => throw const ApiException('登入已過期', statusCode: 401);
}

class _GenerationApi extends FakeApi {
  Completer<List<CareTask>>? _blockedTasks;
  bool blockNextTaskLoad = false;

  @override
  Future<List<CareTask>> listTasks() {
    if (blockNextTaskLoad) {
      blockNextTaskLoad = false;
      _blockedTasks = Completer<List<CareTask>>();
      return _blockedTasks!.future;
    }
    return super.listTasks();
  }

  void releaseBlockedTaskLoad() {
    _blockedTasks?.complete(const <CareTask>[]);
    _blockedTasks = null;
  }
}

class _DelayedFamilyStore extends MemoryLocalStore {
  Completer<String?>? _familyRead;

  @override
  Future<String?> read(String key) {
    if (key.startsWith(SessionStore.familyMessageIdPrefix)) {
      _familyRead ??= Completer<String?>();
      return _familyRead!.future;
    }
    return super.read(key);
  }

  void releaseFamilyRead() {
    _familyRead?.complete(null);
    _familyRead = null;
  }
}
