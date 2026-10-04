import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'answer_card_api.dart';
import 'answer_card_export_api.dart';
export 'answer_card_export_api.dart';
import 'answer_card_sharing_api.dart';
export 'answer_card_sharing_api.dart';

export 'answer_card_api.dart';
import 'family_connection_api.dart';
export 'family_connection_api.dart';
import 'care_features_api.dart';
import 'care_models.dart';
export 'care_features_api.dart';
import 'group_models.dart';

/// The server origin is replaceable at build/run time:
/// `flutter run --dart-define=API_ORIGIN=http://10.0.2.2:8000`.
const defaultApiOrigin = String.fromEnvironment(
  'API_ORIGIN',
  defaultValue: String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  ),
);

abstract class AnxinApi {
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  });

  Future<AuthSession> login({
    required String email,
    required String password,
  });

  Future<AppUser> currentUser();

  Future<void> logout();

  Future<List<Conversation>> listConversations();

  Future<List<ChatMessage>> listMessages(String conversationId);

  Future<Conversation> createConversation({String? title});

  Future<SendMessageResult> sendMessage({
    required String conversationId,
    required String content,
    required String clientMessageId,
  });

  Future<CareTask> updateTask({
    required String taskId,
    required TaskStatus status,
  });

  Future<List<CareTask>> listTasks();

  Future<CareTask?> confirmAction({
    required String actionId,
    required String clientActionId,
  });

  Future<void> dismissAction({required String actionId});

  Future<FamilyInvitation> createInvitation({
    required String email,
    List<String> scopes = const ['care_tasks'],
  });

  Future<List<FamilyInvitation>> listInvitations();

  Future<List<FamilyInvitation>> listLinks();

  Future<FamilyInvitation> acceptInvitation({
    required String invitationId,
    required String token,
  });

  Future<void> revokeInvitation({required String invitationId});

  Future<void> revokeLink({required String linkId});

  Future<List<ActionProposal>> listActions(String conversationId);

  Future<List<MemoryRecord>> listMemories();

  Future<MemoryRecord> createMemory({
    required String content,
    required String kind,
    String? sourceMessageId,
  });

  Future<MemoryRecord> confirmMemory(String memoryId);

  Future<MemoryRecord> updateMemory(
    String memoryId, {
    String? content,
    bool? suppressed,
  });

  Future<void> deleteMemory(String memoryId);

  Future<MemorySearchResult> searchMemories({
    required String query,
    int? limit,
  });

  Future<List<StoryRecord>> listStories();

  Future<StoryRecord> createStory({
    required String title,
    required String content,
    required List<String> memoryIds,
  });

  Future<void> deleteStory(String storyId);

  Future<ResourceSearchResult> searchResources({
    required String query,
    int? limit,
  });

  Future<List<FamilyMessage>> listFamilyMessages();

  Future<FamilyMessage> sendFamilyMessage({
    required String recipientId,
    required String content,
    required String clientMessageId,
    String? sourceStoryId,
  });
}

/// Optional release features. Kept separate so existing test doubles and
/// alternate API implementations can continue to focus on the core contract.
abstract interface class GuestApi {
  Future<GuestSession> startGuestSession();
  Future<GuestReply> sendGuestMessage(String sessionId, String content);
  Future<void> endGuestSession(String sessionId);
}

abstract interface class ConsentApi {
  Future<bool> getMemoryConsent();
  Future<bool> setMemoryConsent(bool enabled);
}

abstract interface class MemoryControlApi {
  Future<MemoryControlState> getMemoryControlState();
  Future<MemoryControlState> setMemoryConsentAtRevision(bool enabled,
      {required int expectedRevision});
  Future<MemoryRecord> createMemoryAtRevision(
      {required String content,
      required String kind,
      String? sourceMessageId,
      required int expectedRevision});
  Future<MemoryRecord> saveConfirmedMemoryAtRevision(
      {required String content,
      required String kind,
      String? sourceMessageId,
      String? topicKey,
      required int expectedRevision});
  Future<MemoryRecord> confirmMemoryAtRevision(String memoryId,
      {required int expectedRevision});
  Future<MemoryRecord> updateMemoryAtRevision(String memoryId,
      {String? content, bool? suppressed, required int expectedRevision});
  Future<void> deleteMemoryAtRevision(String memoryId,
      {required int expectedRevision, required String idempotencyKey});
  Future<MemoryDeletionReceipt> deleteMemories(
      {required String mode,
      List<String> memoryIds = const [],
      required int expectedRevision,
      required String idempotencyKey});
  Future<List<SkillSuggestion>> listSkillSuggestionsAtRevision(
      {required int expectedRevision});
  Future<SkillSuggestion> decideSkillAtRevision(String id,
      {required String decision, String? skill, required int expectedRevision});
  Future<StoryRecord> createStoryAtRevision(
      {required String title,
      required String content,
      required List<String> memoryIds,
      required int expectedRevision});
  Future<void> deleteStoryAtRevision(String storyId,
      {required int expectedRevision});
  Future<FamilyMessage> sendFamilyMessageAtRevision(
      {required String recipientId,
      required String content,
      required String clientMessageId,
      required String sourceStoryId,
      required int expectedRevision});
}

/// Optional private card editing; existing core API doubles remain compatible.
abstract interface class StoryEditApi {
  Future<StoryRecord> updateStoryAtRevision(
    String storyId, {
    required String title,
    required String content,
    required int expectedRevision,
  });
}

abstract interface class MemorySaveApi {
  Future<MemoryRecord> saveConfirmedMemory(
      {required String content,
      required String kind,
      String? sourceMessageId,
      String? topicKey});
}

abstract interface class GuestResourceApi {
  Future<ResourceSearchResult> searchGuestResources(
      {required String query, int? limit});
}

abstract interface class CommunityApi {
  Future<List<CommunityActivity>> listCommunityActivities();
  Future<CommunitySearchResult<CommunityActivity>> searchCommunityActivities(
      {String? topic, String? area});
  Future<List<SkillSuggestion>> listSkillSuggestions();
  Future<SkillSuggestion> decideSkill(String id,
      {required String decision, String? skill});
  Future<List<CommunityOpportunity>> listOpportunities(String skillId);
  Future<CommunitySearchResult<CommunityOpportunity>> searchOpportunities(
      String skillId);
}

/// Optional item-level sharing capability; legacy AnxinApi implementations
/// remain usable without exposing task sharing controls.
abstract interface class TaskSharingApi {
  Future<CareTask> getTaskDetail(String taskId);
  Future<List<TaskShare>> listTaskShares(String taskId);
  Future<TaskShare> createTaskShare({
    required String taskId,
    required String familyLinkId,
    required String expectedContentHash,
    required String idempotencyKey,
  });
  Future<TaskShare> revokeTaskShare({
    required String taskId,
    required String shareId,
  });
}

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  bool get isNetworkError => statusCode == null;

  @override
  String toString() => message;
}

abstract interface class HumanGroupApi {
  Future<List<HumanGroup>> listHumanGroups();
  Future<List<HumanGroupInvitation>> listHumanGroupInvitations();
  Future<HumanGroup> createHumanGroup(String title);
  Future<HumanGroupInvitation> inviteHumanGroupMember(
      String groupId, String email);
  Future<HumanGroup> acceptHumanGroupInvitation(String invitationId);
  Future<void> declineHumanGroupInvitation(String invitationId);
  Future<List<HumanGroupMember>> listHumanGroupMembers(String groupId);
  Future<List<HumanGroupMessage>> listHumanGroupMessages(String groupId);
  Stream<HumanGroupLiveEvent> watchHumanGroupMessages(String groupId);
  Future<HumanGroupMessage> sendHumanGroupMessage(
      String groupId, String content, String clientMessageId);
  Future<void> leaveHumanGroup(String groupId);
  Future<void> closeHumanGroup(String groupId);
  Future<void> reportHumanGroup(String groupId, String reason);
  Future<void> blockHumanGroupInvitations(String accountId);
}

abstract interface class CatalogScamApi {
  // --- Community discovery (FR CMT 01-05) ---

  Future<List<CatalogActivity>> listCatalogActivities({
    String? district,
    String? interest,
    String? contributionType,
  });

  Future<List<CatalogActivity>> catalogRecommendations();

  Future<void> expressCommunityInterest(String activityId);

  Future<List<CatalogActivity>> listCommunityInterests();

  Future<void> withdrawCommunityInterest(String activityId);

  // --- Scam safety (FR SCM 01-04) ---

  Future<List<ScamResource>> listScamResources({String? scamType});

  Future<List<ScamResource>> searchScamResources(String query);

  Future<List<VerifyAction>> getVerifyActions();

  Future<List<ScamContact>> getScamContacts();

  Future<void> logScamGuidance({
    required String scamType,
    required String guidanceSummary,
    String? scamResourceId,
    String? conversationId,
  });

  Future<List<ScamLogEntry>> listScamLogs();
}

class RestApiClient
    implements
        AnxinApi,
        AnswerCardApi,
        AnswerCardExportApi,
        AnswerCardSharingApi,
        GuestApi,
        ConsentApi,
        CommunityApi,
        MemorySaveApi,
        MemoryControlApi,
        StoryEditApi,
        GuestResourceApi,
        HumanGroupApi,
        CareFeaturesApi,
        CatalogScamApi,
        TaskSharingApi,
        FamilyConnectionApi,
        FamilyMessagePreviewApi,
        FamilySupportPreviewApi {
  RestApiClient({
    String? origin,
    http.Client? client,
    this.accessToken,
    Duration requestTimeout = const Duration(seconds: 60),
  })  : origin = _normalizeOrigin(origin ?? defaultApiOrigin),
        _client = client ?? http.Client(),
        _requestTimeout = requestTimeout;

  T _answerCardResponse<T>(Object? raw, T Function(Object?) parse) {
    try {
      return parse(raw);
    } on FormatException {
      throw const ApiException('Invalid answer card response.');
    }
  }

  void _answerCardRequest(void Function() validate) {
    try {
      validate();
    } on FormatException {
      throw const ApiException('Invalid captured answer card request.', statusCode: 422);
    }
  }

  @override
  Future<AnswerCardExportSnapshot> getAnswerCardExportPreview(String cardId, {
    required int expectedVersion, required String previewedPayloadHash,
    required bool personalReviewAck,
  }) async {
    _answerCardRequest(() {
      validateAnswerCardIdentity(cardId);
      if (expectedVersion < 1 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(previewedPayloadHash)) {
        throw const FormatException('Invalid captured export request');
      }
    });
    final result = _answerCardResponse(await _request('POST',
      '/answer-cards/${Uri.encodeComponent(cardId)}/export-preview', body: {
        'expected_version': expectedVersion,
        'previewed_payload_hash': previewedPayloadHash,
        'personal_review_ack': personalReviewAck,
      }), AnswerCardExportSnapshot.fromJson);
    if (result.cardVersion != expectedVersion || result.publicPayloadHash != previewedPayloadHash) {
      throw const ApiException('Export preview does not match the reviewed card.');
    }
    return result;
  }

  @override
  Future<AnswerCardShare> shareAnswerCard(String cardId, Map<String, Object?> request) async {
    _answerCardRequest(() => validateAnswerCardShareRequest(cardId, request));
    final captured = Map<String, Object?>.unmodifiable(request);
    final share = _answerCardResponse(await _request('POST',
      '/answer-cards/${Uri.encodeComponent(cardId)}/shares', body: captured), AnswerCardShare.fromJson);
    if (share.cardVersion != captured['expected_version'] ||
        share.publicPayloadHash != captured['previewed_payload_hash'] ||
        share.recipientId != captured['recipient_id'] ||
        share.linkId != captured['expected_link_id'] || share.linkEpoch != captured['expected_link_epoch']) {
      throw const ApiException('Share receipt does not match the reviewed recipient and card.');
    }
    return share;
  }

  @override
  Future<List<AnswerCardShare>> listAnswerCardInbox() async =>
    _answerCardResponse(await _request('GET', '/answer-card-shares/inbox'), (raw) {
      if (raw is! List) throw const FormatException('Expected card inbox');
      return List<AnswerCardShare>.unmodifiable(raw.map(AnswerCardShare.fromJson));
    });

  @override
  Future<List<AnswerCardSentShare>> listSentAnswerCardShares() async =>
    _answerCardResponse(await _request('GET', '/answer-card-shares/sent'), (raw) {
      if (raw is! List) throw const FormatException('Expected sent cards');
      return List<AnswerCardSentShare>.unmodifiable(raw.map(AnswerCardSentShare.fromJson));
    });

  @override
  Future<AnswerCardShareRevokeReceipt> revokeAnswerCardShare(String shareId) async {
    _answerCardRequest(() => validateAnswerCardIdentity(shareId));
    final receipt = _answerCardResponse(await _request('POST',
      '/answer-card-shares/${Uri.encodeComponent(shareId)}/revoke', body: <String, Object?>{}),
      AnswerCardShareRevokeReceipt.fromJson);
    if (receipt.id != shareId) throw const ApiException('Withdrawal receipt does not match.');
    return receipt;
  }

  @override
  Future<List<AnswerCardTemplate>> listAnswerCardTemplates() async {
    final raw = await _request('GET', '/answer-card-templates');
    return _answerCardResponse(raw, (value) {
      if (value is! List) throw const FormatException('Expected template list');
      return List<AnswerCardTemplate>.unmodifiable(value.map(AnswerCardTemplate.fromJson));
    });
  }

  @override
  Future<AnswerCardDraftSnapshot> prepareAnswerCard(String sourceMessageId) async {
    _answerCardRequest(() => validateAnswerCardIdentity(sourceMessageId));
    final draft = _answerCardResponse(await _request('POST', '/answer-cards/prepare',
      body: {'source_message_id': sourceMessageId}), AnswerCardDraftSnapshot.fromJson);
    if (draft.sourceMessageId != sourceMessageId) {
      throw const ApiException('Answer card draft source does not match.');
    }
    return draft;
  }

  @override
  Future<List<OwnedAnswerCard>> listAnswerCards() async {
    final raw = await _request('GET', '/answer-cards');
    return _answerCardResponse(raw, (value) {
      if (value is! List) throw const FormatException('Expected owned card list');
      return List<OwnedAnswerCard>.unmodifiable(value.map(OwnedAnswerCard.fromJson));
    });
  }

  @override
  Future<OwnedAnswerCard> createAnswerCard(Map<String, Object?> request) async {
    _answerCardRequest(() => validateAnswerCardCreateRequest(request));
    final origin = Map<String, Object?>.of(request['origin'] as Map<String, Object?>);
    final card = _answerCardResponse(await _request('POST', '/answer-cards', body: request),
      OwnedAnswerCard.fromJson);
    final provenance = card.provenance;
    final matches = origin.containsKey('message_id')
        ? card.mode == 'assistant_answer' &&
            provenance['origin_message_id'] == origin['message_id'] &&
            provenance['origin_hash'] == origin['source_hash']
        : card.mode == 'public_template' &&
            provenance['template_id'] == origin['template_id'] &&
            provenance['template_version'] == origin['template_version'] &&
            provenance['template_hash'] == origin['template_hash'];
    if (!matches) {
      throw const ApiException('Answer card creation receipt source does not match.');
    }
    return card;
  }

  @override
  Future<OwnedAnswerCard> updateAnswerCard(String cardId, Map<String, Object?> request) async {
    _answerCardRequest(() {
      validateAnswerCardIdentity(cardId);
      validateAnswerCardUpdateRequest(request);
    });
    final capturedVersion = request['expected_version'] as int;
    final card = _answerCardResponse(await _request('PATCH',
      '/answer-cards/${Uri.encodeComponent(cardId)}', body: request), OwnedAnswerCard.fromJson);
    if (card.id != cardId || card.version != capturedVersion + 1) {
      throw const ApiException('Answer card edit receipt does not match.');
    }
    return card;
  }

  @override
  Future<AnswerCardDeleteReceipt> deleteAnswerCard({required String cardId,
    required int expectedVersion, required String clientOperationId}) async {
    _answerCardRequest(() {
      validateAnswerCardIdentity(cardId);
      validateAnswerCardDeleteRequest(expectedVersion, clientOperationId);
    });
    final receipt = _answerCardResponse(await _request('DELETE',
      '/answer-cards/${Uri.encodeComponent(cardId)}', body: {
        'expected_version': expectedVersion, 'client_operation_id': clientOperationId,
      }), AnswerCardDeleteReceipt.fromJson);
    if (receipt.id != cardId || receipt.version != expectedVersion + 1) {
      throw const ApiException('Answer card deletion receipt does not match.');
    }
    return receipt;
  }

  final String origin;
  final http.Client _client;
  final Duration _requestTimeout;
  String? accessToken;

  @override
  Future<List<HumanGroup>> listHumanGroups() async =>
      mapsFromJson(await _request('GET', '/groups'))
          .map(HumanGroup.fromJson)
          .toList(growable: false);

  @override
  Future<List<HumanGroupInvitation>> listHumanGroupInvitations() async =>
      mapsFromJson(await _request('GET', '/groups/invitations'))
          .map(HumanGroupInvitation.fromJson)
          .toList(growable: false);

  @override
  Future<HumanGroup> createHumanGroup(String title) async =>
      HumanGroup.fromJson(mapFromJson(
          await _request('POST', '/groups', body: {'title': title}))!);

  @override
  Future<HumanGroupInvitation> inviteHumanGroupMember(
          String groupId, String email) async =>
      HumanGroupInvitation.fromJson(mapFromJson(await _request(
          'POST', '/groups/${Uri.encodeComponent(groupId)}/invitations',
          body: {'email': email}))!);

  @override
  Future<HumanGroup> acceptHumanGroupInvitation(String invitationId) async =>
      HumanGroup.fromJson(mapFromJson(await _request('POST',
          '/groups/invitations/${Uri.encodeComponent(invitationId)}/accept'))!);

  @override
  Future<void> declineHumanGroupInvitation(String invitationId) async {
    await _request('POST',
        '/groups/invitations/${Uri.encodeComponent(invitationId)}/decline');
  }

  @override
  Future<List<HumanGroupMember>> listHumanGroupMembers(String groupId) async =>
      mapsFromJson(await _request(
              'GET', '/groups/${Uri.encodeComponent(groupId)}/members'))
          .map(HumanGroupMember.fromJson)
          .toList(growable: false);

  @override
  Future<List<HumanGroupMessage>> listHumanGroupMessages(
          String groupId) async =>
      mapsFromJson(await _request(
              'GET', '/groups/${Uri.encodeComponent(groupId)}/messages'))
          .map(HumanGroupMessage.fromJson)
          .toList(growable: false);

  @override
  Stream<HumanGroupLiveEvent> watchHumanGroupMessages(String groupId) {
    late final StreamController<HumanGroupLiveEvent> controller;
    bool cancelled = false;
    WebSocketChannel? activeChannel;
    StreamSubscription<dynamic>? activeSubscription;
    Completer<int?>? activeClosed;
    Completer<void>? retryWake;

    Future<void> reconnect() async {
      var retryDelay = const Duration(seconds: 1);
      while (!cancelled) {
        final token = accessToken;
        if (token == null || token.isEmpty) {
          controller.add(
              const HumanGroupLiveEvent(HumanGroupLiveEventType.accessRevoked));
          await controller.close();
          return;
        }

        WebSocketChannel? channel;
        Completer<int?>? disconnected;
        try {
          final openedChannel = WebSocketChannel.connect(_liveUri(groupId));
          channel = openedChannel;
          activeChannel = openedChannel;
          final authenticated = Completer<void>();
          final disconnectedAttempt = Completer<int?>();
          disconnected = disconnectedAttempt;
          activeClosed = disconnectedAttempt;
          var isAuthenticated = false;

          await openedChannel.ready.timeout(const Duration(seconds: 10));
          if (cancelled) break;
          activeSubscription = openedChannel.stream.listen((dynamic frame) {
            if (frame is! String) return;
            try {
              final decoded = jsonDecode(frame);
              if (decoded is! Map<String, dynamic>) return;
              switch (decoded['type']) {
                case 'ready':
                  isAuthenticated = true;
                  if (!authenticated.isCompleted) authenticated.complete();
                  break;
                case 'messages_changed':
                  if (isAuthenticated && !controller.isClosed) {
                    controller.add(const HumanGroupLiveEvent(
                        HumanGroupLiveEventType.messagesChanged));
                  }
                  break;
                case 'access_revoked':
                  openedChannel.sink.close(4404, 'Group access ended');
                  break;
                default:
                  break;
              }
            } on FormatException {
              // Ignore malformed notification frames; history remains canonical.
            }
          }, onError: (Object error, StackTrace stackTrace) {
            if (!authenticated.isCompleted) {
              authenticated.completeError(error, stackTrace);
            }
            if (!disconnectedAttempt.isCompleted) {
              disconnectedAttempt.complete(openedChannel.closeCode);
            }
          }, onDone: () {
            if (!authenticated.isCompleted) {
              authenticated.completeError(StateError(
                  'The group connection closed before authentication.'));
            }
            if (!disconnectedAttempt.isCompleted) {
              disconnectedAttempt.complete(openedChannel.closeCode);
            }
          });
          openedChannel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
          await authenticated.future.timeout(const Duration(seconds: 10));
          if (cancelled) break;
          controller.add(
              const HumanGroupLiveEvent(HumanGroupLiveEventType.connected));
          final connectedAt = DateTime.now();

          final closeCode = await disconnectedAttempt.future;
          if (_isPermanentGroupClose(closeCode)) {
            if (!cancelled && !controller.isClosed) {
              controller.add(const HumanGroupLiveEvent(
                  HumanGroupLiveEventType.accessRevoked));
              await controller.close();
            }
            return;
          }
          if (DateTime.now().difference(connectedAt) >=
              const Duration(seconds: 30)) {
            retryDelay = const Duration(seconds: 1);
          }
        } catch (_) {
          // Authentication, membership, and missing-group closures are final.
          // Network failures and server restarts use bounded exponential retry.
          if (_isPermanentGroupClose(channel?.closeCode)) {
            if (!cancelled && !controller.isClosed) {
              controller.add(const HumanGroupLiveEvent(
                  HumanGroupLiveEventType.accessRevoked));
              await controller.close();
            }
            return;
          }
        } finally {
          await activeSubscription?.cancel();
          activeSubscription = null;
          if (channel != null) {
            try {
              await channel.sink.close();
            } catch (_) {
              // The peer may already have closed during the reconnect attempt.
            }
          }
          if (identical(activeChannel, channel)) activeChannel = null;
          if (identical(activeClosed, disconnected)) activeClosed = null;
        }

        if (cancelled) return;
        if (!controller.isClosed) {
          controller.add(
              const HumanGroupLiveEvent(HumanGroupLiveEventType.reconnecting));
        }
        final wake = Completer<void>();
        retryWake = wake;
        await Future.any<void>([
          Future<void>.delayed(retryDelay),
          wake.future,
        ]);
        if (identical(retryWake, wake)) retryWake = null;
        final nextDelayMs =
            (retryDelay.inMilliseconds * 2).clamp(1000, 30000).toInt();
        retryDelay = Duration(milliseconds: nextDelayMs);
      }
    }

    controller = StreamController<HumanGroupLiveEvent>(
      onListen: () => unawaited(reconnect()),
      onCancel: () async {
        cancelled = true;
        final waitingToRetry = retryWake;
        if (waitingToRetry != null && !waitingToRetry.isCompleted) {
          waitingToRetry.complete();
        }
        final closed = activeClosed;
        if (closed != null && !closed.isCompleted) closed.complete(1000);
        await activeSubscription?.cancel();
        activeSubscription = null;
        try {
          await activeChannel?.sink.close();
        } catch (_) {
          // The channel can finish at the same time as the screen is disposed.
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<HumanGroupMessage> sendHumanGroupMessage(
          String groupId, String content, String clientMessageId) async =>
      HumanGroupMessage.fromJson(mapFromJson(await _request(
          'POST', '/groups/${Uri.encodeComponent(groupId)}/messages',
          body: {'content': content, 'client_message_id': clientMessageId}))!);

  @override
  Future<void> leaveHumanGroup(String groupId) async {
    await _request('POST', '/groups/${Uri.encodeComponent(groupId)}/leave');
  }

  @override
  Future<void> closeHumanGroup(String groupId) async {
    await _request('POST', '/groups/${Uri.encodeComponent(groupId)}/close');
  }

  @override
  Future<void> reportHumanGroup(String groupId, String reason) async {
    await _request('POST', '/groups/${Uri.encodeComponent(groupId)}/reports',
        body: {'reason': reason});
  }

  @override
  Future<void> blockHumanGroupInvitations(String accountId) async {
    await _request('POST', '/groups/blocks', body: {'account_id': accountId});
  }

  @override
  Future<CheckInSchedule?> getCheckInSchedule() async {
    final body = await _request('GET', '/check-ins/schedule');
    if (body == null) return null;
    return CheckInSchedule.fromJson(_requireCareObject(body));
  }

  @override
  Future<CheckInSchedule> saveCheckInSchedule(CheckInSchedule schedule) async {
    final body =
        await _request('PUT', '/check-ins/schedule', body: schedule.toJson());
    return CheckInSchedule.fromJson(_requireCareObject(body));
  }

  @override
  Future<void> skipCheckInToday() async {
    await _request('POST', '/check-ins/skip');
  }

  @override
  Future<CheckInTriggerResult> triggerCheckIn() async {
    final body = await _request('POST', '/check-ins/trigger', body: {});
    return CheckInTriggerResult.fromJson(_requireCareObject(body));
  }

  @override
  Future<List<CareNotification>> listNotifications() async {
    final body = await _request('GET', '/notifications');
    return mapsFromJson(body).map(CareNotification.fromJson).toList();
  }

  @override
  Future<CareNotification> updateNotification({
    required String notificationId,
    required CareNotificationAction status,
  }) async {
    final body = await _request(
      'PATCH',
      '/notifications/${Uri.encodeComponent(notificationId)}',
      body: {'status': status.name},
    );
    return CareNotification.fromJson(_requireCareObject(body));
  }

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() async {
    final body = await _request('GET', '/safety/emergency-contacts');
    return mapsFromJson(body).map(EmergencyContact.fromJson).toList();
  }

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String familyLinkId,
    required String label,
  }) async {
    final body = await _request('POST', '/safety/emergency-contacts', body: {
      'family_link_id': familyLinkId,
      'label': label,
    });
    return EmergencyContact.fromJson(_requireCareObject(body));
  }

  @override
  Future<void> deleteEmergencyContact(String contactId) async {
    await _request('DELETE',
        '/safety/emergency-contacts/${Uri.encodeComponent(contactId)}');
  }

  @override
  Future<List<SafetyEvent>> listSafetyEvents() async {
    final body = await _request('GET', '/safety/events');
    return mapsFromJson(body).map(SafetyEvent.fromJson).toList();
  }

  @override
  Future<void> sendSupportRequest({
    required String emergencyContactId,
    required String message,
    required String idempotencyKey,
    String? safetyEventId,
    String? familyLinkId,
    int? expectedAuthorizationEpoch,
  }) async {
    if (idempotencyKey.trim().isEmpty) {
      throw ArgumentError.value(
          idempotencyKey, 'idempotencyKey', 'Must not be empty');
    }
    _validateFamilyPreview(familyLinkId, expectedAuthorizationEpoch);
    await _request('POST', '/safety/support-request',
        body: {
          'emergency_contact_id': emergencyContactId,
          'message': message,
          'idempotency_key': idempotencyKey,
          'safety_event_id': safetyEventId,
          'family_link_id': familyLinkId,
          'expected_authorization_epoch': expectedAuthorizationEpoch,
        },
        idempotencyKey: idempotencyKey);
  }

  @override
  Future<void> sendSupportRequestForPreview({
    required String emergencyContactId,
    required String message,
    required String idempotencyKey,
    required String familyLinkId,
    required int expectedAuthorizationEpoch,
    String? safetyEventId,
  }) =>
      sendSupportRequest(
        emergencyContactId: emergencyContactId,
        message: message,
        idempotencyKey: idempotencyKey,
        safetyEventId: safetyEventId,
        familyLinkId: familyLinkId,
        expectedAuthorizationEpoch: expectedAuthorizationEpoch,
      );

  static Map<String, dynamic> _requireCareObject(Object? body) {
    final map = mapFromJson(body);
    if (map == null) {
      throw const ApiException(
          'The care service returned an incomplete response.');
    }
    return map;
  }

  // --- Community discovery (FR CMT 01-05) ---

  @override
  Future<List<CatalogActivity>> listCatalogActivities({
    String? district,
    String? interest,
    String? contributionType,
  }) async {
    final params = <String, String>{};
    if (district != null && district.isNotEmpty) params['district'] = district;
    if (interest != null && interest.isNotEmpty) params['interest'] = interest;
    if (contributionType != null && contributionType.isNotEmpty) {
      params['contribution_type'] = contributionType;
    }
    final path = params.isEmpty
        ? '/community/catalog/activities'
        : '/community/catalog/activities?${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
    final body = await _request('GET', path);
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['activities'] ?? map);
    return list
        .map(CatalogActivity.fromJson)
        .where((a) => a.id.isNotEmpty)
        .toList();
  }

  @override
  Future<List<CatalogActivity>> catalogRecommendations() async {
    final body = await _request('GET', '/community/catalog/recommendations');
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['recommendations'] ?? map);
    return list
        .map(CatalogActivity.fromJson)
        .where((a) => a.id.isNotEmpty)
        .toList();
  }

  @override
  Future<void> expressCommunityInterest(String activityId) async {
    await _request('POST',
        '/community/catalog/interest/${Uri.encodeComponent(activityId)}');
  }

  @override
  Future<List<CatalogActivity>> listCommunityInterests() async {
    final body = await _request('GET', '/community/catalog/interests');
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['interests'] ?? map);
    return list
        .map(CatalogActivity.fromJson)
        .where((a) => a.id.isNotEmpty)
        .toList();
  }

  @override
  Future<void> withdrawCommunityInterest(String activityId) async {
    await _request('DELETE',
        '/community/catalog/interest/${Uri.encodeComponent(activityId)}');
  }

  // --- Scam safety (FR SCM 01-04) ---

  @override
  Future<List<ScamResource>> listScamResources({String? scamType}) async {
    final path = scamType != null && scamType.isNotEmpty
        ? '/scam/resources?scam_type=${Uri.encodeComponent(scamType)}'
        : '/scam/resources';
    final body = await _request('GET', path);
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['resources'] ?? map);
    return list
        .map(ScamResource.fromJson)
        .where((r) => r.id.isNotEmpty)
        .toList();
  }

  @override
  Future<List<ScamResource>> searchScamResources(String query) async {
    final body = await _request(
      'GET',
      '/scam/resources/search?query=${Uri.encodeComponent(query)}',
    );
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['results'] ?? map);
    return list
        .map(ScamResource.fromJson)
        .where((r) => r.id.isNotEmpty)
        .toList();
  }

  @override
  Future<List<VerifyAction>> getVerifyActions() async {
    final body = await _request('GET', '/scam/verify-actions');
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['actions'] ?? map);
    return list.map(VerifyAction.fromJson).toList();
  }

  @override
  Future<List<ScamContact>> getScamContacts() async {
    final body = await _request('GET', '/scam/contacts');
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['contacts'] ?? map);
    return list.map(ScamContact.fromJson).toList();
  }

  @override
  Future<void> logScamGuidance({
    required String scamType,
    required String guidanceSummary,
    String? scamResourceId,
    String? conversationId,
  }) async {
    await _request('POST', '/scam/log', body: {
      'scam_type': scamType,
      'guidance_summary': guidanceSummary,
      if (scamResourceId != null) 'scam_resource_id': scamResourceId,
      if (conversationId != null) 'conversation_id': conversationId,
    });
  }

  @override
  Future<List<ScamLogEntry>> listScamLogs() async {
    final body = await _request('GET', '/scam/log');
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final list = mapsFromJson(map['logs'] ?? map);
    return list.map(ScamLogEntry.fromJson).toList();
  }

  Future<bool?> readDemoMode() async {
    final body = await _request('GET', '/health');
    final map = mapFromJson(body);
    if (map == null) return null;
    final mode = map['mode'] ?? map['model_mode'];
    if (mode is String) {
      if (mode == 'deterministic_demo' || mode == 'demo') return true;
      if (mode == 'openai_compatible' || mode == 'live') return false;
    }
    final explicit = map['demo_mode'] ?? map['is_demo'];
    if (explicit is bool) return explicit;
    final configured = map['model_configured'];
    if (configured is bool) return !configured;
    return null;
  }

  @override
  Future<GuestSession> startGuestSession() async {
    final body = await _request('POST', '/guest/sessions', body: const {});
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆訪客對話資料。');
    final session = GuestSession.fromJson(map);
    if (session.id.isEmpty) throw const ApiException('服務未回覆訪客對話編號。');
    return session;
  }

  @override
  Future<GuestReply> sendGuestMessage(String sessionId, String content) async {
    final body = await _request(
      'POST',
      '/guest/sessions/${Uri.encodeComponent(sessionId)}/messages',
      body: {'content': content},
    );
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆對話內容。');
    final reply = GuestReply.fromJson(map);
    if (reply.content.isEmpty) throw const ApiException('服務未回覆對話內容。');
    return reply;
  }

  @override
  Future<void> endGuestSession(String sessionId) async {
    await _request(
        'DELETE', '/guest/sessions/${Uri.encodeComponent(sessionId)}');
  }

  @override
  Future<ResourceSearchResult> searchGuestResources(
      {required String query, int? limit}) async {
    final params = <String, String>{
      'query': query,
      if (limit != null) 'limit': '$limit'
    };
    final map = mapFromJson(await _request('GET',
            '/guest/resources/search?${Uri(queryParameters: params).query}')) ??
        const <String, dynamic>{};
    final rawConflicts = map['conflicts'] ?? map['resource_conflicts'];
    return ResourceSearchResult(
      query: _stringValue(map, const ['query']) ?? query,
      retrievalMode: _stringValue(map, const ['retrieval_mode', 'mode']),
      items: mapsFromJson(map['items']).map(ResourceItem.fromJson).toList(),
      conflicts: rawConflicts is List
          ? rawConflicts.map(ResourceConflict.fromJson).toList()
          : const [],
    );
  }

  @override
  Future<bool> getMemoryConsent() async {
    final map = mapFromJson(await _request('GET', '/memories/consent'));
    return map?['enabled'] == true;
  }

  @override
  Future<bool> setMemoryConsent(bool enabled) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<MemoryControlState> setMemoryConsentAtRevision(bool enabled,
      {required int expectedRevision}) async {
    _validateMemoryRevision(expectedRevision);
    final map = mapFromJson(await _request('PUT', '/memories/consent',
        body: {'enabled': enabled}, memoryRevision: expectedRevision));
    return _parseControlState(map);
  }

  @override
  Future<MemoryRecord> saveConfirmedMemory(
      {required String content,
      required String kind,
      String? sourceMessageId,
      String? topicKey}) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<MemoryRecord> saveConfirmedMemoryAtRevision({
    required String content,
    required String kind,
    String? sourceMessageId,
    String? topicKey,
    required int expectedRevision,
  }) async {
    _validateMemoryRevision(expectedRevision);
    final body = await _request('POST', '/memories/save',
        body: {
          'content': content,
          'kind': kind,
          if (sourceMessageId != null && sourceMessageId.trim().isNotEmpty)
            'source_message_id': sourceMessageId,
          if (topicKey != null && topicKey.trim().isNotEmpty)
            'topic_key': topicKey,
        },
        memoryRevision: expectedRevision);
    return _requireVersionedMemory(body);
  }

  @override
  Future<List<CommunityActivity>> listCommunityActivities() async {
    return (await searchCommunityActivities()).items;
  }

  @override
  Future<CommunitySearchResult<CommunityActivity>> searchCommunityActivities(
      {String? topic, String? area}) async {
    final params = <String, String>{
      if (topic != null && topic.trim().isNotEmpty) 'topic': topic.trim(),
      if (area != null && area.trim().isNotEmpty) 'area': area.trim(),
    };
    final path = params.isEmpty
        ? '/community/activities'
        : '/community/activities?${Uri(queryParameters: params).query}';
    final map =
        mapFromJson(await _request('GET', path)) ?? const <String, dynamic>{};
    return CommunitySearchResult<CommunityActivity>.fromJson(
        map, CommunityActivity.fromJson);
  }

  @override
  Future<List<SkillSuggestion>> listSkillSuggestions() async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<List<SkillSuggestion>> listSkillSuggestionsAtRevision(
      {required int expectedRevision}) async {
    _validateMemoryRevision(expectedRevision);
    final map = mapFromJson(await _request(
        'GET', '/community/skills/suggestions',
        memoryRevision: expectedRevision));
    final skills =
        mapsFromJson(map?['items']).map(SkillSuggestion.fromJson).toList();
    if (skills.any((skill) => skill.revision == null)) {
      throw const ApiException('Missing skill revision.');
    }
    return skills;
  }

  @override
  Future<SkillSuggestion> decideSkill(String id,
      {required String decision, String? skill}) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<SkillSuggestion> decideSkillAtRevision(
    String id, {
    required String decision,
    String? skill,
    required int expectedRevision,
  }) async {
    _validateMemoryRevision(expectedRevision);
    final map = mapFromJson(await _request(
        'POST', '/community/skills/${Uri.encodeComponent(id)}/decision',
        body: {'decision': decision, if (skill != null) 'skill': skill},
        memoryRevision: expectedRevision));
    if (map == null) throw const ApiException('服務未確認技能選擇。');
    final suggestion = SkillSuggestion.fromJson(map);
    if (suggestion.revision == null) {
      throw const ApiException('Missing skill revision.');
    }
    return suggestion;
  }

  @override
  Future<List<CommunityOpportunity>> listOpportunities(String skillId) async {
    return (await searchOpportunities(skillId)).items;
  }

  @override
  Future<CommunitySearchResult<CommunityOpportunity>> searchOpportunities(
      String skillId) async {
    final uri = Uri.parse('$origin/community/opportunities')
        .replace(queryParameters: {'skill_id': skillId});
    final map =
        mapFromJson(await _request('GET', '${uri.path}?${uri.query}')) ??
            const <String, dynamic>{};
    return CommunitySearchResult<CommunityOpportunity>.fromJson(
        map, CommunityOpportunity.fromJson);
  }

  static String _normalizeOrigin(String value) {
    final trimmed = value.trim();
    if (trimmed.endsWith('/')) return trimmed.substring(0, trimmed.length - 1);
    return trimmed;
  }

  Uri _uri(String path) => Uri.parse('$origin/${path.replaceFirst('/', '')}');

  Uri _liveUri(String groupId) {
    final uri = _uri('/groups/${Uri.encodeComponent(groupId)}/live');
    final scheme = switch (uri.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      'ws' || 'wss' => uri.scheme,
      _ =>
        throw FormatException('Unsupported API origin scheme: ${uri.scheme}'),
    };
    return uri.replace(scheme: scheme, query: null, fragment: null);
  }

  static bool _isPermanentGroupClose(int? code) =>
      code == 1008 || code == 4401 || code == 4403 || code == 4404;

  Map<String, String> _headers({bool jsonBody = false}) => {
        'Accept': 'application/json',
        if (jsonBody) 'Content-Type': 'application/json',
        if (accessToken != null && accessToken!.isNotEmpty)
          'Authorization': 'Bearer $accessToken',
      };

  Future<Object?> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? idempotencyKey,
    int? memoryRevision,
  }) async {
    final uri = _uri(path);
    try {
      final encodedBody = body == null ? null : jsonEncode(body);
      final response = await _client
          .send(
            http.Request(method, uri)
              ..headers.addAll(_headers(jsonBody: body != null))
              ..headers.addAll({
                if (idempotencyKey != null && idempotencyKey.isNotEmpty)
                  'Idempotency-Key': idempotencyKey,
                if (memoryRevision != null)
                  'X-Memory-Revision': memoryRevision.toString(),
              })
              ..body = encodedBody ?? '',
          )
          .timeout(_requestTimeout);
      final text = await response.stream.bytesToString();
      Object? decoded;
      if (text.trim().isNotEmpty) {
        try {
          decoded = jsonDecode(text);
        } on FormatException {
          decoded = text;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          _errorMessage(decoded, response.statusCode),
          statusCode: response.statusCode,
        );
      }
      return decoded;
    } on ApiException {
      rethrow;
    } on TimeoutException catch (error) {
      throw ApiException('連線逾時，請檢查網絡後再試。', cause: error);
    } on http.ClientException catch (error) {
      throw ApiException('暫時未能連接服務，請檢查網絡後再試。', cause: error);
    } catch (error) {
      throw ApiException('暫時未能連接服務，請檢查網絡後再試。', cause: error);
    }
  }

  static String _errorMessage(Object? body, int statusCode) {
    final map = mapFromJson(body);
    if (map != null) {
      for (final key in const ['detail', 'message', 'error', 'title']) {
        final value = map[key];
        if (value is String && value.trim().isNotEmpty) return value;
      }
    }
    if (statusCode == 401) return '登入已過期，請重新登入。';
    if (statusCode == 403) return '你沒有權限進行這項操作。';
    return '服務暫時未能完成要求（$statusCode）。';
  }

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  }) async {
    final body = await _request('POST', '/auth/register', body: {
      'email': email,
      'password': password,
      'display_name': displayName,
      'role': role.apiValue,
    });
    final session = AuthSession.fromJson(mapFromJson(body) ?? const {});
    _requireToken(session);
    accessToken = session.accessToken;
    return session;
  }

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    final body = await _request('POST', '/auth/login', body: {
      'email': email,
      'password': password,
    });
    final session = AuthSession.fromJson(mapFromJson(body) ?? const {});
    _requireToken(session);
    accessToken = session.accessToken;
    return session;
  }

  static void _requireToken(AuthSession session) {
    if (session.accessToken.isEmpty || session.user.id.isEmpty) {
      throw const ApiException('服務回覆的登入資料不完整，請稍後再試。');
    }
  }

  @override
  Future<AppUser> currentUser() async {
    final body = await _request('GET', '/auth/me');
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務回覆的帳戶資料不完整。');
    return AppUser.fromJson(
        _mapOrEmpty(map['account']) ?? _mapOrEmpty(map['user']) ?? map);
  }

  @override
  Future<void> logout() async {
    // The foundation API has no remote logout endpoint. Clearing this bearer
    // token after the local secure store is cleared is the complete logout.
    accessToken = null;
  }

  @override
  Future<List<Conversation>> listConversations() async {
    final body = await _request('GET', '/conversations');
    return mapsFromJson(body)
        .map(Conversation.fromJson)
        .where((conversation) => conversation.id.isNotEmpty)
        .toList();
  }

  @override
  Future<List<ChatMessage>> listMessages(String conversationId) async {
    final body = await _request(
      'GET',
      '/conversations/${Uri.encodeComponent(conversationId)}/messages',
    );
    return mapsFromJson(body)
        .map((json) =>
            ChatMessage.fromJson(json, conversationId: conversationId))
        .where((message) => message.body.isNotEmpty)
        .toList();
  }

  @override
  Future<Conversation> createConversation({String? title}) async {
    final body = await _request('POST', '/conversations', body: {
      'title': title == null || title.trim().isEmpty ? '新對話' : title.trim(),
    });
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆新對話資料。');
    final conversation = Conversation.fromJson(map);
    if (conversation.id.isEmpty) {
      throw const ApiException('服務未回覆新對話編號。');
    }
    return conversation;
  }

  @override
  Future<SendMessageResult> sendMessage({
    required String conversationId,
    required String content,
    required String clientMessageId,
  }) async {
    final body = await _request(
      'POST',
      '/conversations/${Uri.encodeComponent(conversationId)}/messages',
      body: {
        'content': content,
        'client_message_id': clientMessageId,
      },
      idempotencyKey: clientMessageId,
    );
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final userJson = _mapOrEmpty(
      map['user_message'] ?? map['userMessage'] ?? map['sent_message'],
    );
    final assistantJson = _mapOrEmpty(
      map['assistant_message'] ??
          map['assistantMessage'] ??
          map['reply'] ??
          map['response'],
    );
    final actionJson = _mapOrEmpty(
      map['action'] ?? map['pending_action'] ?? map['action_proposal'],
    );
    final userMessage = userJson == null
        ? null
        : ChatMessage.fromJson(
            userJson,
            conversationId: conversationId,
            isFromUser: true,
          );
    var assistantMessage = assistantJson == null
        ? null
        : ChatMessage.fromJson(
            assistantJson,
            conversationId: conversationId,
            isFromUser: false,
          );
    if (assistantMessage == null &&
        userJson == null &&
        map['content'] is String &&
        (map['content'] as String).trim().isNotEmpty) {
      assistantMessage = ChatMessage.fromJson(
        map,
        conversationId: conversationId,
        isFromUser: false,
      );
    }
    return SendMessageResult(
      userMessage: userMessage,
      assistantMessage: assistantMessage,
      action: actionJson == null ? null : ActionProposal.fromJson(actionJson),
      demoMode: _demoModeValue(map['mode']),
    );
  }

  @override
  Future<List<CareTask>> listTasks() async {
    final body = await _request('GET', '/tasks');
    return mapsFromJson(body)
        .map(CareTask.fromJson)
        .where((task) => task.id.isNotEmpty)
        .toList();
  }

  @override
  Future<CareTask> getTaskDetail(String taskId) async {
    final body = await _request('GET', '/tasks/${Uri.encodeComponent(taskId)}');
    final map = mapFromJson(body);
    if (map == null) {
      throw const ApiException('Task details were not returned.');
    }
    final task = CareTask.fromJson(map);
    if (task.id.isEmpty) {
      throw const ApiException('Task details were not returned.');
    }
    return task;
  }

  @override
  Future<List<TaskShare>> listTaskShares(String taskId) async {
    final body =
        await _request('GET', '/tasks/${Uri.encodeComponent(taskId)}/shares');
    if (body is! List) {
      throw const ApiException('Sharing history was not returned.');
    }
    return body.map(_requireTaskShare).toList(growable: false);
  }

  @override
  Future<TaskShare> createTaskShare({
    required String taskId,
    required String familyLinkId,
    required String expectedContentHash,
    required String idempotencyKey,
  }) async {
    final body = await _request(
      'POST',
      '/tasks/${Uri.encodeComponent(taskId)}/shares',
      body: {
        'family_link_id': familyLinkId,
        'expected_content_hash': expectedContentHash,
        'idempotency_key': idempotencyKey,
      },
    );
    return _requireTaskShare(body);
  }

  @override
  Future<TaskShare> revokeTaskShare({
    required String taskId,
    required String shareId,
  }) async {
    final body = await _request('DELETE',
        '/tasks/${Uri.encodeComponent(taskId)}/shares/${Uri.encodeComponent(shareId)}');
    return _requireTaskShare(body);
  }

  @override
  Future<CareTask> updateTask({
    required String taskId,
    required TaskStatus status,
  }) async {
    final body = await _request(
      'PATCH',
      '/tasks/${Uri.encodeComponent(taskId)}',
      body: {'status': status.apiValue},
    );
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆更新後的任務。');
    return CareTask.fromJson(map);
  }

  @override
  Future<CareTask?> confirmAction({
    required String actionId,
    required String clientActionId,
  }) async {
    final body = await _request(
      'POST',
      '/actions/${Uri.encodeComponent(actionId)}/confirm',
      body: {'idempotency_key': clientActionId},
      idempotencyKey: clientActionId,
    );
    final map = mapFromJson(body);
    if (map == null) return null;
    final taskJson = _mapOrEmpty(map['task'] ?? map['created_task']);
    return taskJson == null ? null : CareTask.fromJson(taskJson);
  }

  @override
  Future<void> dismissAction({required String actionId}) async {
    await _request(
      'POST',
      '/actions/${Uri.encodeComponent(actionId)}/dismiss',
    );
  }

  @override
  Future<List<FamilyConnectionRequest>> listConnectionRequests() async =>
      mapsFromJson(await _request('GET', '/family-links/requests'))
          .map(FamilyConnectionRequest.fromJson)
          .toList();

  @override
  Future<FamilyConnectionRequest> createConnectionRequest(
          {required String elderEmail,
          required String clientRequestId}) async =>
      FamilyConnectionRequest.fromJson(_familyResponse(
          await _request('POST', '/family-links/requests', body: {
        'elder_email': elderEmail,
        'client_request_id': clientRequestId,
      })));

  @override
  Future<FamilyInvitation> approveConnectionRequest(
          {required String requestId,
          required int expectedVersion,
          required List<String> scopes}) async =>
      FamilyInvitation.fromJson(_familyResponse(await _request('POST',
          '/family-links/requests/${Uri.encodeComponent(requestId)}/decision',
          body: {
            'decision': 'approve',
            'expected_version': expectedVersion,
            'scopes': scopes,
          })));

  @override
  Future<FamilyConnectionRequest> rejectConnectionRequest(
          {required String requestId, required int expectedVersion}) async =>
      FamilyConnectionRequest.fromJson(_familyResponse(await _request('POST',
          '/family-links/requests/${Uri.encodeComponent(requestId)}/decision',
          body: {
            'decision': 'reject',
            'expected_version': expectedVersion,
          })));

  @override
  Future<FamilyConnectionRequest> withdrawConnectionRequest(
          {required String requestId, required int expectedVersion}) async =>
      FamilyConnectionRequest.fromJson(_familyResponse(await _request('POST',
          '/family-links/requests/${Uri.encodeComponent(requestId)}/withdraw',
          body: {
            'expected_version': expectedVersion,
          })));

  @override
  Future<List<FamilyBlock>> listFamilyBlocks() async =>
      mapsFromJson(await _request('GET', '/family-links/blocks'))
          .map(FamilyBlock.fromJson)
          .toList();

  @override
  Future<FamilyBlock> blockFamilyPair(
          {required String caregiverId,
          String? requestId,
          String? linkId,
          required String clientOperationId}) async =>
      FamilyBlock.fromJson(
          _familyResponse(await _request('POST', '/family-links/blocks', body: {
        'caregiver_id': caregiverId,
        if (requestId != null) 'request_id': requestId,
        if (linkId != null) 'link_id': linkId,
        'client_operation_id': clientOperationId,
      })));

  @override
  Future<FamilyBlock> unblockFamilyPair(
          {required String caregiverId,
          required int expectedVersion,
          required String clientOperationId}) async =>
      FamilyBlock.fromJson(_familyResponse(await _request('POST',
          '/family-links/blocks/${Uri.encodeComponent(caregiverId)}/unblock',
          body: {
            'expected_version': expectedVersion,
            'client_operation_id': clientOperationId,
          })));

  @override
  Future<List<FamilyMessage>> listSentFamilyMessages() async =>
      mapsFromJson(await _request('GET', '/family-messages/sent'))
          .map(FamilyMessage.fromJson)
          .toList();

  Map<String, dynamic> _familyResponse(Object? body) {
    final map = mapFromJson(body);
    if (map == null) {
      throw const ApiException('Invalid family connection response.');
    }
    return map;
  }

  @override
  Future<FamilyInvitation> createInvitation({
    required String email,
    List<String> scopes = const ['care_tasks'],
  }) async {
    final body = await _request('POST', '/family-links/invitations', body: {
      'email': email,
      'scopes': scopes,
    });
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆邀請資料。');
    return FamilyInvitation.fromJson(_mapOrEmpty(map['invitation']) ?? map);
  }

  @override
  Future<List<FamilyInvitation>> listInvitations() async {
    final body = await _request('GET', '/family-links/invitations');
    return mapsFromJson(body)
        .map(FamilyInvitation.fromJson)
        .where((invitation) => invitation.id.isNotEmpty)
        .toList();
  }

  @override
  Future<List<FamilyInvitation>> listLinks() async {
    final body = await _request('GET', '/family-links');
    return mapsFromJson(body)
        .map(FamilyInvitation.fromJson)
        .where((link) => link.id.isNotEmpty)
        .toList();
  }

  @override
  Future<FamilyInvitation> acceptInvitation({
    required String invitationId,
    required String token,
  }) async {
    final body = await _request(
      'POST',
      '/family-links/invitations/accept',
      body: {'token': token},
      idempotencyKey: invitationId,
    );
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆接受後的連結。');
    return FamilyInvitation.fromJson(_mapOrEmpty(map['invitation']) ?? map);
  }

  @override
  Future<void> revokeInvitation({required String invitationId}) async {
    await _request(
      'POST',
      '/family-links/invitations/${Uri.encodeComponent(invitationId)}/revoke',
    );
  }

  @override
  Future<void> revokeLink({required String linkId}) async {
    await _request(
      'POST',
      '/family-links/${Uri.encodeComponent(linkId)}/revoke',
    );
  }

  @override
  Future<List<ActionProposal>> listActions(String conversationId) async {
    final body = await _request(
      'GET',
      '/conversations/${Uri.encodeComponent(conversationId)}/actions',
    );
    return mapsFromJson(body)
        .map(ActionProposal.fromJson)
        .where((action) =>
            action.id.isNotEmpty && !action.confirmed && !action.dismissed)
        .toList();
  }

  @override
  Future<List<MemoryRecord>> listMemories() async {
    final body = await _request('GET', '/memories');
    return mapsFromJson(body)
        .map(MemoryRecord.fromJson)
        .where((memory) => memory.id.isNotEmpty && memory.content.isNotEmpty)
        .toList();
  }

  @override
  Future<MemoryRecord> createMemory({
    required String content,
    required String kind,
    String? sourceMessageId,
  }) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<MemoryRecord> createMemoryAtRevision({
    required String content,
    required String kind,
    String? sourceMessageId,
    required int expectedRevision,
  }) async {
    _validateMemoryRevision(expectedRevision);
    final body = await _request('POST', '/memories',
        body: {
          'content': content,
          'kind': kind,
          if (sourceMessageId != null && sourceMessageId.trim().isNotEmpty)
            'source_message_id': sourceMessageId,
        },
        memoryRevision: expectedRevision);
    return _requireVersionedMemory(body);
  }

  @override
  Future<MemoryRecord> confirmMemory(String memoryId) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<MemoryRecord> confirmMemoryAtRevision(String memoryId,
      {required int expectedRevision}) async {
    _validateMemoryRevision(expectedRevision);
    final body = await _request(
        'POST', '/memories/${Uri.encodeComponent(memoryId)}/confirm',
        memoryRevision: expectedRevision);
    return _requireVersionedMemory(body);
  }

  @override
  Future<MemoryRecord> updateMemory(
    String memoryId, {
    String? content,
    bool? suppressed,
  }) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<MemoryRecord> updateMemoryAtRevision(
    String memoryId, {
    String? content,
    bool? suppressed,
    required int expectedRevision,
  }) async {
    _validateMemoryRevision(expectedRevision);
    final body =
        await _request('PATCH', '/memories/${Uri.encodeComponent(memoryId)}',
            body: {
              if (content != null) 'content': content,
              if (suppressed != null) 'suppressed': suppressed,
            },
            memoryRevision: expectedRevision);
    return _requireVersionedMemory(body);
  }

  @override
  Future<void> deleteMemory(String memoryId) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<void> deleteMemoryAtRevision(String memoryId,
      {required int expectedRevision, required String idempotencyKey}) async {
    _validateMemoryRevision(expectedRevision);
    if (idempotencyKey.trim().isEmpty) {
      throw const ApiException('A deletion key is required.', statusCode: 422);
    }
    await _request('DELETE', '/memories/${Uri.encodeComponent(memoryId)}',
        memoryRevision: expectedRevision, idempotencyKey: idempotencyKey);
  }

  @override
  Future<MemorySearchResult> searchMemories({
    required String query,
    int? limit,
  }) async {
    final body = await _request('POST', '/memories/search', body: {
      'query': query,
      if (limit != null) 'limit': limit,
    });
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    return MemorySearchResult(
      items: mapsFromJson(map['items'] ?? map)
          .map(MemoryRecord.fromJson)
          .where((memory) => memory.id.isNotEmpty)
          .toList(),
      retrievalMode: _stringValue(map, const [
        'retrieval_mode',
        'retrievalMode',
        'memory_retrieval_mode',
        'mode',
      ]),
    );
  }

  @override
  Future<List<StoryRecord>> listStories() async {
    final body = await _request('GET', '/stories');
    return mapsFromJson(body)
        .map(StoryRecord.fromJson)
        .where((story) => story.id.isNotEmpty)
        .toList();
  }

  @override
  Future<StoryRecord> createStory({
    required String title,
    required String content,
    required List<String> memoryIds,
  }) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<StoryRecord> createStoryAtRevision({
    required String title,
    required String content,
    required List<String> memoryIds,
    required int expectedRevision,
  }) async {
    _validateMemoryRevision(expectedRevision);
    final body = await _request('POST', '/stories',
        body: {
          'title': title,
          'content': content,
          'memory_ids': memoryIds,
        },
        memoryRevision: expectedRevision);
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆故事資料。');
    final story = StoryRecord.fromJson(map);
    if (story.id.isEmpty || story.revision == null) {
      throw const ApiException('服務未回覆故事編號。');
    }
    return story;
  }

  @override
  Future<StoryRecord> updateStoryAtRevision(
    String storyId, {
    required String title,
    required String content,
    required int expectedRevision,
  }) async {
    _validateMemoryRevision(expectedRevision);
    final map = mapFromJson(await _request(
      'PATCH',
      '/stories/${Uri.encodeComponent(storyId)}',
      body: {'title': title, 'content': content},
      memoryRevision: expectedRevision,
    ));
    final revision = map?['revision'];
    final returnedTitle = map?['title'];
    final returnedContent = map?['content'];
    final memoryIds = map?['memory_ids'];
    if (map == null ||
        map['id'] != storyId ||
        storyId.isEmpty ||
        revision is! int ||
        revision <= expectedRevision ||
        returnedTitle is! String ||
        returnedTitle.trim().isEmpty ||
        returnedTitle != title.trim() ||
        returnedContent is! String ||
        returnedContent.trim().isEmpty ||
        returnedContent != content.trim() ||
        memoryIds is! List ||
        memoryIds.any((id) => id is! String || id.isEmpty || id != id.trim()) ||
        memoryIds.toSet().length != memoryIds.length) {
      throw const ApiException('Invalid private card edit receipt.');
    }
    return StoryRecord.fromJson(map);
  }

  @override
  Future<void> deleteStory(String storyId) async {
    throw const ApiException('A captured memory revision is required.',
        statusCode: 422);
  }

  @override
  Future<void> deleteStoryAtRevision(String storyId,
      {required int expectedRevision}) async {
    _validateMemoryRevision(expectedRevision);
    await _request('DELETE', '/stories/${Uri.encodeComponent(storyId)}',
        memoryRevision: expectedRevision);
  }

  @override
  Future<ResourceSearchResult> searchResources({
    required String query,
    int? limit,
  }) async {
    final body = await _request('POST', '/resources/search', body: {
      'query': query,
      if (limit != null) 'limit': limit,
    });
    final map = mapFromJson(body) ?? const <String, dynamic>{};
    final rawConflicts = map['conflicts'] ?? map['resource_conflicts'];
    return ResourceSearchResult(
      query: _stringValue(map, const ['query']) ?? query,
      retrievalMode: _stringValue(map, const [
        'retrieval_mode',
        'retrievalMode',
        'resource_retrieval_mode',
        'mode',
      ]),
      items: mapsFromJson(map['items'] ?? map)
          .map(ResourceItem.fromJson)
          .where((item) => item.id.isNotEmpty || item.title.isNotEmpty)
          .toList(),
      conflicts: rawConflicts is List
          ? rawConflicts.map(ResourceConflict.fromJson).toList()
          : const [],
    );
  }

  @override
  Future<List<FamilyMessage>> listFamilyMessages() async {
    final body = await _request('GET', '/family-messages');
    return mapsFromJson(body)
        .map(FamilyMessage.fromJson)
        .where((message) => message.id.isNotEmpty)
        .toList();
  }

  @override
  Future<FamilyMessage> sendFamilyMessage({
    required String recipientId,
    required String content,
    required String clientMessageId,
    String? sourceStoryId,
    String? familyLinkId,
    int? expectedAuthorizationEpoch,
  }) async {
    _validateFamilyPreview(familyLinkId, expectedAuthorizationEpoch);
    if (sourceStoryId != null && sourceStoryId.trim().isNotEmpty) {
      throw const ApiException('A captured memory revision is required.',
          statusCode: 422);
    }
    final body = await _request(
      'POST',
      '/family-messages',
      body: {
        'recipient_id': recipientId,
        'content': content,
        'client_message_id': clientMessageId,
        'family_link_id': familyLinkId,
        'expected_authorization_epoch': expectedAuthorizationEpoch,
        if (sourceStoryId != null && sourceStoryId.trim().isNotEmpty)
          'source_story_id': sourceStoryId,
      },
      idempotencyKey: clientMessageId,
    );
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆家庭訊息。');
    final message = FamilyMessage.fromJson(map);
    if (message.id.isEmpty) throw const ApiException('服務未回覆家庭訊息編號。');
    return message;
  }

  @override
  Future<FamilyMessage> sendFamilyMessageAtRevision({
    required String recipientId,
    required String content,
    required String clientMessageId,
    required String sourceStoryId,
    required int expectedRevision,
    String? familyLinkId,
    int? expectedAuthorizationEpoch,
  }) async {
    _validateFamilyPreview(familyLinkId, expectedAuthorizationEpoch);
    _validateMemoryRevision(expectedRevision);
    final body = await _request(
      'POST',
      '/family-messages',
      body: {
        'recipient_id': recipientId,
        'content': content,
        'client_message_id': clientMessageId,
        'family_link_id': familyLinkId,
        'expected_authorization_epoch': expectedAuthorizationEpoch,
        if (sourceStoryId.trim().isNotEmpty) 'source_story_id': sourceStoryId,
      },
      idempotencyKey: clientMessageId,
      memoryRevision: expectedRevision,
    );
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆家庭訊息。');
    final message = FamilyMessage.fromJson(map);
    if (message.id.isEmpty) throw const ApiException('服務未回覆家庭訊息編號。');
    return message;
  }

  @override
  Future<FamilyMessage> sendFamilyMessageForPreview({
    required String recipientId,
    required String content,
    required String clientMessageId,
    required String familyLinkId,
    required int expectedAuthorizationEpoch,
    String? sourceStoryId,
    int? expectedRevision,
  }) async {
    _validateFamilyPreview(familyLinkId, expectedAuthorizationEpoch);
    if (sourceStoryId != null) {
      if (expectedRevision == null) {
        throw const ApiException('A captured memory revision is required.',
            statusCode: 422);
      }
      return sendFamilyMessageAtRevision(
        recipientId: recipientId,
        content: content,
        clientMessageId: clientMessageId,
        familyLinkId: familyLinkId,
        expectedAuthorizationEpoch: expectedAuthorizationEpoch,
        sourceStoryId: sourceStoryId,
        expectedRevision: expectedRevision,
      );
    }
    return sendFamilyMessage(
      recipientId: recipientId,
      content: content,
      clientMessageId: clientMessageId,
      familyLinkId: familyLinkId,
      expectedAuthorizationEpoch: expectedAuthorizationEpoch,
    );
  }

  void _validateFamilyPreview(
      String? familyLinkId, int? expectedAuthorizationEpoch) {
    if (familyLinkId == null ||
        familyLinkId.trim().isEmpty ||
        expectedAuthorizationEpoch == null ||
        expectedAuthorizationEpoch < 1) {
      throw const ApiException(
          'A captured family connection and authorization epoch are required.',
          statusCode: 422);
    }
  }

  @override
  Future<MemoryControlState> getMemoryControlState() async =>
      _parseControlState(
          mapFromJson(await _request('GET', '/memories/control-state')));

  @override
  Future<MemoryDeletionReceipt> deleteMemories(
      {required String mode,
      List<String> memoryIds = const [],
      required int expectedRevision,
      required String idempotencyKey}) async {
    _validateMemoryRevision(expectedRevision);
    if ((mode != 'all' && mode != 'selected') ||
        idempotencyKey.trim().isEmpty ||
        (mode == 'selected' && memoryIds.isEmpty) ||
        (mode == 'all' && memoryIds.isNotEmpty)) {
      throw const ApiException('Invalid memory deletion request.',
          statusCode: 422);
    }
    final map =
        mapFromJson(await _request('POST', '/memories/deletions', body: {
      'mode': mode,
      'memory_ids': memoryIds,
      'expected_revision': expectedRevision,
      'idempotency_key': idempotencyKey
    }));
    try {
      final receipt = MemoryDeletionReceipt.fromJson(map ?? const {});
      if (receipt.revision <= expectedRevision) {
        throw const ApiException(
            'The deletion receipt did not advance the captured revision.');
      }
      return receipt;
    } on FormatException {
      throw const ApiException('Invalid memory deletion receipt.');
    }
  }
}

Map<String, dynamic>? _mapOrEmpty(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

bool? _demoModeValue(Object? value) {
  if (value is String) {
    if (value == 'deterministic_demo' || value == 'demo') return true;
    if (value == 'openai_compatible' || value == 'live') return false;
  }
  if (value is bool) return value;
  return null;
}

TaskShare _requireTaskShare(Object? body) {
  final map = mapFromJson(body);
  if (map == null) {
    throw const ApiException('A task sharing receipt was not returned.');
  }
  final share = TaskShare.fromJson(map);
  if (share.id.isEmpty ||
      share.taskId.isEmpty ||
      share.familyLinkId.isEmpty ||
      share.sharedBy.isEmpty ||
      share.contentHash.isEmpty) {
    throw const ApiException('A valid task sharing receipt was not returned.');
  }
  return share;
}

MemoryRecord _requireMemory(Object? body) {
  final map = mapFromJson(body);
  if (map == null) throw const ApiException('服務未回覆記憶資料。');
  final memory = MemoryRecord.fromJson(map);
  if (memory.id.isEmpty) throw const ApiException('服務未回覆記憶編號。');
  return memory;
}

String? _stringValue(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is num || value is bool) return value.toString();
  }
  return null;
}

void _validateMemoryRevision(int revision) {
  if (revision < 0) {
    throw const ApiException('Invalid memory revision.', statusCode: 422);
  }
}

MemoryControlState _parseControlState(Map<String, dynamic>? map) {
  try {
    return MemoryControlState.fromJson(map ?? const {});
  } on FormatException {
    throw const ApiException('Invalid memory control state.');
  }
}

MemoryRecord _requireVersionedMemory(Object? body) {
  final memory = _requireMemory(body);
  if (memory.revision == null) {
    throw const ApiException('Missing memory revision.');
  }
  return memory;
}
