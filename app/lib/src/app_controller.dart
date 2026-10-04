import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'models.dart';
import 'reminders.dart';
import 'storage.dart';

class MemoryDeletionPreview {
  MemoryDeletionPreview._(
      {required this.ownerId,
      required this.sessionGeneration,
      required this.revision,
      required this.mode,
      required List<String> memoryIds,
      required this.idempotencyKey,
      required Map<String, int> counts})
      : memoryIds = List.unmodifiable(memoryIds),
        counts = Map.unmodifiable(counts);
  final String ownerId;
  final int sessionGeneration;
  final int revision;
  final String mode;
  final List<String> memoryIds;
  final String idempotencyKey;
  final Map<String, int> counts;
}

class MemoryCardDraft {
  MemoryCardDraft._(
      {required this.ownerId,
      required this.sessionGeneration,
      required this.mutationGeneration,
      required this.revision,
      this.storyId,
      required this.title,
      required this.content,
      required List<String> memoryIds,
      required AppController controller,
      required AuthSession session,
      bool manualComposition = false})
      : memoryIds = List.unmodifiable(memoryIds),
        _controller = controller,
        _session = session,
        _manualComposition = manualComposition,
        _currentMutationGeneration = mutationGeneration;
  final String ownerId;
  final int sessionGeneration;
  final int mutationGeneration;
  final int revision;
  final String? storyId;
  final String title;
  final String content;
  final List<String> memoryIds;
  final AppController _controller;
  final AuthSession _session;
  final bool _manualComposition;
  int _currentMutationGeneration;
  bool _saved = false;
}

class AppController extends ChangeNotifier {
  AppController({
    required this.api,
    required this.sessionStore,
    this.reminderScheduler,
  });

  final AnxinApi api;
  final SessionStore sessionStore;
  final ReminderScheduler? reminderScheduler;

  AuthSession? session;
  bool initialized = false;
  bool loading = false;
  String? errorMessage;
  List<Conversation> conversations = const [];
  final Map<String, List<ChatMessage>> messagesByConversation = {};
  List<CareTask> tasks = const [];
  final Map<String, CareTask> taskDetails = {};
  final Set<String> loadingTaskDetailIds = {};
  final Map<String, String> taskDetailErrors = {};
  final Map<String, int> _taskDetailRequests = {};
  final Map<String, CareTask> taskSharePreviews = {};
  final Map<String, List<TaskShare>> taskSharesByTask = {};
  final Set<String> sharingTaskIds = {};
  final Set<String> revokingTaskShareIds = {};
  String? taskSharingError;
  final Map<String, String> _taskShareRetryKeys = {};
  final Map<String, int> _taskPreviewRequests = {};
  final Map<String, int> _taskShareHistoryRequests = {};
  int _taskSharingGeneration = 0;
  int _taskRefreshGeneration = 0;
  int _taskSharingSequence = 0;

  bool get supportsFamilyConnections => api is FamilyConnectionApi;
  bool get familyAuthorizationUncertain => _familyAccessUncertain;
  List<FamilyConnectionRequest> familyConnectionRequests = const [];
  List<FamilyBlock> familyBlocks = const [];
  List<FamilyMessage> sentFamilyMessages = const [];
  bool familyConnectionBusy = false;
  String? familyConnectionError;
  int familyConnectionGeneration = 0;
  int _familyReadGeneration = 0;
  bool _familyAccessUncertain = false;
  final Map<String, String> _familyOperationKeys = {};
  final Map<String, Object> _familyRetryTargets = {};

  bool _familyCurrent(int sessionGeneration, int pairGeneration) =>
      session != null &&
      sessionGeneration == _sessionGeneration &&
      pairGeneration == familyConnectionGeneration;

  void _invalidateFamilyAccess() {
    ++familyConnectionGeneration;
    ++_familyReadGeneration;
    _familyAccessUncertain = true;
    loading = false;
    links = const [];
    invitations = const [];
    familyMessages = const [];
    sentFamilyMessages = const [];
    _resetTaskSharing();
    tasks = tasks
        .where((task) =>
            task.ownerId == user?.id ||
            (isElder && task.ownerId == null && !task.isReadOnly))
        .toList();
    _familyMessageClientIds.clear();
    _sendingFamilyMessageKeys.clear();
    _memoryCardSave = null;
    ++_memoryMutationGeneration;
    if (user != null && reminderScheduler != null) {
      unawaited(reminderScheduler!
          .cancelUserNotifications(user!.id)
          .catchError((Object _) {}));
    }
  }

  void _resetFamilyConnections() {
    _invalidateFamilyAccess();
    _familyAccessUncertain = false;
    familyConnectionRequests = const [];
    familyBlocks = const [];
    familyConnectionBusy = false;
    familyConnectionError = null;
    _familyOperationKeys.clear();
    _familyRetryTargets.clear();
  }

  Future<void> refreshFamilyConnections({bool silent = true}) async {
    if (!supportsFamilyConnections || session == null || familyConnectionBusy) {
      return;
    }
    final generation = _sessionGeneration;
    final pair = familyConnectionGeneration;
    final read = ++_familyReadGeneration;
    final capability = api as FamilyConnectionApi;
    if (!silent) familyConnectionError = null;
    try {
      final values = await Future.wait<Object>([
        capability.listConnectionRequests(),
        isElder ? capability.listFamilyBlocks() : Future.value(<FamilyBlock>[]),
        capability.listSentFamilyMessages(),
        api.listInvitations(),
        api.listLinks(),
      ]);
      if (!_familyCurrent(generation, pair) ||
          read != _familyReadGeneration ||
          familyConnectionBusy) {
        return;
      }
      final freshLinks = values[4] as List<FamilyInvitation>;
      if (_familyAuthorizationSignature(links) !=
          _familyAuthorizationSignature(freshLinks)) {
        _invalidateFamilyAccess();
      }
      familyConnectionRequests = values[0] as List<FamilyConnectionRequest>;
      familyBlocks = values[1] as List<FamilyBlock>;
      sentFamilyMessages = values[2] as List<FamilyMessage>;
      invitations = values[3] as List<FamilyInvitation>;
      links = values[4] as List<FamilyInvitation>;
      _familyAccessUncertain = false;
      familyConnectionError = null;
      notifyListeners();
    } on Object catch (error) {
      if (!_familyCurrent(generation, pair) || read != _familyReadGeneration) {
        return;
      }
      familyConnectionError = _messageFor(error);
    }
    if (_familyCurrent(generation, pair) && read == _familyReadGeneration) {
      notifyListeners();
    }
  }

  Future<bool> _mutateFamily(
      String fingerprint, Future<Object> Function(String key) action,
      {Object? target}) async {
    if (!supportsFamilyConnections || session == null || familyConnectionBusy) {
      return false;
    }
    final generation = _sessionGeneration;
    final actor = user!.id;
    final key = _familyOperationKeys.putIfAbsent(
        fingerprint, () => _newClientId('family-operation'));
    if (target != null) _familyRetryTargets[fingerprint] = target;
    _invalidateFamilyAccess();
    final pair = familyConnectionGeneration;
    familyConnectionBusy = true;
    familyConnectionError = null;
    notifyListeners();
    try {
      await action(key);
      if (!_familyCurrent(generation, pair) || user?.id != actor) return false;
      _familyOperationKeys.remove(fingerprint);
      _familyRetryTargets.remove(fingerprint);
      return true;
    } on Object catch (error) {
      if (!_familyCurrent(generation, pair) || user?.id != actor) return false;
      familyConnectionError = _messageFor(error);
      return false;
    } finally {
      if (_familyCurrent(generation, pair) && user?.id == actor) {
        familyConnectionBusy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> requestFamilyConnection(String elderEmail) async {
    final email = elderEmail.trim().toLowerCase();
    if (!isCaregiver ||
        !email.contains('@') ||
        email == user?.email.toLowerCase()) {
      return false;
    }
    final result = await _mutateFamily(
        'request:$email',
        (key) => (api as FamilyConnectionApi)
            .createConnectionRequest(elderEmail: email, clientRequestId: key));
    if (result) await refreshFamilyConnections();
    return result;
  }

  bool _currentRequest(FamilyConnectionRequest request, String operation,
      {bool pending = true}) {
    final fingerprint = '$operation:${request.id}:${request.version}';
    final retained = _familyAccessUncertain &&
        identical(_familyRetryTargets[fingerprint], request);
    return request.id.isNotEmpty &&
        request.elderId.isNotEmpty &&
        request.caregiverId.isNotEmpty &&
        (request.version ?? 0) > 0 &&
        (!pending || request.actionable) &&
        (retained ||
            (!_familyAccessUncertain &&
                familyConnectionRequests
                    .any((item) => identical(item, request))));
  }

  Future<bool> approveFamilyConnection(
      FamilyConnectionRequest request, List<String> scopes) async {
    final selected = scopes.toSet().toList()..sort();
    if (!isElder ||
        request.elderId != user?.id ||
        selected.isEmpty ||
        selected.any(
            (scope) => scope != 'care_tasks' && scope != 'family_messages') ||
        !_currentRequest(request, 'approve:${selected.join(',')}')) {
      return false;
    }
    final result = await _mutateFamily(
        'approve:${selected.join(',')}:${request.id}:${request.version}',
        (_) => (api as FamilyConnectionApi).approveConnectionRequest(
            requestId: request.id,
            expectedVersion: request.version!,
            scopes: selected),
        target: request);
    if (result) await refreshFamilyConnections();
    return result;
  }

  Future<bool> rejectFamilyConnection(FamilyConnectionRequest request) async {
    if (!isElder ||
        request.elderId != user?.id ||
        !_currentRequest(request, 'reject')) {
      return false;
    }
    final result = await _mutateFamily(
        'reject:${request.id}:${request.version}',
        (_) => (api as FamilyConnectionApi).rejectConnectionRequest(
            requestId: request.id, expectedVersion: request.version!),
        target: request);
    if (result) await refreshFamilyConnections();
    return result;
  }

  Future<bool> withdrawFamilyConnection(FamilyConnectionRequest request) async {
    if (!isCaregiver ||
        request.caregiverId != user?.id ||
        !_currentRequest(request, 'withdraw')) {
      return false;
    }
    final result = await _mutateFamily(
        'withdraw:${request.id}:${request.version}',
        (_) => (api as FamilyConnectionApi).withdrawConnectionRequest(
            requestId: request.id, expectedVersion: request.version!),
        target: request);
    if (result) await refreshFamilyConnections();
    return result;
  }

  bool _authorizedLink(FamilyInvitation link) =>
      link.actionable &&
      (isElder ? link.elderId == user?.id : link.caregiverId == user?.id);

  String _familyAuthorizationSignature(List<FamilyInvitation> values) {
    final signatures = values
        .map((link) =>
            '${link.id}:${link.elderId}:${link.caregiverId}:${link.status}:${link.authorizationEpoch}:${(List<String>.of(link.scopes)..sort()).join(',')}')
        .toList()
      ..sort();
    return signatures.join('|');
  }

  Future<bool> blockFamilyConnection(
      {FamilyConnectionRequest? request, FamilyInvitation? link}) async {
    if (!isElder || (request == null) == (link == null)) return false;
    final caregiver = request?.caregiverId ?? link!.caregiverId ?? '';
    final fingerprint =
        'block:$caregiver:${request?.id ?? ''}:${link?.id ?? ''}:${request?.version ?? link?.authorizationEpoch}';
    final source = request ?? link!;
    final retained = _familyAccessUncertain &&
        identical(_familyRetryTargets[fingerprint], source);
    if (caregiver.isEmpty ||
        caregiver == user?.id ||
        (request != null &&
            (request.elderId != user?.id ||
                request.id.isEmpty ||
                (request.version ?? 0) < 1 ||
                request.status == FamilyRequestStatus.unknown)) ||
        (link != null &&
            !(link.id.trim().isNotEmpty &&
                (link.authorizationEpoch ?? 0) > 0 &&
                link.elderId == user?.id &&
                (link.caregiverId?.trim().isNotEmpty ?? false) &&
                (link.status == InvitationStatus.accepted ||
                    link.status == InvitationStatus.revoked))) ||
        (!retained &&
            (_familyAccessUncertain ||
                (request != null
                    ? !familyConnectionRequests
                        .any((item) => identical(item, request))
                    : !links.any((item) => identical(item, link)))))) {
      return false;
    }
    final result = await _mutateFamily(
        fingerprint,
        (key) => (api as FamilyConnectionApi).blockFamilyPair(
            caregiverId: caregiver,
            requestId: request?.id,
            linkId: link?.id,
            clientOperationId: key),
        target: source);
    if (result) await refreshFamilyConnections();
    return result;
  }

  Future<bool> unblockFamilyConnection(FamilyBlock block) async {
    final fingerprint =
        'unblock:${block.elderId}:${block.caregiverId}:${block.version}';
    if (!isElder ||
        block.elderId != user?.id ||
        !block.actionable ||
        block.active != true ||
        (!(_familyAccessUncertain &&
                identical(_familyRetryTargets[fingerprint], block)) &&
            (_familyAccessUncertain ||
                !familyBlocks.any((item) => identical(item, block))))) {
      return false;
    }
    final result = await _mutateFamily(
        fingerprint,
        (key) => (api as FamilyConnectionApi).unblockFamilyPair(
            caregiverId: block.caregiverId,
            expectedVersion: block.version!,
            clientOperationId: key),
        target: block);
    if (result) await refreshFamilyConnections();
    return result;
  }

  List<FamilyInvitation> invitations = const [];
  List<FamilyInvitation> links = const [];
  List<MemoryRecord> memories = const [];
  List<MemoryRecord> memorySearchResults = const [];
  String? memoryRetrievalMode;
  List<StoryRecord> stories = const [];
  List<ResourceItem> resourceItems = const [];
  List<ResourceConflict> resourceConflicts = const [];
  List<ResourceItem> guestHelpResources = const [];
  String? guestHelpRetrievalMode;
  String? resourceRetrievalMode;
  List<FamilyMessage> familyMessages = const [];
  bool memoryConsentEnabled = false;
  MemoryControlState? memoryControlState;
  MemoryDeletionPreview? pendingMemoryDeletion;
  MemoryDeletionReceipt? memoryDeletionReceipt;
  MemoryDeletionPreview? _preparedMemoryDeletion;
  bool memoryDeletionBusy = false;
  MemoryCardDraft? _memoryCardSave;
  int _memoryMutationGeneration = 0;
  int _memoryPreviewGeneration = 0;
  bool get supportsMemoryControls => isElder && api is MemoryControlApi;
  int? get memoryRevision => memoryControlState?.revision;
  bool get _memoryReadsBlocked => pendingMemoryDeletion != null;

  bool _memoryCurrent(int sessionGeneration, int mutationGeneration) =>
      session != null &&
      sessionGeneration == _sessionGeneration &&
      mutationGeneration == _memoryMutationGeneration &&
      !_memoryReadsBlocked;

  void _invalidateMemoryDerived() {
    _memoryCardSave = null;
    ++_memoryMutationGeneration;
    loading = false;
    _catalogLoadingGeneration = null;
    _catalogActivitiesLoadingGeneration = null;
    _sendingFamilyMessageKeys.clear();
    ++_memoryPreviewGeneration;
    _preparedMemoryDeletion = null;
    ++_catalogConsentGeneration;
    ++_catalogActivitiesGeneration;
    skillSuggestions = const [];
    opportunities = const [];
    opportunitySources = const [];
    opportunitySearchState = 'unavailable';
    opportunityCheckedAt = null;
    opportunitySearchMessage = '';
    catalogRecommendations = const [];
    catalogActivities = const [];
    memorySearchResults = const [];
    memoryRetrievalMode = null;
  }

  void _acceptMemoryRevision(int? revision) {
    if (revision == null) return;
    memoryControlState = MemoryControlState(
        enabled: memoryConsentEnabled,
        revision: revision,
        counts: memoryControlState?.counts ?? const {});
  }

  bool _hasMemoryRevision(int? revision) {
    if (_memoryReadsBlocked) return false;
    if (api is! MemoryControlApi || revision != null) return true;
    errorMessage = 'Memory changed. Refresh and review before saving.';
    notifyListeners();
    return false;
  }

  void _resetMemoryControls() {
    _invalidateMemoryDerived();
    ++_memoryPreviewGeneration;
    _preparedMemoryDeletion = null;
    pendingMemoryDeletion = null;
    memoryDeletionReceipt = null;
    memoryDeletionBusy = false;
    memoryControlState = null;
    savingMemorySuggestionIds.clear();
    savedMemorySuggestionIds.clear();
    updatingMemoryIds.clear();
    updatingStoryIds.clear();
    sendingConversationIds.clear();
    loadingConversationIds.clear();
    _sendingFamilyMessageKeys.clear();
    memories = const [];
    stories = const [];
    familyMessages = const [];
    memoryConsentEnabled = false;
  }

  Future<MemoryDeletionPreview?> prepareMemoryDeletion(
      {required String mode, List<String> memoryIds = const []}) async {
    if (!supportsMemoryControls ||
        _memoryReadsBlocked ||
        memoryDeletionBusy ||
        (mode != 'all' && mode != 'selected') ||
        (mode == 'all' && memoryIds.isNotEmpty) ||
        (mode == 'selected' &&
            (memoryIds.isEmpty ||
                memoryIds.toSet().length != memoryIds.length))) {
      return null;
    }
    final generation = _sessionGeneration;
    final mutation = _memoryMutationGeneration;
    final request = ++_memoryPreviewGeneration;
    final ownerId = user!.id;
    final selected = {
      for (final m in [...memories, ...memorySearchResults]) m.id: m
    };
    _preparedMemoryDeletion = null;
    try {
      final control = await (api as MemoryControlApi).getMemoryControlState();
      if (!_memoryCurrent(generation, mutation) ||
          request != _memoryPreviewGeneration) {
        return null;
      }
      if (mode == 'selected') {
        final current = await api.listMemories();
        if (!_memoryCurrent(generation, mutation) ||
            request != _memoryPreviewGeneration) {
          return null;
        }
        for (final id in memoryIds) {
          final matching = current.where((m) => m.id == id);
          if (matching.any(
                  (m) => m.status == 'superseded' || m.status == 'deleted') ||
              !selected.containsKey(id) ||
              matching.length != 1 ||
              selected[id]!.revision != control.revision ||
              matching.single.revision != control.revision) {
            throw const ApiException(
                'Memory changed. Refresh and review the selected memories.',
                statusCode: 409);
          }
        }
      }
      memoryControlState = control;
      memoryConsentEnabled = control.enabled;
      final preview = MemoryDeletionPreview._(
          ownerId: ownerId,
          sessionGeneration: generation,
          revision: control.revision,
          mode: mode,
          memoryIds: memoryIds,
          idempotencyKey: _newClientId('memory-delete'),
          counts: control.counts);
      _preparedMemoryDeletion = preview;
      errorMessage = null;
      notifyListeners();
      return preview;
    } on Object catch (error) {
      if (_memoryCurrent(generation, mutation) &&
          request == _memoryPreviewGeneration) {
        errorMessage = _messageFor(error);
        notifyListeners();
      }
      return null;
    }
  }

  void cancelMemoryDeletion(MemoryDeletionPreview preview) {
    if (identical(preview, _preparedMemoryDeletion)) {
      ++_memoryPreviewGeneration;
      _preparedMemoryDeletion = null;
    }
  }

  Future<bool> confirmMemoryDeletion(MemoryDeletionPreview preview) async {
    if (!supportsMemoryControls ||
        memoryDeletionBusy ||
        pendingMemoryDeletion != null ||
        !identical(preview, _preparedMemoryDeletion) ||
        preview.ownerId != user?.id ||
        preview.sessionGeneration != _sessionGeneration) {
      return false;
    }
    _preparedMemoryDeletion = null;
    pendingMemoryDeletion = preview;
    conversations = const [];
    messagesByConversation.clear();
    pendingActions.clear();
    memoryDeletionReceipt = null;
    savingMemorySuggestionIds.clear();
    savedMemorySuggestionIds.clear();
    _invalidateMemoryDerived();
    memories = const [];
    stories = const [];
    familyMessages = const [];
    return _submitMemoryDeletion(preview);
  }

  Future<bool> retryMemoryDeletion() async {
    final preview = pendingMemoryDeletion;
    if (preview == null ||
        memoryDeletionBusy ||
        !supportsMemoryControls ||
        preview.ownerId != user?.id ||
        preview.sessionGeneration != _sessionGeneration) {
      return false;
    }
    return _submitMemoryDeletion(preview);
  }

  Future<void> _reloadMemoryConflict(int generation, int mutation) async {
    const message =
        'Memory changed. Review the current memories before confirming again.';
    try {
      final state = await (api as MemoryControlApi).getMemoryControlState();
      if (!_memoryCurrent(generation, mutation)) return;
      final rows = await api.listMemories();
      if (!_memoryCurrent(generation, mutation)) return;
      memoryControlState = state;
      memoryConsentEnabled = state.enabled;
      memories = rows;
    } on Object {
      if (!_memoryCurrent(generation, mutation)) return;
    }
    errorMessage = message;
  }

  Future<bool> _submitMemoryDeletion(MemoryDeletionPreview preview) async {
    final generation = _sessionGeneration;
    final mutation = _memoryMutationGeneration;
    bool current() =>
        generation == _sessionGeneration &&
        mutation == _memoryMutationGeneration &&
        user?.id == preview.ownerId &&
        identical(preview, pendingMemoryDeletion);
    memoryDeletionBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final receipt = await (api as MemoryControlApi).deleteMemories(
          mode: preview.mode,
          memoryIds: preview.memoryIds,
          expectedRevision: preview.revision,
          idempotencyKey: preview.idempotencyKey);
      if (!current()) return false;
      if (receipt.revision <= preview.revision ||
          receipt.requestId.trim().isEmpty) {
        throw const ApiException(
            'Deletion could not be verified. Retry the original request.');
      }
      memoryDeletionReceipt = receipt;
      // Receipt counts describe removed rows; only control-state can report
      // how much independent content remains. Never reuse the old totals.
      memoryControlState = MemoryControlState(
          enabled: memoryConsentEnabled,
          revision: receipt.revision,
          counts: const {});
      try {
        final fresh = await (api as MemoryControlApi).getMemoryControlState();
        if (!current()) return false;
        if (fresh.revision >= receipt.revision) {
          memoryControlState = fresh;
          memoryConsentEnabled = fresh.enabled;
        }
      } on Object {
        // The deletion itself is confirmed. A failed follow-up read must
        // neither undo its receipt nor report an uncertain deletion.
        if (!current()) return false;
      }
      pendingMemoryDeletion = null;
      return true;
    } on Object catch (error) {
      if (!current()) return false;
      errorMessage = _messageFor(error);
      if (error is ApiException &&
          (error.statusCode == 409 ||
              error.statusCode == 403 ||
              error.statusCode == 422)) {
        pendingMemoryDeletion = null;
        memoryControlState = null;
        if (error.statusCode == 409) {
          await _reloadMemoryConflict(generation, mutation);
        }
      }
      return false;
    } finally {
      if (generation == _sessionGeneration &&
          mutation == _memoryMutationGeneration) {
        memoryDeletionBusy = false;
        notifyListeners();
      }
    }
  }

  GuestSession? guestSession;
  final List<(String, bool)> guestMessages = <(String, bool)>[];
  final Map<int, Map<String, dynamic>> guestMessageMetadata = {};
  final Set<String> savingMemorySuggestionIds = <String>{};
  final Set<String> savedMemorySuggestionIds = <String>{};
  List<CommunityActivity> communityActivities = const [];
  List<CommunityOpportunity> opportunities = const [];
  List<CommunitySearchSource> opportunitySources = const [];
  String opportunitySearchState = 'unavailable';
  DateTime? opportunityCheckedAt;
  String opportunitySearchMessage = '';
  List<SkillSuggestion> skillSuggestions = const [];
  List<CommunitySearchSource> communitySources = const [];
  String communitySearchState = 'unavailable';
  String communitySearchMessage = '';
  String? communitySearchReason = 'not_searched';
  DateTime? communityCheckedAt;
  bool communitySearchLoading = false;
  String communityTopic = '';
  String communityArea = '';
  String communityTargetGroup = 'elderly';
  bool communityHasMore = false;
  int? communityTotalCount;
  int _communityNextOffset = 0;
  bool communityNoResults = false;
  List<CatalogActivity> catalogActivities = const [];
  List<CatalogActivity> catalogRecommendations = const [];
  List<CatalogActivity> catalogInterests = const [];
  List<ScamResource> scamResources = const [];
  List<VerifyAction> verifyActions = const [];
  List<ScamContact> scamContacts = const [];
  List<ScamLogEntry> scamLogs = const [];
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
  int _guestGeneration = 0;
  int _communityGeneration = 0;
  int _catalogConsentGeneration = 0;
  int? _catalogLoadingGeneration;
  int _catalogActivitiesGeneration = 0;
  int? _catalogActivitiesLoadingGeneration;

  bool get isSignedIn => session != null;
  AppUser? get user => session?.user;
  bool get isElder => user?.role == UserRole.elder;
  bool get isCaregiver => user?.role == UserRole.caregiver;

  bool get _canUseFamilyMessages =>
      !_familyAccessUncertain &&
      links.any(
        (link) =>
            link.status == InvitationStatus.accepted &&
            (!supportsFamilyConnections || _authorizedLink(link)) &&
            link.allowsFamilyMessages,
      );

  /// Active links with the family_messages grant are the only valid message
  /// recipients. The UI uses this list for its picker and the controller
  /// checks the id again before sending.
  List<FamilyInvitation> get familyMessageLinks => links
      .where(
        (link) =>
            link.status == InvitationStatus.accepted &&
            (!supportsFamilyConnections || _authorizedLink(link)) &&
            link.allowsFamilyMessages,
      )
      .toList(growable: false);

  String? recipientIdFor(FamilyInvitation link) {
    if (!_canUseFamilyMessages ||
        !familyMessageLinks.any((current) => identical(current, link)) ||
        link.status != InvitationStatus.accepted ||
        !link.allowsFamilyMessages) {
      return null;
    }
    return isElder ? link.caregiverId : link.elderId;
  }

  String familyCounterpartEmail(FamilyInvitation link) =>
      (isElder ? (link.caregiverEmail ?? link.email) : (link.elderEmail ?? ''))
          .trim();

  String _familyIdentity(String name, String email, String accountId) {
    final label = name.trim();
    final identifier = email.trim().isNotEmpty ? email.trim() : accountId;
    if (label.isEmpty) return identifier.isNotEmpty ? identifier : '家庭成員';
    return identifier.isEmpty ? label : '$label\n$identifier';
  }

  String familyCounterpartLabel(FamilyInvitation link) => _familyIdentity(
      (isElder ? link.caregiverName : link.elderName) ?? link.name ?? '',
      familyCounterpartEmail(link),
      (isElder ? link.caregiverId : link.elderId) ?? link.id);

  String taskShareRecipientLabel(TaskShare share) {
    for (final link in links) {
      if (link.id == share.familyLinkId &&
          link.caregiverId == share.caregiverId) {
        return _familyIdentity(
            share.caregiverName.isNotEmpty
                ? share.caregiverName
                : (link.caregiverName ?? ''),
            share.caregiverEmail.isNotEmpty
                ? share.caregiverEmail
                : (link.caregiverEmail ?? link.email),
            share.caregiverId ?? link.caregiverId ?? share.familyLinkId);
      }
    }
    return _familyIdentity(share.caregiverName, share.caregiverEmail,
        share.caregiverId ?? share.familyLinkId);
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
      if (mode == null || generation != _sessionGeneration || session == null) {
        return;
      }
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
      final nextSession =
          await api.login(email: email.trim(), password: password);
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
    if (guestSession != null) await endGuestSession();
    _sessionGeneration += 1;
    _resetMemoryControls();
    _resetTaskSharing();
    _resetFamilyConnections();
    _catalogLoadingGeneration = null;
    _catalogActivitiesLoadingGeneration = null;
    tasks = const [];
    session = nextSession;
    _syncToken();
    await sessionStore.saveSession(nextSession);
    errorMessage = null;
    notifyListeners();
  }

  Future<void> logout() async {
    await endGuestSession();
    final currentUserId = user?.id;
    _sessionGeneration += 1;
    _resetMemoryControls();
    _resetTaskSharing();
    _resetFamilyConnections();
    tasks = const [];
    _catalogLoadingGeneration = null;
    _catalogActivitiesLoadingGeneration = null;
    loading = true;
    notifyListeners();
    if (currentUserId != null) {
      try {
        await reminderScheduler?.cancelUserNotifications(currentUserId);
      } on Object catch (error) {
        errorMessage = _messageFor(error);
      }
    }
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
      memoryConsentEnabled = false;
      memorySearchResults = const [];
      memoryRetrievalMode = null;
      stories = const [];
      resourceItems = const [];
      resourceConflicts = const [];
      resourceRetrievalMode = null;
      familyMessages = const [];
      skillSuggestions = const [];
      opportunities = const [];
      opportunitySources = const [];
      opportunitySearchState = 'unavailable';
      opportunityCheckedAt = null;
      opportunitySearchMessage = '';
      communityActivities = const [];
      communityHasMore = false;
      communityTotalCount = null;
      _communityNextOffset = 0;
      communitySearchLoading = false;
      communitySources = const [];
      communitySearchState = 'unavailable';
      communityCheckedAt = null;
      communitySearchMessage = '';
      communitySearchReason = 'not_searched';
      guestHelpResources = const [];
      savingMemorySuggestionIds.clear();
      savedMemorySuggestionIds.clear();
      catalogActivities = const [];
      catalogRecommendations = const [];
      catalogInterests = const [];
      scamResources = const [];
      verifyActions = const [];
      scamContacts = const [];
      scamLogs = const [];
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
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    var mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    var pairGeneration = familyConnectionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    final errors = <String>[];
    if (isElder && (api is ConsentApi || api is MemoryControlApi)) {
      try {
        final control = api is MemoryControlApi
            ? await (api as MemoryControlApi).getMemoryControlState()
            : null;
        final enabled =
            control?.enabled ?? await (api as ConsentApi).getMemoryConsent();
        if ((!_memoryCurrent(generation, mutationGeneration) ||
            !_familyCurrent(generation, pairGeneration))) {
          return;
        }
        memoryControlState = control;
        if ((!_memoryCurrent(generation, mutationGeneration) ||
            !_familyCurrent(generation, pairGeneration))) {
          return;
        }
        memoryConsentEnabled = enabled;
      } on ApiException catch (error) {
        errors.add(error.message);
      }
    }
    try {
      final foundation = await Future.wait<Object?>([
        refreshTasks(silent: true).then<Object?>((_) => null),
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
      if ((!_memoryCurrent(generation, mutationGeneration) ||
          !_familyCurrent(generation, pairGeneration))) {
        return;
      }
      if (!_familyAccessUncertain) {
        final freshLinks = foundation[2] as List<FamilyInvitation>;
        if (supportsFamilyConnections &&
            _familyAuthorizationSignature(links) !=
                _familyAuthorizationSignature(freshLinks)) {
          _invalidateFamilyAccess();
          pairGeneration = familyConnectionGeneration;
          mutationGeneration = _memoryMutationGeneration;
          _familyAccessUncertain = false;
        }
        invitations = foundation[1] as List<FamilyInvitation>;
        links = foundation[2] as List<FamilyInvitation>;
      }
      if ((!_memoryCurrent(generation, mutationGeneration) ||
          !_familyCurrent(generation, pairGeneration))) {
        return;
      }
      if (isElder && foundation.length > 3) {
        conversations = foundation[3] as List<Conversation>;
        await _restorePendingActions(
            conversations, generation, mutationGeneration);
        if ((!_memoryCurrent(generation, mutationGeneration) ||
            !_familyCurrent(generation, pairGeneration))) {
          return;
        }
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
      if ((!_memoryCurrent(generation, mutationGeneration) ||
          !_familyCurrent(generation, pairGeneration))) {
        return;
      }
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
          final messages = await api.listFamilyMessages();
          if ((!_memoryCurrent(generation, mutationGeneration) ||
              !_familyCurrent(generation, pairGeneration))) {
            return;
          }
          familyMessages = messages;
        } on Object catch (error) {
          if (supportsFamilyConnections &&
              error is ApiException &&
              (error.statusCode == 403 || error.statusCode == 410) &&
              _familyCurrent(generation, pairGeneration)) {
            _invalidateFamilyAccess();
            errorMessage = _messageFor(error);
            notifyListeners();
            return;
          }
          errors.add(_messageFor(error));
        }
      } else {
        familyMessages = const [];
      }
      if ((!_memoryCurrent(generation, mutationGeneration) ||
          !_familyCurrent(generation, pairGeneration))) {
        return;
      }
      if (errors.isNotEmpty) errorMessage = errors.first;
      notifyListeners();
    } finally {
      if (!silent &&
          generation == _sessionGeneration &&
          pairGeneration == familyConnectionGeneration) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> startGuestSession() async {
    final guestApi = api is GuestApi ? api as GuestApi : null;
    if (guestApi == null) {
      errorMessage = '訪客對話服務尚未就緒。';
      notifyListeners();
      return false;
    }
    loading = true;
    errorMessage = null;
    notifyListeners();
    final generation = ++_guestGeneration;
    try {
      final created = await guestApi.startGuestSession();
      if (generation != _guestGeneration || session != null) {
        await guestApi.endGuestSession(created.id);
        return false;
      }
      guestSession = created;
      guestMessages.clear();
      guestMessageMetadata.clear();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> sendGuestMessage(String content) async {
    final active = guestSession;
    final guestApi = api is GuestApi ? api as GuestApi : null;
    if (active == null || guestApi == null || content.trim().isEmpty) {
      return false;
    }
    final generation = _guestGeneration;
    guestMessages.add((content.trim(), true));
    notifyListeners();
    try {
      final reply = await guestApi.sendGuestMessage(active.id, content.trim());
      if (generation != _guestGeneration || guestSession?.id != active.id) {
        return false;
      }
      guestMessages.add((reply.content, false));
      if (reply.communitySources.isNotEmpty) {
        guestMessageMetadata[guestMessages.length - 1] = {
          'community_sources': reply.communitySources
              .map((source) => {
                    'name': source.name,
                    'url': source.url,
                    'state': source.state,
                    if (source.checkedAt != null)
                      'checked_at': source.checkedAt!.toIso8601String(),
                    if (source.error != null) 'error': source.error,
                  })
              .toList(),
          if (reply.communitySearchState != null)
            'community_search_state': reply.communitySearchState,
        };
      }
      if (reply.expiresAt != null) {
        guestSession = GuestSession(id: active.id, expiresAt: reply.expiresAt);
      }
      errorMessage = null;
      return true;
    } on ApiException catch (error) {
      if (generation == _guestGeneration && guestSession?.id == active.id) {
        errorMessage = error.message;
      }
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<void> endGuestSession() async {
    final previous = guestSession;
    ++_guestGeneration;
    guestSession = null;
    guestMessages.clear();
    guestMessageMetadata.clear();
    errorMessage = null;
    notifyListeners();
    if (previous != null && api is GuestApi) {
      try {
        await (api as GuestApi).endGuestSession(previous.id);
      } on ApiException catch (error) {
        errorMessage = error.message;
        notifyListeners();
      }
    }
  }

  Future<bool> setMemoryConsent(bool enabled) async {
    if (!isElder || (api is! ConsentApi && api is! MemoryControlApi)) {
      return false;
    }
    final revision = memoryRevision;
    if (!_hasMemoryRevision(revision)) return false;
    _invalidateMemoryDerived();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final ownerId = user?.id;
    loading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final control = api is MemoryControlApi
          ? await (api as MemoryControlApi)
              .setMemoryConsentAtRevision(enabled, expectedRevision: revision!)
          : null;
      final updated = control?.enabled ??
          await (api as ConsentApi).setMemoryConsent(enabled);
      if (!_memoryCurrent(generation, mutationGeneration) ||
          user?.id != ownerId ||
          !isElder) {
        return false;
      }
      memoryControlState = control;
      memoryConsentEnabled = updated;
      _catalogConsentGeneration++;
      if (!memoryConsentEnabled) {
        catalogRecommendations = const [];
        skillSuggestions = const [];
        opportunities = const [];
        opportunitySources = const [];
        opportunitySearchState = 'unavailable';
        opportunityCheckedAt = null;
        opportunitySearchMessage = '';
        memorySearchResults = const [];
        memoryRetrievalMode = null;
        savingMemorySuggestionIds.clear();
        savedMemorySuggestionIds.clear();
      }
      // Consent changes the owner revision. Fetch reviewable rows at the new
      // version; never relabel cached rows with the returned revision.
      if (control != null) await refreshMemories(silent: true);
      if (!_memoryCurrent(generation, mutationGeneration) ||
          user?.id != ownerId) {
        return false;
      }
      // Consent changes the owner revision. Fetch reviewable rows at the new
      // version; never relabel cached rows with the returned revision.
      if (control != null) await refreshMemories(silent: true);
      if (!_memoryCurrent(generation, mutationGeneration) ||
          user?.id != ownerId) {
        return false;
      }
      return memoryConsentEnabled == enabled;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration) ||
          user?.id != ownerId) {
        return false;
      }
      errorMessage = error.message;
      return false;
    } finally {
      if (_memoryCurrent(generation, mutationGeneration) &&
          user?.id == ownerId) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshMemoryControlState({bool silent = true}) =>
      loadMemoryConsent();

  Future<void> loadMemoryConsent() async {
    if (!isElder || (api is! ConsentApi && api is! MemoryControlApi)) return;
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final ownerId = user?.id;
    try {
      final control = api is MemoryControlApi
          ? await (api as MemoryControlApi).getMemoryControlState()
          : null;
      final enabled =
          control?.enabled ?? await (api as ConsentApi).getMemoryConsent();
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      memoryControlState = control;
      if (generation != _sessionGeneration || user?.id != ownerId || !isElder) {
        return;
      }
      memoryConsentEnabled = enabled;
      if (!enabled) {
        _invalidateMemoryDerived();
        catalogRecommendations = const [];
      }
      errorMessage = null;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration) ||
          user?.id != ownerId) {
        return;
      }
      errorMessage = error.message;
    }
    notifyListeners();
  }

  Future<bool> saveSuggestedMemory(ChatMessage message,
      {String? editedContent}) async {
    final suggestion = message.memorySuggestion;
    if (!isElder ||
        !memoryConsentEnabled ||
        suggestion == null ||
        (api is! MemorySaveApi && api is! MemoryControlApi)) {
      return false;
    }
    final content = (editedContent ?? suggestion.content).trim();
    if (content.isEmpty) return false;
    if (savingMemorySuggestionIds.contains(message.id) ||
        savedMemorySuggestionIds.contains(message.id)) {
      return false;
    }
    if (!_hasMemoryRevision(suggestion.revision)) return false;
    _invalidateMemoryDerived();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final ownerId = user?.id;
    savingMemorySuggestionIds.add(message.id);
    notifyListeners();
    try {
      final saved = await (api is MemoryControlApi
          ? (api as MemoryControlApi).saveConfirmedMemoryAtRevision(
              expectedRevision: suggestion.revision!,
              content: content,
              kind: suggestion.kind,
              sourceMessageId: suggestion.sourceMessageId,
              topicKey:
                  content == suggestion.content ? suggestion.topicKey : null,
            )
          : (api as MemorySaveApi).saveConfirmedMemory(
              content: content,
              kind: suggestion.kind,
              sourceMessageId: suggestion.sourceMessageId,
              topicKey:
                  content == suggestion.content ? suggestion.topicKey : null,
            ));
      if (!_memoryCurrent(generation, mutationGeneration) ||
          generation != _sessionGeneration ||
          user?.id != ownerId ||
          !isElder ||
          !memoryConsentEnabled) {
        return false;
      }
      _acceptMemoryRevision(saved.revision);
      savedMemorySuggestionIds.add(message.id);
      memories = [saved, ...memories.where((item) => item.id != saved.id)];
      errorMessage = null;
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (_memoryCurrent(generation, mutationGeneration) &&
          user?.id == ownerId) {
        errorMessage = error.message;
      }
      return false;
    } finally {
      if (generation == _sessionGeneration) {
        savingMemorySuggestionIds.remove(message.id);
        notifyListeners();
      }
    }
  }

  Future<void> refreshCommunity({bool skills = true}) async {
    if (api is! CommunityApi) return;
    await searchCommunity();
    if (skills && isElder && memoryConsentEnabled) {
      await _refreshSkillSuggestions();
    }
  }

  Future<void> searchCommunity(
      {String? topic, String? area, String? targetGroup}) async {
    if (api is! CommunityApi && api is! PagedCommunityApi) return;
    communityTopic = (topic ?? communityTopic).trim();
    communityArea = (area ?? communityArea).trim();
    communityTargetGroup = targetGroup ?? communityTargetGroup;
    communityActivities = const [];
    communitySources = const [];
    communityHasMore = false;
    communityTotalCount = null;
    _communityNextOffset = 0;
    await _searchCommunityPage(append: false);
  }

  Future<void> loadMoreCommunity() async {
    if (api is! PagedCommunityApi ||
        communitySearchLoading ||
        !communityHasMore) {
      return;
    }
    await _searchCommunityPage(append: true);
  }

  Future<void> _searchCommunityPage({required bool append}) async {
    final generation = _sessionGeneration;
    final requestId = ++_communityGeneration;
    final ownerId = user?.id;
    bool current() =>
        generation == _sessionGeneration &&
        user?.id == ownerId &&
        requestId == _communityGeneration;
    communitySearchLoading = true;
    communitySearchMessage = '';
    communitySearchReason = null;
    notifyListeners();
    try {
      final result = api is PagedCommunityApi
          ? await (api as PagedCommunityApi).searchCommunityActivityPage(
              topic: communityTopic.isEmpty ? null : communityTopic,
              area: communityArea.isEmpty ? null : communityArea,
              targetGroup: communityTargetGroup,
              offset: append ? _communityNextOffset : 0)
          : await (api as CommunityApi).searchCommunityActivities(
              topic: communityTopic.isEmpty ? null : communityTopic,
              area: communityArea.isEmpty ? null : communityArea);
      if (!current()) return;
      // A source fault during pagination preserves the current page and retry offset.
      if (!(append && result.searchState == 'unavailable')) {
        final seen = append
            ? communityActivities.map((item) => item.id).toSet()
            : <String>{};
        communityActivities = [
          if (append) ...communityActivities,
          ...result.items.where((item) => seen.add(item.id))
        ];
        communityTotalCount = result.totalCount;
        _communityNextOffset = result.offset + result.items.length;
        communityHasMore = api is PagedCommunityApi &&
            result.hasMore &&
            result.items.isNotEmpty;
      }
      communitySources = result.sources;
      communitySearchState = result.searchState;
      communityCheckedAt = result.checkedAt;
      communityNoResults = communityActivities.isEmpty &&
          (result.noResults || result.items.isEmpty);
      communitySearchMessage = result.message;
      communitySearchReason = result.searchReason;
      errorMessage = null;
    } on ApiException catch (error) {
      if (!current()) return;
      if (!append) {
        communityActivities = const [];
        communitySources = const [];
        communitySearchState = 'unavailable';
        communityCheckedAt = null;
      }
      communityNoResults = false;
      communitySearchMessage = error.message;
      communitySearchReason = error.statusCode == 400 || error.statusCode == 422
          ? 'invalid_query'
          : (error.statusCode ?? 0) >= 500
              ? 'service_error'
              : 'request_failed';
    } finally {
      if (current()) {
        communitySearchLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _refreshSkillSuggestions() async {
    if (api is! CommunityApi || !isElder || !memoryConsentEnabled) return;
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final ownerId = user?.id;
    try {
      final revision = memoryRevision;
      if (!_hasMemoryRevision(revision)) return;
      final results = await (api is MemoryControlApi
          ? (api as MemoryControlApi)
              .listSkillSuggestionsAtRevision(expectedRevision: revision!)
          : (api as CommunityApi).listSkillSuggestions());
      if (!_memoryCurrent(generation, mutationGeneration) ||
          user?.id != ownerId ||
          !isElder ||
          !memoryConsentEnabled) {
        return;
      }
      if (results.isNotEmpty) _acceptMemoryRevision(results.first.revision);
      skillSuggestions = results;
      final confirmed = results.where((item) => item.status == 'confirmed');
      final matches = <CommunityOpportunity>[];
      final sources = <CommunitySearchSource>[];
      var state = 'unavailable';
      DateTime? checkedAt;
      var message = '';
      for (final skill in confirmed) {
        final search =
            await (api as CommunityApi).searchOpportunities(skill.id);
        if (!_memoryCurrent(generation, mutationGeneration) ||
            user?.id != ownerId ||
            !isElder ||
            !memoryConsentEnabled) {
          return;
        }
        matches.addAll(search.items);
        sources.addAll(search.sources);
        checkedAt = search.checkedAt ?? checkedAt;
        if (search.searchState == 'live' ||
            (search.searchState == 'cache' && state != 'live')) {
          state = search.searchState;
        }
        if (search.message.isNotEmpty) message = search.message;
      }
      opportunities = matches;
      opportunitySources = sources;
      opportunitySearchState = state;
      opportunityCheckedAt = checkedAt;
      opportunitySearchMessage = message;
      errorMessage = null;
    } on ApiException catch (error) {
      if (_memoryCurrent(generation, mutationGeneration) &&
          user?.id == ownerId) {
        errorMessage = error.message;
      }
    }
    notifyListeners();
  }

  Future<void> searchHelp(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final generation = _sessionGeneration;
    final ownerId = user?.id;
    try {
      final result = isSignedIn
          ? await api.searchResources(query: trimmed, limit: 4)
          : api is GuestResourceApi
              ? await (api as GuestResourceApi)
                  .searchGuestResources(query: trimmed, limit: 4)
              : throw const ApiException('訪客資訊搜尋暫時未能使用。');
      if (generation != _sessionGeneration || user?.id != ownerId) return;
      guestHelpResources = result.items;
      guestHelpRetrievalMode = result.retrievalMode;
      errorMessage = null;
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || user?.id != ownerId) return;
      errorMessage = error.message;
      guestHelpResources = const [];
    }
    notifyListeners();
  }

  Future<bool> decideSkill(SkillSuggestion suggestion,
      {required String decision, String? skill}) async {
    if (api is! CommunityApi || !isElder || !memoryConsentEnabled) return false;
    if (!_hasMemoryRevision(suggestion.revision)) return false;
    _invalidateMemoryDerived();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final ownerId = user?.id;
    try {
      final result = await (api is MemoryControlApi
          ? (api as MemoryControlApi).decideSkillAtRevision(suggestion.id,
              decision: decision,
              skill: skill,
              expectedRevision: suggestion.revision!)
          : (api as CommunityApi)
              .decideSkill(suggestion.id, decision: decision, skill: skill));
      if (!_memoryCurrent(generation, mutationGeneration) ||
          user?.id != ownerId ||
          !isElder ||
          !memoryConsentEnabled) {
        return false;
      }
      _acceptMemoryRevision(result.revision);
      _catalogConsentGeneration++;
      catalogRecommendations = const [];
      notifyListeners();
      skillSuggestions = [
        for (final item in skillSuggestions)
          if (item.id != result.id) item,
        result
      ];
      if (decision == 'confirm' || decision == 'edit') {
        final matches =
            await (api as CommunityApi).searchOpportunities(result.id);
        if (!_memoryCurrent(generation, mutationGeneration) ||
            user?.id != ownerId ||
            !isElder ||
            !memoryConsentEnabled) {
          return false;
        }
        opportunities = matches.items;
        opportunitySources = matches.sources;
        opportunitySearchState = matches.searchState;
        opportunityCheckedAt = matches.checkedAt;
        opportunitySearchMessage = matches.message;
      } else if (decision == 'reject') {
        opportunities = const [];
        opportunitySources = const [];
        opportunitySearchState = 'unavailable';
        opportunityCheckedAt = null;
        opportunitySearchMessage = '';
      }
      errorMessage = null;
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (_memoryCurrent(generation, mutationGeneration) &&
          user?.id == ownerId) {
        errorMessage = error.message;
      }
      notifyListeners();
      return false;
    }
  }

  Future<void> _restorePendingActions(
    List<Conversation> restoredConversations,
    int generation,
    int mutationGeneration,
  ) async {
    if (!_memoryCurrent(generation, mutationGeneration)) return;
    if (restoredConversations.isEmpty) {
      pendingActions.clear();
      return;
    }
    final restored = <ActionProposal>[];
    for (final conversation in restoredConversations) {
      try {
        final actions = await api.listActions(conversation.id);
        if (!_memoryCurrent(generation, mutationGeneration)) return;
        restored.addAll(actions);
      } on ApiException {
        if (!_memoryCurrent(generation, mutationGeneration)) return;
        // The action list is additive. A chat can still be opened if this
        // optional restore request is unavailable on an older server.
      }
    }
    if (_memoryCurrent(generation, mutationGeneration)) {
      pendingActions
        ..clear()
        ..addAll({for (final action in restored) action.id: action}.values);
    }
  }

  Future<Conversation?> startConversation() async {
    if (!isElder || _memoryReadsBlocked) return null;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    errorMessage = null;
    try {
      final conversation = await api.createConversation();
      if (!_memoryCurrent(generation, mutationGeneration)) return null;
      conversations = [conversation, ...conversations];
      messagesByConversation.putIfAbsent(
          conversation.id, () => <ChatMessage>[]);
      notifyListeners();
      return conversation;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return null;
      errorMessage = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<void> loadMessages(String conversationId) async {
    if (!isElder || loadingConversationIds.contains(conversationId)) return;
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    loadingConversationIds.add(conversationId);
    errorMessage = null;
    notifyListeners();
    try {
      final loadedMessages = await api.listMessages(conversationId);
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      final loadedActions = await api.listActions(conversationId);
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      messagesByConversation[conversationId] = loadedMessages;
      for (final action in loadedActions) {
        if (!pendingActions.any((item) => item.id == action.id)) {
          pendingActions.add(action);
        }
      }
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      errorMessage = error.message;
    } finally {
      if (generation == _sessionGeneration) {
        loadingConversationIds.remove(conversationId);
        notifyListeners();
      }
    }
  }

  List<ChatMessage> messagesFor(String conversationId) =>
      messagesByConversation[conversationId] ?? const <ChatMessage>[];

  Future<String?> readDraft(String conversationId) async {
    if (drafts.containsKey(conversationId)) return drafts[conversationId];
    final value =
        await sessionStore.readDraft(conversationId, userId: user?.id);
    if (value != null) drafts[conversationId] = value;
    final clientId =
        await sessionStore.readDraftClientId(conversationId, userId: user?.id);
    if (clientId != null && clientId.isNotEmpty) {
      _draftClientIds[conversationId] = clientId;
    }
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
      await sessionStore.saveDraftClientId(conversationId, clientId,
          userId: user?.id);
    }
    await sessionStore.saveDraft(conversationId, draft, userId: user?.id);
    notifyListeners();
  }

  Future<bool> sendMessage({
    required String conversationId,
    required String content,
  }) async {
    if (_memoryReadsBlocked ||
        !isElder ||
        content.trim().isEmpty ||
        sendingConversationIds.contains(conversationId)) {
      return false;
    }
    final trimmed = content.trim();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final ownerId = user!.id;
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
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      final existing = List<ChatMessage>.from(messagesFor(conversationId));
      final userMessage = result.userMessage ??
          ChatMessage(
            id: clientMessageId,
            conversationId: conversationId,
            body: trimmed,
            isFromUser: true,
            createdAt: DateTime.now(),
          );
      if (!existing.any((message) => message.id == userMessage.id)) {
        existing.add(userMessage);
      }
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
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      if (result.action != null &&
          !pendingActions.any((action) => action.id == result.action!.id)) {
        pendingActions.add(result.action!);
      }
      // An explicit "記住" request can create a server-side candidate. The
      // candidate remains unconfirmed; refreshing it here only makes the
      // review card available immediately after the chat response.
      if (assistantMessage?.candidateMemoryId != null ||
          assistantMessage?.autoSavedMemory != null) {
        try {
          final refreshedMemories = await api.listMemories();
          if (_memoryCurrent(generation, mutationGeneration)) {
            memories = refreshedMemories;
          }
        } on ApiException {
          // The chat send already succeeded. The memory screen can retry.
        }
      }
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      _messageClientIds.remove(key);
      await sessionStore.clearDraft(conversationId, userId: ownerId);
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      await sessionStore.clearDraftClientId(conversationId, userId: ownerId);
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      drafts.remove(conversationId);
      _draftClientIds.remove(conversationId);
      try {
        await reminderScheduler?.markConversationActivity(user!.id);
      } on Object catch (error) {
        if (!_memoryCurrent(generation, mutationGeneration)) return false;
        errorMessage = _messageFor(error);
      }
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      if (generation == _sessionGeneration) {
        sendingConversationIds.remove(conversationId);
        notifyListeners();
      }
    }
  }

  List<FamilyInvitation> get eligibleTaskSharingLinks =>
      !isElder || _familyAccessUncertain
          ? const []
          : links
              .where((link) =>
                  link.status == InvitationStatus.accepted &&
                  link.scopes.contains('care_tasks') &&
                  (!supportsFamilyConnections || _authorizedLink(link)) &&
                  link.elderId == user?.id &&
                  (link.caregiverId?.isNotEmpty ?? false) &&
                  link.caregiverId != user?.id)
              .toList(growable: false);

  bool canShareTask(CareTask task) =>
      api is TaskSharingApi &&
      isElder &&
      task.ownerId == user?.id &&
      task.accessMode == 'owner' &&
      !task.isReadOnly;

  CareTask? _shareTask(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) return task;
    }
    return taskSharePreviews[taskId];
  }

  bool _sharingSession(
          int sessionGeneration, String ownerId, int sharingGeneration) =>
      sessionGeneration == _sessionGeneration &&
      ownerId == user?.id &&
      isElder &&
      sharingGeneration == _taskSharingGeneration;

  bool _eligibleTaskRecipient(FamilyInvitation chosen) =>
      eligibleTaskSharingLinks.any((link) =>
          link.id == chosen.id &&
          link.caregiverId == chosen.caregiverId &&
          link.authorizationEpoch == chosen.authorizationEpoch);

  String _shareFingerprint(CareTask task, FamilyInvitation recipient) =>
      '${user?.id}\u0000${task.id}\u0000${task.contentHash}\u0000${recipient.id}';

  void _forgetTaskPreview(String taskId) {
    taskSharePreviews.remove(taskId);
    final prefix = '${user?.id}\u0000$taskId\u0000';
    _taskShareRetryKeys.removeWhere((key, _) => key.startsWith(prefix));
  }

  void _resetTaskSharing() {
    _taskSharingGeneration++;
    _taskRefreshGeneration++;
    taskDetails.clear();
    loadingTaskDetailIds.clear();
    taskDetailErrors.clear();
    _taskDetailRequests.clear();
    taskSharePreviews.clear();
    taskSharesByTask.clear();
    sharingTaskIds.clear();
    revokingTaskShareIds.clear();
    _taskShareRetryKeys.clear();
    _taskPreviewRequests.clear();
    _taskShareHistoryRequests.clear();
    taskSharingError = null;
  }

  Future<CareTask?> prepareTaskShare(String taskId) async {
    final existing = _shareTask(taskId);
    if (existing == null || !canShareTask(existing)) return null;
    final sessionGeneration = _sessionGeneration;
    final sharingGeneration = _taskSharingGeneration;
    final ownerId = user!.id;
    final request = (_taskPreviewRequests[taskId] ?? 0) + 1;
    _taskPreviewRequests[taskId] = request;
    _forgetTaskPreview(taskId);
    taskSharingError = null;
    notifyListeners();
    try {
      final fresh = await (api as TaskSharingApi).getTaskDetail(taskId);
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration) ||
          _taskPreviewRequests[taskId] != request) {
        return null;
      }
      if (fresh.id != taskId ||
          !canShareTask(fresh) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fresh.contentHash ?? '')) {
        throw const ApiException(
            'Current task content cannot be verified for sharing.');
      }
      taskSharePreviews[taskId] = fresh;
      tasks = [
        for (final task in tasks)
          if (task.id == taskId) fresh else task
      ];
      notifyListeners();
      return fresh;
    } on ApiException catch (error) {
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration) ||
          _taskPreviewRequests[taskId] != request) {
        return null;
      }
      taskSharingError = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<bool> confirmTaskShare(
      CareTask preview, FamilyInvitation recipient) async {
    if (!canShareTask(preview) ||
        !_eligibleTaskRecipient(recipient) ||
        !identical(taskSharePreviews[preview.id], preview) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(preview.contentHash ?? '') ||
        sharingTaskIds.contains(preview.id)) {
      return false;
    }
    final sessionGeneration = _sessionGeneration;
    final sharingGeneration = _taskSharingGeneration;
    final ownerId = user!.id;
    final fingerprint = _shareFingerprint(preview, recipient);
    final key = _taskShareRetryKeys.putIfAbsent(
        fingerprint,
        () =>
            'task-share-${DateTime.now().microsecondsSinceEpoch}-${++_taskSharingSequence}');
    sharingTaskIds.add(preview.id);
    taskSharingError = null;
    notifyListeners();
    try {
      final receipt = await (api as TaskSharingApi).createTaskShare(
          taskId: preview.id,
          familyLinkId: recipient.id,
          expectedContentHash: preview.contentHash!,
          idempotencyKey: key);
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration) ||
          !identical(taskSharePreviews[preview.id], preview) ||
          !_eligibleTaskRecipient(recipient)) {
        return false;
      }
      if (receipt.id.isEmpty ||
          receipt.taskId != preview.id ||
          receipt.familyLinkId != recipient.id ||
          receipt.sharedBy != ownerId ||
          receipt.contentHash != preview.contentHash ||
          (receipt.caregiverId != null &&
              receipt.caregiverId != recipient.caregiverId) ||
          (receipt.caregiverEmail.isNotEmpty &&
              familyCounterpartEmail(recipient).isNotEmpty &&
              receipt.caregiverEmail != familyCounterpartEmail(recipient)) ||
          !receipt.isActive) {
        throw const ApiException(
            'The task sharing receipt does not match your confirmation.');
      }
      _taskShareHistoryRequests[preview.id] =
          (_taskShareHistoryRequests[preview.id] ?? 0) + 1;
      taskSharesByTask[preview.id] = [
        for (final share in taskSharesByTask[preview.id] ?? <TaskShare>[])
          if (share.id != receipt.id) share,
        receipt,
      ];
      _forgetTaskPreview(preview.id);
      return true;
    } on ApiException catch (error) {
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration)) {
        return false;
      }
      taskSharingError = error.message;
      if (error.statusCode == 409 ||
          error.statusCode == 403 ||
          error.statusCode == 404) {
        _forgetTaskPreview(preview.id);
      }
      return false;
    } finally {
      if (_sharingSession(sessionGeneration, ownerId, sharingGeneration)) {
        sharingTaskIds.remove(preview.id);
        notifyListeners();
      }
    }
  }

  Future<bool> refreshTaskShares(String taskId) async {
    final task = _shareTask(taskId);
    if (task == null || !canShareTask(task)) return false;
    final sessionGeneration = _sessionGeneration;
    final sharingGeneration = _taskSharingGeneration;
    final ownerId = user!.id;
    final request = (_taskShareHistoryRequests[taskId] ?? 0) + 1;
    _taskShareHistoryRequests[taskId] = request;
    try {
      final receipts = await (api as TaskSharingApi).listTaskShares(taskId);
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration) ||
          _taskShareHistoryRequests[taskId] != request) {
        return false;
      }
      if (receipts.any(
          (share) => share.taskId != taskId || share.sharedBy != ownerId)) {
        throw const ApiException('Task sharing history could not be verified.');
      }
      taskSharesByTask[taskId] = receipts;
      taskSharingError = null;
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration) ||
          _taskShareHistoryRequests[taskId] != request) {
        return false;
      }
      taskSharingError = error.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> revokeTaskShare(CareTask task, TaskShare share) async {
    if (!canShareTask(task) ||
        share.taskId != task.id ||
        share.sharedBy != user?.id ||
        share.id.isEmpty ||
        revokingTaskShareIds.contains(share.id)) {
      return false;
    }
    final sessionGeneration = _sessionGeneration;
    final sharingGeneration = _taskSharingGeneration;
    final ownerId = user!.id;
    revokingTaskShareIds.add(share.id);
    taskSharingError = null;
    notifyListeners();
    try {
      final receipt = await (api as TaskSharingApi)
          .revokeTaskShare(taskId: task.id, shareId: share.id);
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration)) {
        return false;
      }
      if (receipt.id != share.id ||
          receipt.taskId != task.id ||
          receipt.sharedBy != ownerId ||
          receipt.familyLinkId != share.familyLinkId ||
          receipt.contentHash != share.contentHash ||
          receipt.revokedAt == null ||
          receipt.isActive) {
        throw const ApiException(
            'Stopping task sharing could not be verified.');
      }
      _taskShareHistoryRequests[task.id] =
          (_taskShareHistoryRequests[task.id] ?? 0) + 1;
      taskSharesByTask[task.id] = [
        for (final existing in taskSharesByTask[task.id] ?? <TaskShare>[])
          if (existing.id != share.id) existing,
        receipt,
      ];
      return true;
    } on ApiException catch (error) {
      if (!_sharingSession(sessionGeneration, ownerId, sharingGeneration)) {
        return false;
      }
      taskSharingError = error.message;
      return false;
    } finally {
      if (_sharingSession(sessionGeneration, ownerId, sharingGeneration)) {
        revokingTaskShareIds.remove(share.id);
        notifyListeners();
      }
    }
  }

  bool _taskVisibleToCurrentUser(CareTask task) {
    if (task.ownerId == user?.id) return true;
    if (isElder) return task.ownerId == null && !task.isReadOnly;
    return isCaregiver &&
        task.accessMode == 'shared_readonly' &&
        (task.shareId?.isNotEmpty ?? false);
  }

  void _clearSharedTaskDetails() {
    final ownIds = tasks
        .where((task) => task.ownerId == user?.id)
        .map((task) => task.id)
        .toSet();
    taskDetails.removeWhere((id, task) => task.ownerId != user?.id);
    loadingTaskDetailIds.removeWhere((id) => !ownIds.contains(id));
  }

  Future<void> invalidateTaskDetail(String taskId) async {
    ++_taskRefreshGeneration;
    _taskDetailRequests[taskId] = (_taskDetailRequests[taskId] ?? 0) + 1;
    taskDetails.remove(taskId);
    loadingTaskDetailIds.remove(taskId);
    taskDetailErrors.remove(taskId);
    if (isCaregiver) {
      tasks = tasks
          .where((task) => task.id != taskId || task.ownerId == user?.id)
          .toList(growable: false);
    }
    notifyListeners();
  }

  Future<void> refreshTaskDetail(String taskId) async {
    if (!isSignedIn ||
        api is! TaskSharingApi ||
        (isCaregiver && _familyAccessUncertain)) {
      return;
    }
    final sessionGeneration = _sessionGeneration;
    final sharingGeneration = _taskSharingGeneration;
    final ownerId = user!.id;
    final refreshGeneration = ++_taskRefreshGeneration;
    final request = (_taskDetailRequests[taskId] ?? 0) + 1;
    _taskDetailRequests[taskId] = request;
    taskDetails.remove(taskId);
    taskDetailErrors.remove(taskId);
    loadingTaskDetailIds.add(taskId);
    notifyListeners();
    bool current() =>
        sessionGeneration == _sessionGeneration &&
        user?.id == ownerId &&
        refreshGeneration == _taskRefreshGeneration &&
        _taskDetailRequests[taskId] == request;
    try {
      final fresh = await (api as TaskSharingApi).getTaskDetail(taskId);
      if (!current()) return;
      final owned = fresh.ownerId == ownerId &&
          fresh.accessMode == 'owner' &&
          !fresh.isReadOnly;
      final shared = isCaregiver &&
          fresh.ownerId != ownerId &&
          (fresh.ownerId?.isNotEmpty ?? false) &&
          fresh.accessMode == 'shared_readonly' &&
          (fresh.shareId?.isNotEmpty ?? false) &&
          (fresh.ownerDisplayName?.trim().isNotEmpty ?? false);
      if (fresh.id != taskId || (!owned && !shared)) {
        throw const ApiException('Current task access could not be verified.');
      }
      taskDetails[taskId] = fresh;
      tasks = [
        for (final task in tasks)
          if (task.id == taskId) fresh else task
      ];
    } on Object catch (error) {
      if (!current()) return;
      taskDetails.remove(taskId);
      taskDetailErrors[taskId] = _messageFor(error);
      if (isCaregiver) {
        tasks = tasks
            .where((task) => task.id != taskId || task.ownerId == ownerId)
            .toList(growable: false);
      }
    } finally {
      if (_taskDetailRequests[taskId] == request &&
          sessionGeneration == _sessionGeneration &&
          sharingGeneration == _taskSharingGeneration) {
        loadingTaskDetailIds.remove(taskId);
        notifyListeners();
      }
    }
  }

  Future<void> invalidateSharedTaskAccess() async {
    if (!isCaregiver) return;
    final sessionGeneration = _sessionGeneration;
    final ownerId = user!.id;
    final request = ++_taskRefreshGeneration;
    _clearSharedTaskDetails();
    tasks =
        tasks.where((task) => task.ownerId == ownerId).toList(growable: false);
    notifyListeners();
    try {
      await reminderScheduler?.syncDueTasks(ownerId, tasks);
    } on Object catch (error) {
      if (sessionGeneration == _sessionGeneration &&
          user?.id == ownerId &&
          request == _taskRefreshGeneration) {
        errorMessage = _messageFor(error);
        notifyListeners();
      }
    }
  }

  Future<void> refreshTasks({bool silent = true}) async {
    if (!isSignedIn || (isCaregiver && _familyAccessUncertain)) return;
    final sessionGeneration = _sessionGeneration;
    final ownerId = user!.id;
    final request = ++_taskRefreshGeneration;
    if (isCaregiver) {
      _clearSharedTaskDetails();
      tasks = tasks
          .where((task) => task.ownerId == ownerId)
          .toList(growable: false);
    }
    if (!silent) errorMessage = null;
    notifyListeners();
    try {
      try {
        await reminderScheduler?.syncDueTasks(ownerId, tasks);
      } on Object catch (error) {
        if (sessionGeneration == _sessionGeneration &&
            user?.id == ownerId &&
            request == _taskRefreshGeneration) {
          errorMessage = _messageFor(error);
          notifyListeners();
        }
      }
      if (sessionGeneration != _sessionGeneration ||
          user?.id != ownerId ||
          request != _taskRefreshGeneration) {
        return;
      }
      final loaded = await api.listTasks();
      if (sessionGeneration != _sessionGeneration ||
          user?.id != ownerId ||
          request != _taskRefreshGeneration) {
        return;
      }
      tasks = loaded.where(_taskVisibleToCurrentUser).toList(growable: false);
      notifyListeners();
      await reminderScheduler?.syncDueTasks(ownerId, tasks);
    } on Object catch (error) {
      if (sessionGeneration != _sessionGeneration ||
          user?.id != ownerId ||
          request != _taskRefreshGeneration) {
        return;
      }
      errorMessage = _messageFor(error);
      notifyListeners();
    }
  }

  bool canUpdateTask(CareTask task) =>
      isSignedIn &&
      !task.isReadOnly &&
      (task.ownerId == user?.id || (task.ownerId == null && isElder));

  Future<bool> updateTaskStatus(CareTask task, TaskStatus status) async {
    if (!canUpdateTask(task)) return false;
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
      try {
        await reminderScheduler?.syncDueTasks(user!.id, tasks);
      } on Object catch (error) {
        errorMessage = _messageFor(error);
      }
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
        try {
          await reminderScheduler?.syncDueTasks(user!.id, tasks);
        } on Object catch (error) {
          errorMessage = _messageFor(error);
        }
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

  Future<bool> acceptInvitation(FamilyInvitation invitation,
      {String? token}) async {
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
      invitations = [
        for (final item in invitations)
          if (item.id != invitation.id && item.id != accepted.id) item
      ];
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
    if (session == null) return false;
    _invalidateFamilyAccess();
    final pairGeneration = familyConnectionGeneration;
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
      if (generation != _sessionGeneration ||
          session == null ||
          pairGeneration != familyConnectionGeneration) {
        return false;
      }
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
      links = [
        for (final item in links)
          if (item.id != invitation.id) item
      ];
      if (isCaregiver && invitation.status == InvitationStatus.accepted) {
        await invalidateSharedTaskAccess();
        await refreshTasks();
      } else if (isElder) {
        _resetTaskSharing();
      }
      if (generation != _sessionGeneration ||
          session == null ||
          pairGeneration != familyConnectionGeneration) {
        return false;
      }
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (!_familyCurrent(generation, pairGeneration)) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      if (_familyCurrent(generation, pairGeneration)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshMemories({bool silent = false}) async {
    if (!isElder) return;
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await api.listMemories();
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      memories = loaded;
      memorySearchResults = const [];
      memoryRetrievalMode = null;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (!silent && _memoryCurrent(generation, mutationGeneration)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<MemorySearchResult?> searchMemories(String query) async {
    if (!isElder || query.trim().isEmpty) return null;
    if (_memoryReadsBlocked || _memoryCardSave != null) return null;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await api.searchMemories(query: query.trim());
      if (!_memoryCurrent(generation, mutationGeneration)) return null;
      memorySearchResults = result.items;
      memoryRetrievalMode = result.retrievalMode;
      notifyListeners();
      return result;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return null;
      errorMessage = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<bool> createMemory({
    required String content,
    String kind = 'experience',
    String? sourceMessageId,
    int? expectedRevision,
  }) async {
    if (!isElder || content.trim().isEmpty) return false;
    final revision = api is MemoryControlApi
        ? expectedRevision
        : (expectedRevision ?? memoryRevision);
    if (!_hasMemoryRevision(revision)) return false;
    _invalidateMemoryDerived();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final created = await (api is MemoryControlApi
          ? (api as MemoryControlApi).createMemoryAtRevision(
              content: content.trim(),
              kind: kind,
              sourceMessageId: sourceMessageId,
              expectedRevision: revision!,
            )
          : api.createMemory(
              content: content.trim(),
              kind: kind,
              sourceMessageId: sourceMessageId,
            ));
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      _acceptMemoryRevision(created.revision);
      memories = [
        created,
        ...memories.where((memory) => memory.id != created.id)
      ];
      memorySearchResults = [
        for (final memory in memorySearchResults)
          if (memory.id != created.id) memory,
      ];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> confirmMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    if (!_hasMemoryRevision(memory.revision)) return false;
    return _runMemoryUpdate(
      memory.id,
      () => api is MemoryControlApi
          ? (api as MemoryControlApi).confirmMemoryAtRevision(memory.id,
              expectedRevision: memory.revision!)
          : api.confirmMemory(memory.id),
    );
  }

  Future<bool> editMemory(MemoryRecord memory, String content) async {
    final trimmed = content.trim();
    if (!isElder || trimmed.isEmpty || updatingMemoryIds.contains(memory.id)) {
      return false;
    }
    if (!_hasMemoryRevision(memory.revision)) return false;
    return _runMemoryUpdate(
      memory.id,
      () => api is MemoryControlApi
          ? (api as MemoryControlApi).updateMemoryAtRevision(memory.id,
              expectedRevision: memory.revision!, content: trimmed)
          : api.updateMemory(memory.id, content: trimmed),
    );
  }

  Future<bool> suppressMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    if (!_hasMemoryRevision(memory.revision)) return false;
    return _runMemoryUpdate(
      memory.id,
      () => api is MemoryControlApi
          ? (api as MemoryControlApi).updateMemoryAtRevision(memory.id,
              expectedRevision: memory.revision!, suppressed: true)
          : api.updateMemory(memory.id, suppressed: true),
    );
  }

  Future<bool> restoreMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    if (!_hasMemoryRevision(memory.revision)) return false;
    return _runMemoryUpdate(
      memory.id,
      () => api is MemoryControlApi
          ? (api as MemoryControlApi).updateMemoryAtRevision(memory.id,
              expectedRevision: memory.revision!, suppressed: false)
          : api.updateMemory(memory.id, suppressed: false),
    );
  }

  Future<bool> deleteMemory(MemoryRecord memory) async {
    if (!isElder || updatingMemoryIds.contains(memory.id)) return false;
    if (api is MemoryControlApi) {
      if (!_hasMemoryRevision(memory.revision)) return false;
      final preview =
          await prepareMemoryDeletion(mode: 'selected', memoryIds: [memory.id]);
      return preview != null && await confirmMemoryDeletion(preview);
    }
    _invalidateMemoryDerived();
    final generation = _sessionGeneration;
    updatingMemoryIds.add(memory.id);
    errorMessage = null;
    notifyListeners();
    try {
      await api.deleteMemory(memory.id);
      if (generation != _sessionGeneration || session == null) return false;
      _catalogConsentGeneration++;
      catalogRecommendations = const [];
      memories = [
        for (final item in memories)
          if (item.id != memory.id) item
      ];
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
    _invalidateMemoryDerived();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    updatingMemoryIds.add(memoryId);
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await operation();
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      _acceptMemoryRevision(updated.revision);
      _catalogConsentGeneration++;
      catalogRecommendations = const [];
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
              !story.memoryIds.contains(updated.id))
            story,
      ];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      if (generation == _sessionGeneration) {
        updatingMemoryIds.remove(memoryId);
        notifyListeners();
      }
    }
  }

  Future<void> refreshStories({bool silent = false}) async {
    if (!isElder) return;
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await api.listStories();
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      stories = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (!silent && _memoryCurrent(generation, mutationGeneration)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  MemoryRecord? _memoryCardSource(String id, int revision) {
    // Current list takes precedence over an older search hit for the same ID.
    final current = memories.where((m) => m.id == id).toList();
    final matches = current.isNotEmpty
        ? current
        : memorySearchResults.where((m) => m.id == id).toList();
    if (matches.length != 1) return null;
    final source = matches.single;
    return source.status == 'confirmed' &&
            !source.suppressed &&
            (source.revision == revision ||
                (api is! MemoryControlApi &&
                    source.revision == null &&
                    revision == 0))
        ? source
        : null;
  }

  /// Captures a RAM-only guard for the manual composer before its dialog opens.
  MemoryCardDraft? prepareStoryCreateDraft({
    String title = '',
    String content = '',
    List<String> memoryIds = const [],
  }) {
    final revision = memoryRevision ?? (api is MemoryControlApi ? null : 0);
    if (!isElder ||
        _memoryReadsBlocked ||
        _memoryCardSave != null ||
        revision == null ||
        memoryIds.toSet().length != memoryIds.length ||
        memoryIds.any((id) => _memoryCardSource(id, revision) == null)) {
      return null;
    }
    return MemoryCardDraft._(
        ownerId: user!.id,
        sessionGeneration: _sessionGeneration,
        mutationGeneration: _memoryMutationGeneration,
        revision: revision,
        title: title,
        content: content,
        memoryIds: memoryIds,
        controller: this,
        session: session!,
        manualComposition: true);
  }

  MemoryCardDraft? prepareMemoryCardDraft(MemoryRecord memory) {
    final revision = memory.revision;
    if (!isElder ||
        _memoryReadsBlocked ||
        _memoryCardSave != null ||
        revision == null ||
        revision < 0 ||
        (memoryRevision != null && memoryRevision != revision) ||
        memory.status != 'confirmed' ||
        memory.suppressed) {
      return null;
    }
    final source = _memoryCardSource(memory.id, revision);
    if (source == null || source.content != memory.content) {
      return null;
    }
    final paragraph =
        source.content.trim().split(RegExp(r'\n\s*\n')).first.trim();
    if (paragraph.isEmpty) {
      return null;
    }
    final title = String.fromCharCodes(paragraph.runes.take(240));
    return MemoryCardDraft._(
        ownerId: user!.id,
        sessionGeneration: _sessionGeneration,
        mutationGeneration: _memoryMutationGeneration,
        revision: revision,
        title: title,
        content: source.content,
        memoryIds: [source.id],
        controller: this,
        session: session!);
  }

  MemoryCardDraft? prepareStoryEditDraft(StoryRecord story) {
    final revision = story.revision;
    if (!isElder ||
        api is! StoryEditApi ||
        _memoryReadsBlocked ||
        _memoryCardSave != null ||
        revision == null ||
        revision < 0 ||
        (memoryRevision != null && memoryRevision != revision) ||
        story.memoryIds.toSet().length != story.memoryIds.length) {
      return null;
    }
    final current = stories.where((s) => s.id == story.id).toList();
    if (current.length != 1 ||
        current.single.revision != revision ||
        current.single.title != story.title ||
        current.single.content != story.content ||
        !listEquals(current.single.memoryIds, story.memoryIds) ||
        story.memoryIds.any((id) => _memoryCardSource(id, revision) == null)) {
      return null;
    }
    return MemoryCardDraft._(
        ownerId: user!.id,
        sessionGeneration: _sessionGeneration,
        mutationGeneration: _memoryMutationGeneration,
        revision: revision,
        storyId: story.id,
        title: story.title,
        content: story.content,
        memoryIds: story.memoryIds,
        controller: this,
        session: session!);
  }

  bool isMemoryCardDraftCurrent(MemoryCardDraft draft) {
    if (!identical(draft._controller, this) ||
        draft._saved ||
        !isElder ||
        !identical(draft._session, session) ||
        draft.ownerId != user?.id ||
        !_memoryCurrent(
            draft.sessionGeneration, draft._currentMutationGeneration) ||
        (memoryRevision != null && memoryRevision != draft.revision) ||
        draft.memoryIds
            .any((id) => _memoryCardSource(id, draft.revision) == null)) {
      return false;
    }
    if (draft.storyId != null) {
      final current = stories.where((s) => s.id == draft.storyId).toList();
      if (current.length != 1 ||
          current.single.revision != draft.revision ||
          !listEquals(current.single.memoryIds, draft.memoryIds) ||
          current.single.title != draft.title ||
          current.single.content != draft.content) {
        return false;
      }
    }
    return true;
  }

  Future<bool> saveMemoryCardDraft(MemoryCardDraft draft,
      {required String title, required String content}) async {
    if (_memoryCardSave != null ||
        !isMemoryCardDraftCurrent(draft) ||
        title.trim().isEmpty ||
        content.trim().isEmpty ||
        title.trim().runes.length > 240 ||
        content.trim().runes.length > 30000 ||
        (draft.storyId != null && api is! StoryEditApi) ||
        (draft.storyId == null &&
            api is! MemoryControlApi &&
            !draft._manualComposition)) {
      return false;
    }
    // Invalidate earlier reads and other drafts, but preserve this RAM draft
    // and its original revision even when the server result is uncertain.
    final searchSources = memorySearchResults;
    _invalidateMemoryDerived();
    memorySearchResults = searchSources;
    draft._currentMutationGeneration = _memoryMutationGeneration;
    _memoryCardSave = draft;
    final mutation = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    bool current() =>
        identical(_memoryCardSave, draft) &&
        identical(session, draft._session) &&
        user?.id == draft.ownerId &&
        _memoryCurrent(generation, mutation);
    loading = true;
    errorMessage = null;
    notifyListeners();
    try {
      // Listeners can synchronously switch sessions or start a mutation.
      if (!current()) {
        return false;
      }
      final saved = draft.storyId == null
          ? api is MemoryControlApi
              ? await (api as MemoryControlApi).createStoryAtRevision(
                  title: title.trim(),
                  content: content.trim(),
                  memoryIds: draft.memoryIds,
                  expectedRevision: draft.revision)
              : await api.createStory(
                  title: title.trim(),
                  content: content.trim(),
                  memoryIds: draft.memoryIds)
          : await (api as StoryEditApi).updateStoryAtRevision(draft.storyId!,
              title: title.trim(),
              content: content.trim(),
              expectedRevision: draft.revision);
      if (!current()) {
        return false;
      }
      if (saved.id.isEmpty ||
          saved.title != title.trim() ||
          saved.content != content.trim() ||
          saved.memoryIds.toSet().length != saved.memoryIds.length ||
          ((api is MemoryControlApi || draft.storyId != null) &&
              (saved.revision == null || saved.revision! <= draft.revision)) ||
          (draft.storyId != null && saved.id != draft.storyId) ||
          !setEquals(saved.memoryIds.toSet(), draft.memoryIds.toSet())) {
        throw const ApiException('Invalid saved memory card response.');
      }
      draft._saved = true;
      _acceptMemoryRevision(saved.revision);
      stories = [saved, ...stories.where((s) => s.id != saved.id)];
      familyMessages = const [];
      notifyListeners();
      if (api is MemoryControlApi) {
        try {
          final sources = await api.listMemories();
          if (!current()) return false;
          // Refresh real source records; never relabel stale records with the
          // new revision simply to make a subsequent draft pass validation.
          if (sources.every((source) => source.revision == saved.revision)) {
            memories = sources;
            memorySearchResults = const [];
            notifyListeners();
          }
        } on Object {
          // The card save is confirmed. A failed source read does not undo it.
          if (!current()) return false;
        }
      }
      return true;
    } on Object catch (error) {
      if (!current()) {
        return false;
      }
      errorMessage = _messageFor(error);
      notifyListeners();
      return false;
    } finally {
      if (current()) {
        _memoryCardSave = null;
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> createStory({
    required String title,
    required String content,
    List<String> memoryIds = const [],
    int? expectedRevision,
  }) async {
    if (!isElder || title.trim().isEmpty || content.trim().isEmpty) {
      return false;
    }
    final revision = api is MemoryControlApi
        ? expectedRevision
        : (expectedRevision ?? memoryRevision);
    if (!_hasMemoryRevision(revision)) return false;
    _invalidateMemoryDerived();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    loading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final created = await (api is MemoryControlApi
          ? (api as MemoryControlApi).createStoryAtRevision(
              title: title.trim(),
              content: content.trim(),
              memoryIds: memoryIds,
              expectedRevision: revision!,
            )
          : api.createStory(
              title: title.trim(),
              content: content.trim(),
              memoryIds: memoryIds,
            ));
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      _acceptMemoryRevision(created.revision);
      stories = [created, ...stories.where((story) => story.id != created.id)];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      if (_memoryCurrent(generation, mutationGeneration)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> deleteStory(StoryRecord story) async {
    if (!isElder || updatingStoryIds.contains(story.id)) return false;
    if (!_hasMemoryRevision(story.revision)) return false;
    _invalidateMemoryDerived();
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    updatingStoryIds.add(story.id);
    errorMessage = null;
    notifyListeners();
    try {
      if (api is MemoryControlApi) {
        await (api as MemoryControlApi)
            .deleteStoryAtRevision(story.id, expectedRevision: story.revision!);
      } else {
        await api.deleteStory(story.id);
      }
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      if (api is MemoryControlApi) memoryControlState = null;
      familyMessages = const [];
      stories = [
        for (final item in stories)
          if (item.id != story.id) item
      ];
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      if (generation == _sessionGeneration) {
        updatingStoryIds.remove(story.id);
        notifyListeners();
      }
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
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await api.listFamilyMessages();
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      familyMessages = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration)) return;
      if (supportsFamilyConnections &&
          (error.statusCode == 403 || error.statusCode == 410)) {
        _invalidateFamilyAccess();
      }
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (!silent && _memoryCurrent(generation, mutationGeneration)) {
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
    if (sourceStory != null && !_hasMemoryRevision(sourceStory.revision)) {
      return false;
    }
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final senderUserId = user?.id;
    if (senderUserId == null || senderUserId.isEmpty) return false;
    final storageRecipientId = supportsFamilyConnections
        ? '$recipientId@link:${link.id}@epoch:${link.authorizationEpoch}'
        : recipientId;
    final operationKey =
        '$storageRecipientId::${sourceStory?.id ?? ''}::$trimmed';
    if (_sendingFamilyMessageKeys.contains(operationKey)) return false;
    _sendingFamilyMessageKeys.add(operationKey);
    var clientMessageId = _familyMessageClientIds[operationKey];
    clientMessageId ??= await sessionStore.readFamilyMessageClientId(
      recipientId: storageRecipientId,
      sourceStoryId: sourceStory?.id,
      content: trimmed,
      userId: senderUserId,
    );
    if (!_memoryCurrent(generation, mutationGeneration) ||
        session?.user.id != senderUserId) {
      if (generation == _sessionGeneration &&
          mutationGeneration == _memoryMutationGeneration &&
          user?.id == senderUserId) {
        _sendingFamilyMessageKeys.remove(operationKey);
      }
      return false;
    }
    clientMessageId ??= _newClientId('family-message');
    _familyMessageClientIds[operationKey] = clientMessageId;
    await sessionStore.saveFamilyMessageClientId(
      recipientId: storageRecipientId,
      sourceStoryId: sourceStory?.id,
      content: trimmed,
      clientId: clientMessageId,
      userId: senderUserId,
    );
    if (!_memoryCurrent(generation, mutationGeneration) ||
        session?.user.id != senderUserId) {
      if (generation == _sessionGeneration &&
          mutationGeneration == _memoryMutationGeneration &&
          user?.id == senderUserId) {
        _sendingFamilyMessageKeys.remove(operationKey);
      }
      return false;
    }
    errorMessage = null;
    loading = true;
    notifyListeners();
    try {
      final message = await (api is FamilyMessagePreviewApi
          ? (api as FamilyMessagePreviewApi).sendFamilyMessageForPreview(
              recipientId: recipientId,
              content: trimmed,
              clientMessageId: clientMessageId,
              familyLinkId: link.id,
              expectedAuthorizationEpoch: link.authorizationEpoch!,
              sourceStoryId: sourceStory?.id,
              expectedRevision: sourceStory?.revision,
            )
          : sourceStory != null && api is MemoryControlApi
              ? (api as MemoryControlApi).sendFamilyMessageAtRevision(
                  recipientId: recipientId,
                  content: trimmed,
                  clientMessageId: clientMessageId,
                  sourceStoryId: sourceStory.id,
                  expectedRevision: sourceStory.revision!,
                )
              : api.sendFamilyMessage(
                  recipientId: recipientId,
                  content: trimmed,
                  clientMessageId: clientMessageId,
                  sourceStoryId: sourceStory?.id,
                ));
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      familyMessages = [
        ...familyMessages.where((item) => item.id != message.id),
        message,
      ];
      _familyMessageClientIds.remove(operationKey);
      await sessionStore.clearFamilyMessageClientId(
        recipientId: storageRecipientId,
        sourceStoryId: sourceStory?.id,
        content: trimmed,
        userId: senderUserId,
      );
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      // Keep the operation id so a retry is idempotent after a timeout or
      // transient 5xx response.
      if (!_memoryCurrent(generation, mutationGeneration)) return false;
      if (supportsFamilyConnections &&
          (error.statusCode == 403 || error.statusCode == 410)) {
        _invalidateFamilyAccess();
      }
      errorMessage = error.message;
      notifyListeners();
      return false;
    } finally {
      if (generation == _sessionGeneration &&
          mutationGeneration == _memoryMutationGeneration &&
          user?.id == senderUserId) {
        _sendingFamilyMessageKeys.remove(operationKey);
      }
      if (_memoryCurrent(generation, mutationGeneration)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  // --- Community discovery (FR CMT 01-05) ---

  Future<void> refreshCatalogActivities({
    bool silent = false,
    String? district,
    String? interest,
  }) async {
    if (api is! CatalogScamApi || session == null) return;
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final requestGeneration = ++_catalogActivitiesGeneration;
    if (!silent || _catalogActivitiesLoadingGeneration != null) {
      _catalogActivitiesLoadingGeneration = requestGeneration;
    }
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await (api as CatalogScamApi).listCatalogActivities(
        district: district,
        interest: interest,
      );
      if (!_memoryCurrent(generation, mutationGeneration) ||
          session == null ||
          requestGeneration != _catalogActivitiesGeneration) {
        return;
      }
      catalogActivities = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration) ||
          session == null ||
          requestGeneration != _catalogActivitiesGeneration) {
        return;
      }
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (generation == _sessionGeneration &&
          _catalogActivitiesLoadingGeneration == requestGeneration) {
        _catalogActivitiesLoadingGeneration = null;
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshCatalogRecommendations({bool silent = false}) async {
    if (api is! CatalogScamApi || !isElder) return;
    if (_memoryReadsBlocked || _memoryCardSave != null) return;
    final mutationGeneration = _memoryMutationGeneration;
    final generation = _sessionGeneration;
    final consentGeneration = ++_catalogConsentGeneration;
    catalogRecommendations = const [];
    if (!silent || _catalogLoadingGeneration != null) {
      _catalogLoadingGeneration = consentGeneration;
    }
    if (!silent) {
      loading = true;
      errorMessage = null;
    }
    notifyListeners();
    try {
      final loaded = await (api as CatalogScamApi).catalogRecommendations();
      if (!_memoryCurrent(generation, mutationGeneration) ||
          session == null ||
          consentGeneration != _catalogConsentGeneration) {
        return;
      }
      catalogRecommendations = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_memoryCurrent(generation, mutationGeneration) ||
          session == null ||
          consentGeneration != _catalogConsentGeneration) {
        return;
      }
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (generation == _sessionGeneration &&
          _catalogLoadingGeneration == consentGeneration) {
        _catalogLoadingGeneration = null;
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> expressInterest(CatalogActivity activity) async {
    if (api is! CatalogScamApi || !isElder || !activity.available) return false;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      await (api as CatalogScamApi).expressCommunityInterest(activity.id);
      if (generation != _sessionGeneration || session == null) return false;
      await refreshCatalogInterests(silent: true);
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> withdrawInterest(CatalogActivity activity) async {
    if (api is! CatalogScamApi || !isElder) return false;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      await (api as CatalogScamApi).withdrawCommunityInterest(activity.id);
      if (generation != _sessionGeneration || session == null) return false;
      await refreshCatalogInterests(silent: true);
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> refreshCatalogInterests({bool silent = false}) async {
    if (api is! CatalogScamApi || !isElder) return;
    final generation = _sessionGeneration;
    try {
      final loaded = await (api as CatalogScamApi).listCommunityInterests();
      if (generation != _sessionGeneration || session == null) return;
      catalogInterests = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return;
      if (!silent) errorMessage = error.message;
      notifyListeners();
    }
  }

  // --- Scam safety (FR SCM 01-04) ---

  Future<void> refreshScamResources({bool silent = false}) async {
    if (api is! CatalogScamApi || session == null) return;
    final generation = _sessionGeneration;
    if (!silent) {
      loading = true;
      errorMessage = null;
      notifyListeners();
    }
    try {
      final loaded = await (api as CatalogScamApi).listScamResources();
      if (generation != _sessionGeneration || session == null) return;
      scamResources = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return;
      errorMessage = error.message;
      notifyListeners();
    } finally {
      if (!silent) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<List<ScamResource>> searchScamResources(String query) async {
    if (api is! CatalogScamApi || session == null || query.trim().isEmpty) {
      return const [];
    }
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      final results =
          await (api as CatalogScamApi).searchScamResources(query.trim());
      if (generation != _sessionGeneration || session == null) return const [];
      return results;
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return const [];
      errorMessage = error.message;
      notifyListeners();
      return const [];
    }
  }

  Future<void> refreshVerifyActions({bool silent = true}) async {
    if (api is! CatalogScamApi || session == null) return;
    final generation = _sessionGeneration;
    try {
      final loaded = await (api as CatalogScamApi).getVerifyActions();
      if (generation != _sessionGeneration || session == null) return;
      verifyActions = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return;
      if (!silent) errorMessage = error.message;
      notifyListeners();
    }
  }

  Future<void> refreshScamContacts({bool silent = true}) async {
    if (api is! CatalogScamApi || session == null) return;
    final generation = _sessionGeneration;
    try {
      final loaded = await (api as CatalogScamApi).getScamContacts();
      if (generation != _sessionGeneration || session == null) return;
      scamContacts = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return;
      if (!silent) errorMessage = error.message;
      notifyListeners();
    }
  }

  Future<bool> logScamGuidance({
    required String scamType,
    required String guidanceSummary,
    String? scamResourceId,
    String? conversationId,
  }) async {
    if (api is! CatalogScamApi || !isElder) return false;
    final generation = _sessionGeneration;
    errorMessage = null;
    notifyListeners();
    try {
      await (api as CatalogScamApi).logScamGuidance(
        scamType: scamType,
        guidanceSummary: guidanceSummary,
        scamResourceId: scamResourceId,
        conversationId: conversationId,
      );
      if (generation != _sessionGeneration || session == null) return false;
      await refreshScamLogs(silent: true);
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return false;
      errorMessage = error.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> refreshScamLogs({bool silent = true}) async {
    if (api is! CatalogScamApi || !isElder) return;
    final generation = _sessionGeneration;
    try {
      final loaded = await (api as CatalogScamApi).listScamLogs();
      if (generation != _sessionGeneration || session == null) return;
      scamLogs = loaded;
      notifyListeners();
    } on ApiException catch (error) {
      if (generation != _sessionGeneration || session == null) return;
      if (!silent) errorMessage = error.message;
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
