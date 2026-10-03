import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/reminders.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'dart:async';

import 'helpers.dart';

void main() {
  test('old refresh cannot restore conversations after reminder sync', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final api = _GenerationApi();
    final scheduler = _BlockingReminderScheduler();
    final controller = AppController(
      api: api,
      sessionStore: SessionStore(MemoryLocalStore()),
      reminderScheduler: scheduler,
    );
    expect(await controller.login(email: 'first@example.com', password: 'pw'),
        isTrue);

    api.fakeConversations.add(const Conversation(
      id: 'old-conversation', title: 'Previous account private chat'));
    scheduler.blockNextSync = true;
    final staleRefresh = controller.refreshHome();
    await scheduler.syncStarted.future;
    await controller.logout();
    api.fakeConversations.clear();
    expect(await controller.login(email: 'second@example.com', password: 'pw'),
        isTrue);

    api.blockNextTaskLoad = true;
    final currentRefresh = controller.refreshHome();
    await Future<void>.delayed(Duration.zero);
    scheduler.releaseSync();
    await staleRefresh;
    expect(controller.conversations, isEmpty);
    expect(controller.loading, isTrue);
    api.releaseBlockedTaskLoad();
    await currentRefresh;
    expect(controller.loading, isFalse);
  });

  test('late family messages cannot reappear after account switch', () async {
    final api = _DelayedFamilyListApi()
      ..fakeLinks.add(const FamilyInvitation(
        id: 'link-1',
        email: 'caregiver@example.com',
        status: InvitationStatus.accepted,
        scopes: ['family_messages'],
        elderId: 'elder-1',
        caregiverId: 'caregiver-1',
      ));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(await controller.login(email: 'elder@example.com', password: 'pw'),
        isTrue);

    api.blockNextFamilyList = true;
    final staleRefresh = controller.refreshHome();
    await api.familyListStarted.future;
    await controller.logout();
    api.fakeLinks.clear();
    api.role = UserRole.caregiver;
    expect(await controller.login(email: 'caregiver@example.com', password: 'pw'),
        isTrue);

    api.releaseFamilyList([
      const FamilyMessage(
        id: 'old-message',
        senderId: 'elder-1',
        recipientId: 'caregiver-1',
        content: 'Private message from previous account',
      ),
    ]);
    await staleRefresh;
    expect(controller.familyMessages, isEmpty);
  });

  test('late memory consent cannot overwrite a new account', () async {
    final api = _DelayedConsentApi();
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(await controller.login(email: 'elder@example.com', password: 'pw'),
        isTrue);

    api.blockNextConsentRead = true;
    final staleRefresh = controller.refreshHome();
    await api.consentReadStarted.future;
    await controller.logout();
    api.role = UserRole.caregiver;
    expect(await controller.login(email: 'caregiver@example.com', password: 'pw'),
        isTrue);

    api.releaseConsentRead(true);
    await staleRefresh;
    expect(controller.memoryConsentEnabled, isFalse);
  });

  test('a slower community search cannot replace the newer filter result',
      () async {
    final api = _CommunitySearchApi();
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));

    final olderSearch = controller.searchCommunity(topic: 'gardening');
    await controller.searchCommunity(topic: 'tailoring', area: '觀塘');
    api.gardeningSearch.complete(const CommunitySearchResult<CommunityActivity>(
      items: [CommunityActivity(id: 'old', title: 'Gardening')],
      searchState: 'live',
    ));
    await olderSearch;

    expect(controller.communityTopic, 'tailoring');
    expect(controller.communityArea, '觀塘');
    expect(controller.communityActivities.single.id, 'new');
    expect(controller.communitySearchLoading, isFalse);
  });

  test('failed send preserves local draft and retry reuses message id',
      () async {
    final api = FakeApi();
    final store = MemoryLocalStore();
    final controller =
        AppController(api: api, sessionStore: SessionStore(store));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    final conversation = await controller.startConversation();
    expect(conversation, isNotNull);
    await controller.saveDraft(conversation!.id, '我今晚想早一點休息');

    api.failSend = true;
    expect(
        await controller.sendMessage(
            conversationId: conversation.id, content: '我今晚想早一點休息'),
        isFalse);
    final firstClientId = api.lastMessageClientId;
    expect(firstClientId, isNotNull);
    expect(await controller.readDraft(conversation.id), '我今晚想早一點休息');

    api.failSend = false;
    expect(
        await controller.sendMessage(
            conversationId: conversation.id, content: '我今晚想早一點休息'),
        isTrue);
    expect(api.lastMessageClientId, firstClientId);
    expect(await controller.readDraft(conversation.id), isNull);
  });

  test('sending the same text again after success creates a new operation id',
      () async {
    final api = FakeApi();
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    final conversation = await controller.startConversation();
    expect(conversation, isNotNull);

    expect(
        await controller.sendMessage(
            conversationId: conversation!.id, content: '早晨好'),
        isTrue);
    final firstId = api.lastMessageClientId;
    expect(
        await controller.sendMessage(
            conversationId: conversation.id, content: '早晨好'),
        isTrue);
    expect(api.lastMessageClientId, isNot(firstId));
  });

  test('a failed draft retry after controller recreation keeps its client id',
      () async {
    final store = MemoryLocalStore();
    final firstApi = FakeApi();
    final first =
        AppController(api: firstApi, sessionStore: SessionStore(store));
    expect(
        await first.login(email: 'elder@example.com', password: 'password123'),
        isTrue);
    final conversation = await first.startConversation();
    expect(conversation, isNotNull);
    await first.saveDraft(conversation!.id, '請提醒我覆診');
    firstApi.failSend = true;
    expect(
        await first.sendMessage(
            conversationId: conversation.id, content: '請提醒我覆診'),
        isFalse);
    final originalId = firstApi.lastMessageClientId;

    final secondApi = FakeApi()..failSend = true;
    final second =
        AppController(api: secondApi, sessionStore: SessionStore(store));
    await second.initialize();
    expect(await second.readDraft(conversation.id), '請提醒我覆診');
    expect(
        await second.sendMessage(
            conversationId: conversation.id, content: '請提醒我覆診'),
        isFalse);
    expect(secondApi.lastMessageClientId, originalId);
  });

  test(
      'confirming the same action through the controller removes preview only after success',
      () async {
    final api = FakeApi()
      ..fakeAction = const ActionProposal(
          id: 'action-1',
          kind: ActionKind.task,
          title: '提醒覆診',
          description: '星期五上午十時');
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    final conversation = await controller.startConversation();
    expect(conversation, isNotNull);
    expect(
        await controller.sendMessage(
            conversationId: conversation!.id, content: '請記住覆診'),
        isTrue);
    expect(controller.pendingActions, hasLength(1));
    final action = controller.pendingActions.single;
    expect(await controller.confirmAction(action), isTrue);
    expect(controller.pendingActions, isEmpty);
    expect(api.actionConfirmations, 1);
    expect(api.lastActionClientId, isNotNull);
  });

  test('stored token is validated before restoring an authenticated screen',
      () async {
    final store = MemoryLocalStore();
    final sessionStore = SessionStore(store);
    await sessionStore.saveSession(
      const AuthSession(
        accessToken: 'expired-token',
        user: AppUser(
            id: 'old',
            displayName: '舊帳戶',
            email: 'old@example.com',
            role: UserRole.elder),
      ),
    );
    final controller =
        AppController(api: _ExpiredApi(), sessionStore: sessionStore);
    await controller.initialize();
    expect(controller.session, isNull);
    expect(await store.read(SessionStore.tokenKey), isNull);
  });

  test('a response from a previous account cannot repopulate the next account',
      () async {
    final api = _GenerationApi();
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    api.fakeTasks.add(const CareTask(
        id: 'elder-only',
        title: '長者私有項目',
        description: '',
        status: TaskStatus.pending));
    api.blockNextTaskLoad = true;
    final staleRefresh = controller.refreshHome();
    await Future<void>.delayed(Duration.zero);

    await controller.logout();
    api.fakeTasks.clear();
    api.role = UserRole.caregiver;
    expect(
        await controller.login(
            email: 'caregiver@example.com', password: 'password123'),
        isTrue);
    api.releaseBlockedTaskLoad();
    await staleRefresh;

    expect(controller.user?.role, UserRole.caregiver);
    expect(controller.tasks.where((task) => task.id == 'elder-only'), isEmpty);
  });

  test(
      'memories remain explicit candidates and destructive changes retract local stories',
      () async {
    final api = FakeApi();
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    expect(api.fakeMemories, isEmpty);
    expect(
        await controller.sendMessage(
            conversationId: (await controller.startConversation())!.id,
            content: '我今日心情很好'),
        isTrue);
    expect(api.fakeMemories, isEmpty);

    expect(
        await controller.createMemory(
            content: '我喜歡在公園散步', kind: 'conversation'),
        isTrue);
    final candidate = controller.memories.single;
    expect(candidate.isCandidate, isTrue);
    expect(await controller.confirmMemory(candidate), isTrue);
    expect(controller.memories.single.isConfirmed, isTrue);

    final story = await api.createStory(
        title: '我的習慣',
        content: '我喜歡在公園散步',
        memoryIds: [controller.memories.single.id]);
    controller.stories = [story];
    expect(
        await controller.editMemory(controller.memories.single, '我喜歡早上在公園散步'),
        isTrue);
    expect(controller.stories, isEmpty);
    expect(await controller.deleteMemory(controller.memories.single), isTrue);
    expect(controller.memories, isEmpty);
  });

  test(
      'family message review operation retries with the same id then clears it after success',
      () async {
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
    final controller =
        AppController(api: api, sessionStore: SessionStore(store));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    final link = controller.familyMessageLinks.single;
    api.failFamilyMessageSend = true;
    expect(await controller.sendFamilyMessage(link: link, content: '記得飲水'),
        isFalse);
    final firstId = api.lastFamilyMessageClientId;
    expect(firstId, isNotNull);

    api.failFamilyMessageSend = false;
    expect(await controller.sendFamilyMessage(link: link, content: '記得飲水'),
        isTrue);
    expect(api.lastFamilyMessageClientId, firstId);
    expect(controller.familyMessages, hasLength(1));

    expect(await controller.sendFamilyMessage(link: link, content: '記得飲水'),
        isTrue);
    expect(api.lastFamilyMessageClientId, isNot(firstId));
    expect(controller.familyMessages, hasLength(2));
  });

  test('a delayed family message storage read cannot send after account switch',
      () async {
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
    final controller =
        AppController(api: api, sessionStore: SessionStore(store));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    final pending = controller.sendFamilyMessage(
        link: controller.familyMessageLinks.single, content: '只應該屬於舊帳戶');
    await Future<void>.delayed(Duration.zero);
    await controller.logout();
    api.role = UserRole.caregiver;
    expect(
        await controller.login(
            email: 'caregiver@example.com', password: 'password123'),
        isTrue);
    store.releaseFamilyRead();
    expect(await pending, isFalse);
    expect(api.lastFamilyMessageClientId, isNull);
  });

  test(
      'ending a guest session clears local transcript and ignores a late reply',
      () async {
    final api = _GuestRaceApi();
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(await controller.startGuestSession(), isTrue);
    final sending = controller.sendGuestMessage('請問附近有甚麼活動');
    await Future<void>.delayed(Duration.zero);
    expect(controller.guestMessages, hasLength(1));
    await controller.endGuestSession();
    api.pendingReply
        .complete(const GuestReply(content: '舊回覆', mode: 'deterministic_demo'));
    expect(await sending, isFalse);
    expect(controller.guestSession, isNull);
    expect(controller.guestMessages, isEmpty);
    expect(api.deletedSessions, 1);
  });

  test('late memory save response cannot repopulate another account', () async {
    final api = _DelayedMemorySaveApi();
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
    expect(
        await controller.login(
            email: 'elder@example.com', password: 'password123'),
        isTrue);
    expect(await controller.setMemoryConsent(true), isTrue);
    final suggestion = ChatMessage(
      id: 'assistant-message',
      conversationId: 'conversation',
      body: '你有種花經驗。',
      isFromUser: false,
      createdAt: DateTime.now(),
      metadata: const {
        'memory_suggestion': {
          'content': '我照顧過花園',
          'kind': 'experience',
          'source_message_id': 'user-message'
        }
      },
    );
    final saving = controller.saveSuggestedMemory(suggestion);
    await Future<void>.delayed(Duration.zero);
    await controller.logout();
    api.role = UserRole.caregiver;
    expect(
        await controller.login(
            email: 'caregiver@example.com', password: 'password123'),
        isTrue);
    api.pendingSave.complete(const MemoryRecord(
        id: 'old-elder-memory',
        content: '我照顧過花園',
        kind: 'experience',
        status: 'confirmed'));
    expect(await saving, isFalse);
    expect(controller.user?.role, UserRole.caregiver);
    expect(controller.memories, isEmpty);
    expect(controller.memoryConsentEnabled, isFalse);
  });
}

class _CommunitySearchApi extends FakeApi implements CommunityApi {
  final gardeningSearch = Completer<CommunitySearchResult<CommunityActivity>>();

  @override
  Future<List<CommunityActivity>> listCommunityActivities() async => const [];

  @override
  Future<CommunitySearchResult<CommunityActivity>> searchCommunityActivities(
      {String? topic, String? area}) async {
    if (topic == 'gardening') return gardeningSearch.future;
    return const CommunitySearchResult<CommunityActivity>(
      items: [CommunityActivity(id: 'new', title: 'Tailoring')],
      searchState: 'live',
    );
  }

  @override
  Future<List<SkillSuggestion>> listSkillSuggestions() async => const [];

  @override
  Future<SkillSuggestion> decideSkill(String id,
          {required String decision, String? skill}) async =>
      SkillSuggestion(id: id, suggestion: skill ?? 'skill', status: decision);

  @override
  Future<List<CommunityOpportunity>> listOpportunities(String skillId) async =>
      const [];

  @override
  Future<CommunitySearchResult<CommunityOpportunity>> searchOpportunities(
          String skillId) async =>
      const CommunitySearchResult<CommunityOpportunity>(items: []);
}

class _ExpiredApi extends FakeApi {
  @override
  Future<AppUser> currentUser() async =>
      throw const ApiException('登入已過期', statusCode: 401);
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

class _BlockingReminderScheduler extends ReminderScheduler {
  bool blockNextSync = false;
  final Completer<void> syncStarted = Completer<void>();
  Completer<void>? _blockedSync;

  @override
  Future<void> syncDueTasks(String userId, List<CareTask> tasks) {
    if (blockNextSync) {
      blockNextSync = false;
      _blockedSync = Completer<void>();
      syncStarted.complete();
      return _blockedSync!.future;
    }
    return Future<void>.value();
  }

  @override
  Future<void> cancelUserNotifications(String userId) async {}

  void releaseSync() => _blockedSync!.complete();
}

class _DelayedFamilyListApi extends FakeApi {
  bool blockNextFamilyList = false;
  final Completer<void> familyListStarted = Completer<void>();
  Completer<List<FamilyMessage>>? _blockedFamilyMessages;

  @override
  Future<List<FamilyMessage>> listFamilyMessages() {
    if (blockNextFamilyList) {
      blockNextFamilyList = false;
      _blockedFamilyMessages = Completer<List<FamilyMessage>>();
      familyListStarted.complete();
      return _blockedFamilyMessages!.future;
    }
    return super.listFamilyMessages();
  }

  void releaseFamilyList(List<FamilyMessage> messages) {
    _blockedFamilyMessages!.complete(messages);
  }
}

class _DelayedConsentApi extends FakeApi implements ConsentApi {
  bool blockNextConsentRead = false;
  final Completer<void> consentReadStarted = Completer<void>();
  Completer<bool>? _blockedConsent;

  @override
  Future<bool> getMemoryConsent() {
    if (blockNextConsentRead) {
      blockNextConsentRead = false;
      _blockedConsent = Completer<bool>();
      consentReadStarted.complete();
      return _blockedConsent!.future;
    }
    return Future<bool>.value(false);
  }

  @override
  Future<bool> setMemoryConsent(bool enabled) async => enabled;

  void releaseConsentRead(bool enabled) => _blockedConsent!.complete(enabled);
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

class _GuestRaceApi extends FakeApi implements GuestApi {
  final Completer<GuestReply> pendingReply = Completer<GuestReply>();
  int deletedSessions = 0;
  @override
  Future<GuestSession> startGuestSession() async =>
      GuestSession(id: 'guest-session');
  @override
  Future<GuestReply> sendGuestMessage(String sessionId, String content) =>
      pendingReply.future;
  @override
  Future<void> endGuestSession(String sessionId) async {
    deletedSessions += 1;
  }
}

class _DelayedMemorySaveApi extends FakeApi
    implements ConsentApi, MemorySaveApi {
  bool consentEnabled = false;
  final Completer<MemoryRecord> pendingSave = Completer<MemoryRecord>();
  @override
  Future<bool> getMemoryConsent() async => consentEnabled;
  @override
  Future<bool> setMemoryConsent(bool enabled) async => consentEnabled = enabled;
  @override
  Future<MemoryRecord> saveConfirmedMemory(
          {required String content,
          required String kind,
          String? sourceMessageId,
          String? topicKey}) =>
      pendingSave.future;
}
