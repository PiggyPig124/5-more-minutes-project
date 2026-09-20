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
  final Map<String, String> drafts = {};
  final List<ActionProposal> pendingActions = [];
  final Set<String> sendingConversationIds = <String>{};
  final Set<String> loadingConversationIds = <String>{};
  final Set<String> updatingTaskIds = <String>{};
  final Set<String> updatingActionIds = <String>{};
  final Map<String, String> _messageClientIds = <String, String>{};
  final Map<String, String> _draftClientIds = <String, String>{};
  final Map<String, String> _actionClientIds = <String, String>{};
  Future<void>? _initialization;
  int _sessionGeneration = 0;

  bool get isSignedIn => session != null;
  AppUser? get user => session?.user;
  bool get isElder => user?.role == UserRole.elder;
  bool get isCaregiver => user?.role == UserRole.caregiver;

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
      pendingActions.clear();
      drafts.clear();
      _draftClientIds.clear();
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
      final results = await Future.wait<Object?>([
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
      if (results.isNotEmpty) tasks = results[0] as List<CareTask>;
      if (results.length > 1) invitations = results[1] as List<FamilyInvitation>;
      if (results.length > 2) links = results[2] as List<FamilyInvitation>;
      if (isElder && results.length > 3) {
        conversations = results[3] as List<Conversation>;
        await _restorePendingActions(conversations, generation);
      } else if (isCaregiver) {
        conversations = const [];
        pendingActions.clear();
      }
      if (errors.isNotEmpty) errorMessage = errors.first;
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

  Future<bool> createInvitation(String email) async {
    if (email.trim().isEmpty) return false;
    loading = true;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final invitation = await api.createInvitation(email: email.trim());
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
