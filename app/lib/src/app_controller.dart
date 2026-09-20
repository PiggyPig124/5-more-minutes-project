import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'models.dart';
import 'storage.dart';

class AppController extends ChangeNotifier {
  AppController({required this.api, required this.sessionStore});

  final AnxinApi api;
  final SessionStore sessionStore;

  AuthSession? session;
  bool initialized = false;
  bool loading = false;
  String? errorMessage;
  List<Conversation> conversations = const [];
  final Map<String, List<ChatMessage>> messagesByConversation = {};
  List<CareTask> tasks = const [];
  List<FamilyInvitation> invitations = const [];
  List<FamilyInvitation> links = const [];
  List<MemoryRecord> memories = const [];
  List<MemoryRecord> memorySearchResults = const [];
  String? memoryRetrievalMode;
  List<StoryRecord> stories = const [];
  List<ResourceItem> resourceItems = const [];
  List<ResourceConflict> resourceConflicts = const [];
  String? resourceRetrievalMode;
  List<FamilyMessage> familyMessages = const [];
  final Map<String, String> drafts = {};
  final List<ActionProposal> pendingActions = [];
  final Set<String> sendingConversationIds = <String>{};
  final Set<String> loadingConversationIds = <String>{};
  final Set<String> updatingTaskIds = <String>{};
  final Set<String> updatingActionIds = <String>{};
  final Set<String> updatingMemoryIds = <String>{};
  final Set<String> updatingStoryIds = <String>{};
  final Set<String> _sendingFamilyMessageKeys = <String>{};
  final Map<String, String> _familyMessageClientIds = <String, String>{};
  final Map<String, String> _messageClientIds = <String, String>{};
  final Map<String, String> _draftClientIds = <String, String>{};
  final Map<String, String> _actionClientIds = <String, String>{};
  Future<void>? _initialization;
  int _sessionGeneration = 0;

  bool get isSignedIn => session != null;
  AppUser? get user => session?.user;
  bool get isElder => user?.role == UserRole.elder;
  bool get isCaregiver => user?.role == UserRole.caregiver;

  bool get _canUseFamilyMessages => links.any(
        (link) =>
            link.status == InvitationStatus.accepted && link.allowsFamilyMessages,
      );

  /// Active links with the family_messages grant are the only valid message
  /// recipients. The UI uses this list for its picker and the controller
  /// checks the id again before sending.
  List<FamilyInvitation> get familyMessageLinks => links
      .where(
        (link) =>
            link.status == InvitationStatus.accepted && link.allowsFamilyMessages,
      )
      .toList(growable: false);

  String? recipientIdFor(FamilyInvitation link) {
    if (!_canUseFamilyMessages ||
        link.status != InvitationStatus.accepted ||
        !link.allowsFamilyMessages) {
      return null;
    }
    return isElder ? link.caregiverId : link.elderId;
  }

  String familyCounterpartLabel(FamilyInvitation link) {
    final roleName = isElder ? link.caregiverName : link.elderName;
    final value = (roleName ?? link.name)?.trim();
    if (value != null && value.isNotEmpty) return value;
    return link.email.isNotEmpty ? link.email : '家庭成員';
  }

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final storedSession = await sessionStore.readSession();
      session = storedSession;
      _syncToken();
      if (storedSession != null) {
        try {
          final remoteUser = await api.currentUser();
          if (session?.accessToken == storedSession.accessToken) {
            session = AuthSession(
              accessToken: storedSession.accessToken,
              user: remoteUser,
              demoMode: storedSession.demoMode,
            );
            await sessionStore.saveSession(session!);
            _syncToken();
          }
        } on ApiException catch (error) {
          if (error.statusCode == 401 || error.statusCode == 403) {
            await sessionStore.clearSession();
            session = null;
            _syncToken();
          } else {
            errorMessage = error.message;
          }
        }
      }
      initialized = true;
      notifyListeners();
      await _refreshDemoMode(_sessionGeneration);
      if (session != null) await refreshHome(silent: true);
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  void _syncToken() {
    final restApi = api;
    if (restApi is RestApiClient) restApi.accessToken = session?.accessToken;
  }

  Future<void> _refreshDemoMode(int generation) async {
    final restApi = api;
    if (restApi is! RestApiClient || session == null) return;
    try {
      final mode = await restApi.readDemoMode();
      if (mode == null || generation != _sessionGeneration || session == null) return;
      if (session!.demoMode != mode) {
        session = AuthSession(
          accessToken: session!.accessToken,
          user: session!.user,
          demoMode: mode,
        );
        await sessionStore.saveSession(session!);
        notifyListeners();
      }
    } on ApiException {
      // Health mode is informative. A temporary health failure does not
      // invalidate an otherwise valid authenticated session.
    }
  }

  Future<bool> login({required String email, required String password}) async {
    loading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final nextSession = await api.login(email: email.trim(), password: password);
      await _setSession(nextSession);
      await _refreshDemoMode(_sessionGeneration);
      await refreshHome(silent: true);
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> register({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  }) async {
    loading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final nextSession = await api.register(
        email: email.trim(),
        password: password,
        displayName: displayName.trim(),
        role: role,
      );
      await _setSession(nextSession);
      await _refreshDemoMode(_sessionGeneration);
      await refreshHome(silent: true);
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _setSession(AuthSession nextSession) async {
    _sessionGeneration += 1;
    session = nextSession;
    _syncToken();
    await sessionStore.saveSession(nextSession);
    errorMessage = null;
    notifyListeners();
  }

  Future<void> logout() async {
    _sessionGeneration += 1;
    loading = true;
    notifyListeners();
    try {
      await api.logout();
    } on ApiException catch (error) {
      // Local credentials are still removed, while the warning makes it clear
      // that the server could not be reached.
      errorMessage = error.message;
    } finally {
      await sessionStore.clearSession();
      session = null;
      conversations = const [];
      messagesByConversation.clear();
      tasks = const [];
      invitations = const [];
      links = const [];
      memories = const [];
      memorySearchResults = const [];
      memoryRetrievalMode = null;
      stories = const [];
      resourceItems = const [];
      resourceConflicts = const [];
      resourceRetrievalMode = null;
      familyMessages = const [];
      pendingActions.clear();
      drafts.clear();
      _draftClientIds.clear();
      _familyMessageClientIds.clear();
      _sendingFamilyMessageKeys.clear();
      _syncToken();
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshHome({bool silent = false}) async {
    if (session == null) return;
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    final errors = <String>[];
    try {
      final foundation = await Future.wait<Object?>([
        api.listTasks().catchError((Object error) {
          errors.add(_messageFor(error));
          return <CareTask>[];
        }),
        api.listInvitations().catchError((Object error) {
          errors.add(_messageFor(error));
          return <FamilyInvitation>[];
        }),
        api.listLinks().catchError((Object error) {
          errors.add(_messageFor(error));
          return <FamilyInvitation>[];
        }),
        if (isElder)
          api.listConversations().catchError((Object error) {
            errors.add(_messageFor(error));
            return <Conversation>[];
          }),
      ]);
      if (generation != _sessionGeneration || session == null) return;
      tasks = foundation[0] as List<CareTask>;
      invitations = foundation[1] as List<FamilyInvitation>;
      links = foundation[2] as List<FamilyInvitation>;
      if (isElder && foundation.length > 3) {
        conversations = foundation[3] as List<Conversation>;
        await _restorePendingActions(conversations, generation);
        if (generation != _sessionGeneration || session == null) return;
      } else if (isCaregiver) {
        conversations = const [];
        pendingActions.clear();
      }

      // Personal memories and stories belong to the elder account. A
      // caregiver never requests these endpoints, even when linked.
      final personal = isElder
          ? await Future.wait<Object?>([
              api.listMemories().catchError((Object error) {
                errors.add(_messageFor(error));
                return <MemoryRecord>[];
              }),
              api.listStories().catchError((Object error) {
                errors.add(_messageFor(error));
                return <StoryRecord>[];
              }),
            ])
          : const <Object?>[];
      if (generation != _sessionGeneration || session == null) return;
      if (isElder && personal.length == 2) {
        memories = personal[0] as List<MemoryRecord>;
        stories = personal[1] as List<StoryRecord>;
      } else if (isCaregiver) {
        memories = const [];
        stories = const [];
      }

      // The family-message endpoint is scope protected. Only call it after
      // the active links have been loaded and an explicit family_messages
      // grant exists, avoiding noisy 403s for ordinary care-task links.
      if (_canUseFamilyMessages) {
        try {
          familyMessages = await api.listFamilyMessages();
        } on Object catch (error) {
          errors.add(_messageFor(error));
        }
      } else {
        familyMessages = const [];
      }
      if (errors.isNotEmpty) errorMessage = errors.first;
      notifyListeners();
    } finally {
      if (!silent) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _restorePendingActions(
    List<Conversation> restoredConversations,
    int generation,
  ) async {
    if (restoredConversations.isEmpty) {
      pendingActions.clear();
      return;
    }
    final restored = <ActionProposal>[];
    for (final conversation in restoredConversations) {
      try {
        final actions = await api.listActions(conversation.id);
        if (generation != _sessionGeneration || session == null) return;
        restored.addAll(actions);
      } on ApiException {
        // The action list is additive. A chat can still be opened if this
        // optional restore request is unavailable on an older server.
      }
    }
    if (generation == _sessionGeneration && session != null) {
      pendingActions
        ..clear()
        ..addAll({for (final action in restored) action.id: action}.values);
    }
  }

  Future<Conversation?> startConversation() async {
    if (!isElder) return null;
    final generation = _sessionGeneration;
    errorMessage = null;
    try {
      final conversation = await api.createConversation();
      if (generation != _sessionGeneration || session == null) return null;
      conversations = [conversation, ...conversations];
      messagesByConversation.putIfAbsent(conversation.id, () => <ChatMessage>[]);
      notifyListeners();
      return conversation;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<void> loadMessages(String conversationId) async {
    if (!isElder || loadingConversationIds.contains(conversationId)) return;
    final generation = _sessionGeneration;
    loadingConversationIds.add(conversationId);
    errorMessage = null;
    notifyListeners();
    try {
      final loadedMessages = await api.listMessages(conversationId);
      final loadedActions = await api.listActions(conversationId);
      if (generation != _sessionGeneration || session == null) return;
      messagesByConversation[conversationId] = loadedMessages;
      for (final action in loadedActions) {
        if (!pendingActions.any((item) => item.id == action.id)) pendingActions.add(action);
      }
    } on ApiException catch (error) {
      errorMessage = error.message;
    } finally {
      loadingConversationIds.remove(conversationId);
      notifyListeners();
    }
  }

  List<ChatMessage> messagesFor(String conversationId) =>
      messagesByConversation[conversationId] ?? const <ChatMessage>[];

  Future<String?> readDraft(String conversationId) async {
    if (drafts.containsKey(conversationId)) return drafts[conversationId];
    final value = await sessionStore.readDraft(conversationId, userId: user?.id);
    if (value != null) drafts[conversationId] = value;
    final clientId = await sessionStore.readDraftClientId(conversationId, userId: user?.id);
    if (clientId != null && clientId.isNotEmpty) _draftClientIds[conversationId] = clientId;
    return value;
  }

  Future<void> saveDraft(String conversationId, String draft) async {
    if (draft.trim().isEmpty) {
      drafts.remove(conversationId);
      _draftClientIds.remove(conversationId);
      await sessionStore.clearDraft(conversationId, userId: user?.id);
      await sessionStore.clearDraftClientId(conversationId, userId: user?.id);
      notifyListeners();
      return;
    }
    final previous = drafts[conversationId];
    drafts[conversationId] = draft;
    if (previous != draft || !_draftClientIds.containsKey(conversationId)) {
      final clientId = _newClientId('message-draft');
      _draftClientIds[conversationId] = clientId;
      await sessionStore.saveDraftClientId(conversationId, clientId, userId: user?.id);
    }
    await sessionStore.saveDraft(conversationId, draft, userId: user?.id);
    notifyListeners();
  }

  Future<bool> sendMessage({
    required String conversationId,
    required String content,
  }) async {
    if (!isElder || content.trim().isEmpty || sendingConversationIds.contains(conversationId)) {
      return false;
    }
    final trimmed = content.trim();
    final generation = _sessionGeneration;
    final key = '$conversationId::$trimmed';
    final clientMessageId = _messageClientIds.putIfAbsent(
      key,
      () => _draftClientIds[conversationId] ?? _newClientId('message'),
    );
    sendingConversationIds.add(conversationId);
    errorMessage = null;
    notifyListeners();
    try {
      final result = await api.sendMessage(
        conversationId: conversationId,
        content: trimmed,
        clientMessageId: clientMessageId,
      );
      if (generation != _sessionGeneration || session == null) return false;
      final existing = List<ChatMessage>.from(messagesFor(conversationId));
      final userMessage = result.userMessage ??
          ChatMessage(
            id: clientMessageId,
            conversationId: conversationId,
            body: trimmed,
            isFromUser: true,
            createdAt: DateTime.now(),
          );
      if (!existing.any((message) => message.id == userMessage.id)) existing.add(userMessage);
      final assistantMessage = result.assistantMessage;
      if (assistantMessage != null &&
          !existing.any((message) => message.id == assistantMessage.id)) {
        existing.add(assistantMessage);
      }
      messagesByConversation[conversationId] = existing;
      if (result.demoMode != null && session != null) {
        session = AuthSession(
          accessToken: session!.accessToken,
          user: session!.user,
          demoMode: result.demoMode!,
        );
        await sessionStore.saveSession(session!);
      }
      if (result.action != null &&
          !pendingActions.any((action) => action.id == result.action!.id)) {
        pendingActions.add(result.action!);
      }
      // An explicit "記住" request can create a server-side candidate. The
      // candidate remains unconfirmed; refreshing it here only makes the
      // review card available immediately after the chat response.
      if (assistantMessage?.candidateMemoryId != null) {
        try {
          final refreshedMemories = await api.listMemories();
          if (generation == _sessionGeneration && session != null) {
            memories = refreshedMemories;
          }
        } on ApiException {
          // The chat send already succeeded. The memory screen can retry.
        }
      }
      _messageClientIds.remove(key);
      await sessionStore.clearDraft(conversationId, userId: user?.id);
      await sessionStore.clearDraftClientId(conversationId, userId: user?.id);
      drafts.remove(conversationId);
      _draftClientIds.remove(conversationId);
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      sendingConversationIds.remove(conversationId);
      notifyListeners();
    }
  }

  Future<bool> updateTaskStatus(CareTask task, TaskStatus status) async {
    if (updatingTaskIds.contains(task.id)) return false;
    updatingTaskIds.add(task.id);
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await api.updateTask(taskId: task.id, status: status);
      if (generation != _sessionGeneration || session == null) return false;
      tasks = [
        for (final item in tasks)
          if (item.id == updated.id) updated else item,
      ];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      updatingTaskIds.remove(task.id);
      notifyListeners();
    }
  }

  Future<bool> confirmAction(ActionProposal action) async {
    if (updatingActionIds.contains(action.id)) return false;
    final clientActionId = _actionClientIds.putIfAbsent(
      action.id,
      () => _stableClientId('action', action.id),
    );
    final generation = _sessionGeneration;
    updatingActionIds.add(action.id);
    errorMessage = null;
    notifyListeners();
    try {
      final task = await api.confirmAction(
        actionId: action.id,
        clientActionId: clientActionId,
      );
      if (generation != _sessionGeneration || session == null) return false;
      pendingActions.removeWhere((item) => item.id == action.id);
      _actionClientIds.remove(action.id);
      if (task != null && !tasks.any((item) => item.id == task.id)) {
        tasks = [task, ...tasks];
      }
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      updatingActionIds.remove(action.id);
      notifyListeners();
    }
  }

  Future<bool> dismissAction(ActionProposal action) async {
    if (updatingActionIds.contains(action.id)) return false;
    updatingActionIds.add(action.id);
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      await api.dismissAction(actionId: action.id);
      if (generation != _sessionGeneration || session == null) return false;
      pendingActions.removeWhere((item) => item.id == action.id);
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      updatingActionIds.remove(action.id);
      notifyListeners();
    }
  }

  Future<bool> createInvitation(
    String email, {
    bool includeFamilyMessages = false,
  }) async {
    if (email.trim().isEmpty) return false;
    loading = true;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final invitation = await api.createInvitation(
        email: email.trim(),
        scopes: [
          'care_tasks',
          if (includeFamilyMessages) 'family_messages',
        ],
      );
      if (generation != _sessionGeneration || session == null) return false;
      invitations = [invitation, ...invitations];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> acceptInvitation(FamilyInvitation invitation, {String? token}) async {
    final invitationToken = (token ?? invitation.token ?? '').trim();
    if (invitationToken.isEmpty) {
      errorMessage = '請輸入邀請碼，服務才可以確認這個連結。';
      notifyListeners();
      return false;
    }
    loading = true;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final accepted = await api.acceptInvitation(
        invitationId: invitation.id,
        token: invitationToken,
      );
      if (generation != _sessionGeneration || session == null) return false;
      invitations = [for (final item in invitations) if (item.id != invitation.id && item.id != accepted.id) item];
      links = [accepted, ...links.where((item) => item.id != accepted.id)];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> revokeInvitation(FamilyInvitation invitation) async {
    loading = true;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      if (invitation.status == InvitationStatus.accepted) {
        await api.revokeLink(linkId: invitation.id);
      } else {
        await api.revokeInvitation(invitationId: invitation.id);
      }
      if (generation != _sessionGeneration || session == null) return false;
      invitations = [
        for (final item in invitations)
          if (item.id == invitation.id)
            FamilyInvitation(
              id: item.id,
              email: item.email,
              status: InvitationStatus.revoked,
              name: item.name,
              createdAt: item.createdAt,
              token: item.token,
              scopes: item.scopes,
              elderId: item.elderId,
              caregiverId: item.caregiverId,
              elderName: item.elderName,
              caregiverName: item.caregiverName,
            )
          else
            item,
      ];
      links = [for (final item in links) if (item.id != invitation.id) item];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshMemories({bool silent = false}) async {
    if (!isElder) return;
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await api.listMemories();
      if (generation != _sessionGeneration || session == null) return;
      memories = loaded;
      memorySearchResults = const [];
      memoryRetrievalMode = null;
      notifyListeners();
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (!silent) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<MemorySearchResult?> searchMemories(String query) async {
    if (!isElder || query.trim().isEmpty) return null;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await api.searchMemories(query: query.trim());
      if (generation != _sessionGeneration || session == null) return null;
      memorySearchResults = result.items;
      memoryRetrievalMode = result.retrievalMode;
      notifyListeners();
      return result;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<bool> createMemory({
    required String content,
    String kind = 'experience',
    String? sourceMessageId,
  }) async {
    if (!isElder || content.trim().isEmpty) return false;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final created = await api.createMemory(
        content: content.trim(),
        kind: kind,
        sourceMessageId: sourceMessageId,
      );
      if (generation != _sessionGeneration || session == null) return false;
      memories = [created, ...memories.where((memory) => memory.id != created.id)];
      memorySearchResults = [
        for (final memory in memorySearchResults)
          if (memory.id != created.id) memory,
      ];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> confirmMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    return _runMemoryUpdate(
      memory.id,
      () => api.confirmMemory(memory.id),
    );
  }

  Future<bool> editMemory(MemoryRecord memory, String content) async {
    final trimmed = content.trim();
    if (!isElder || trimmed.isEmpty || updatingMemoryIds.contains(memory.id)) {
      return false;
    }
    return _runMemoryUpdate(
      memory.id,
      () => api.updateMemory(memory.id, content: trimmed),
    );
  }

  Future<bool> suppressMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    return _runMemoryUpdate(
      memory.id,
      () => api.updateMemory(memory.id, suppressed: true),
    );
  }

  Future<bool> restoreMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    return _runMemoryUpdate(
      memory.id,
      () => api.updateMemory(memory.id, suppressed: false),
    );
  }

  Future<bool> deleteMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    final generation = _sessionGeneration;
    updatingMemoryIds.add(memory.id);
    errorMessage = null;
    notifyListeners();
    try {
      await api.deleteMemory(memory.id);
      if (generation != _sessionGeneration || session == null) return false;
      memories = [for (final item in memories) if (item.id != memory.id) item];
      memorySearchResults = [
        for (final item in memorySearchResults)
          if (item.id != memory.id) item,
      ];
      stories = [
        for (final story in stories)
          if (!story.memoryIds.contains(memory.id)) story,
      ];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      updatingMemoryIds.remove(memory.id);
      notifyListeners();
    }
  }

  Future<bool> _runMemoryUpdate(
    String memoryId,
    Future<MemoryRecord> Function() operation,
  ) async {
    final generation = _sessionGeneration;
    updatingMemoryIds.add(memoryId);
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await operation();
      if (generation != _sessionGeneration || session == null) return false;
      // Confirm/edit responses may intentionally issue a fresh memory id.
      // Remove both the submitted candidate and any returned duplicate before
      // inserting the server's canonical record.
      memories = [
        for (final item in memories)
          if (item.id != memoryId && item.id != updated.id) item,
        updated,
      ];
      memorySearchResults = [
        for (final item in memorySearchResults)
          if (item.id != memoryId && item.id != updated.id) item,
        updated,
      ];
      // A correction changes the source of any derived story; remove those
      // local cards until the server returns a newly authored story.
      stories = [
        for (final story in stories)
          if (!story.memoryIds.contains(memoryId) &&
              !story.memoryIds.contains(updated.id)) story,
      ];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      updatingMemoryIds.remove(memoryId);
      notifyListeners();
    }
  }

  Future<void> refreshStories({bool silent = false}) async {
    if (!isElder) return;
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await api.listStories();
      if (generation != _sessionGeneration || session == null) return;
      stories = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (!silent) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> createStory({
    required String title,
    required String content,
    List<String> memoryIds = const [],
  }) async {
    if (!isElder || title.trim().isEmpty || content.trim().isEmpty) return false;
    final generation = _sessionGeneration;
    loading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final created = await api.createStory(
        title: title.trim(),
        content: content.trim(),
        memoryIds: memoryIds,
      );
      if (generation != _sessionGeneration || session == null) return false;
      stories = [created, ...stories.where((story) => story.id != created.id)];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> deleteStory(StoryRecord story) async {
    if (!isElder || updatingStoryIds.contains(story.id)) return false;
    final generation = _sessionGeneration;
    updatingStoryIds.add(story.id);
    errorMessage = null;
    notifyListeners();
    try {
      await api.deleteStory(story.id);
      if (generation != _sessionGeneration || session == null) return false;
      stories = [for (final item in stories) if (item.id != story.id) item];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      updatingStoryIds.remove(story.id);
      notifyListeners();
    }
  }

  Future<ResourceSearchResult?> searchResources(String query) async {
    if (query.trim().isEmpty) return null;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await api.searchResources(query: query.trim());
      if (generation != _sessionGeneration || session == null) return null;
      resourceItems = result.items;
      resourceConflicts = result.conflicts;
      resourceRetrievalMode = result.retrievalMode;
      notifyListeners();
      return result;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<void> refreshFamilyMessages({bool silent = false}) async {
    if (!_canUseFamilyMessages) {
      familyMessages = const [];
      notifyListeners();
      return;
    }
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await api.listFamilyMessages();
      if (generation != _sessionGeneration || session == null) return;
      familyMessages = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (!silent) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> sendFamilyMessage({
    required FamilyInvitation link,
    required String content,
    StoryRecord? sourceStory,
  }) async {
    final recipientId = recipientIdFor(link);
    final trimmed = content.trim();
    if (recipientId == null || trimmed.isEmpty) {
      errorMessage = '這位家庭成員尚未授權家庭訊息。';
      notifyListeners();
      return false;
    }
    final generation = _sessionGeneration;
    final senderUserId = user?.id;
    if (senderUserId == null || senderUserId.isEmpty) return false;
    final operationKey = '$recipientId::${sourceStory?.id ?? ''}::$trimmed';
    if (_sendingFamilyMessageKeys.contains(operationKey)) return false;
    _sendingFamilyMessageKeys.add(operationKey);
    var clientMessageId = _familyMessageClientIds[operationKey];
    clientMessageId ??= await sessionStore.readFamilyMessageClientId(
      recipientId: recipientId,
      sourceStoryId: sourceStory?.id,
      content: trimmed,
      userId: senderUserId,
    );
    if (generation != _sessionGeneration || session?.user.id != senderUserId) {
      _sendingFamilyMessageKeys.remove(operationKey);
      return false;
    }
    clientMessageId ??= _newClientId('family-message');
    _familyMessageClientIds[operationKey] = clientMessageId;
    await sessionStore.saveFamilyMessageClientId(
      recipientId: recipientId,
      sourceStoryId: sourceStory?.id,
      content: trimmed,
      clientId: clientMessageId,
      userId: senderUserId,
    );
    if (generation != _sessionGeneration || session?.user.id != senderUserId) {
      _sendingFamilyMessageKeys.remove(operationKey);
      return false;
    }
    errorMessage = null;
    loading = true;
    notifyListeners();
    try {
      final message = await api.sendFamilyMessage(
        recipientId: recipientId,
        content: trimmed,
        clientMessageId: clientMessageId,
        sourceStoryId: sourceStory?.id,
      );
      if (generation != _sessionGeneration || session == null) return false;
      familyMessages = [
        ...familyMessages.where((item) => item.id != message.id),
        message,
      ];
      _familyMessageClientIds.remove(operationKey);
      await sessionStore.clearFamilyMessageClientId(
        recipientId: recipientId,
        sourceStoryId: sourceStory?.id,
        content: trimmed,
        userId: senderUserId,
      );
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      // Keep the operation id so a retry is idempotent after a timeout or
      // transient 5xx response.
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      _sendingFamilyMessageKeys.remove(operationKey);
      loading = false;
      notifyListeners();
    }
  }

  static String _newClientId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';

  static String _stableClientId(String prefix, String value) {
    // FNV-1a keeps retry keys stable across app restarts, while avoiding a
    // timestamp that would make a network retry look like a new operation.
    var hash = 2166136261;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return '$prefix-${hash.toRadixString(16)}';
  }

  static String _messageFor(Object error) {
    if (error is ApiException) return error.message;
    return '資料暫時未能更新，請稍後重試。';
  }
}
