import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
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
  Future<HumanGroupInvitation> inviteHumanGroupMember(String groupId, String email);
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

class RestApiClient
    implements
        AnxinApi,
        GuestApi,
        ConsentApi,
        CommunityApi,
        MemorySaveApi,
        GuestResourceApi, HumanGroupApi {
  RestApiClient({
    String? origin,
    http.Client? client,
    this.accessToken,
    Duration requestTimeout = const Duration(seconds: 60),
  })  : origin = _normalizeOrigin(origin ?? defaultApiOrigin),
        _client = client ?? http.Client(),
        _requestTimeout = requestTimeout;

  final String origin;
  final http.Client _client;
  final Duration _requestTimeout;
  String? accessToken;

  @override
  Future<List<HumanGroup>> listHumanGroups() async =>
      mapsFromJson(await _request('GET', '/groups'))
          .map(HumanGroup.fromJson).toList(growable: false);

  @override
  Future<List<HumanGroupInvitation>> listHumanGroupInvitations() async =>
      mapsFromJson(await _request('GET', '/groups/invitations'))
          .map(HumanGroupInvitation.fromJson).toList(growable: false);

  @override
  Future<HumanGroup> createHumanGroup(String title) async => HumanGroup.fromJson(
      mapFromJson(await _request('POST', '/groups', body: {'title': title}))!);

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
          .map(HumanGroupMember.fromJson).toList(growable: false);

  @override
  Future<List<HumanGroupMessage>> listHumanGroupMessages(String groupId) async =>
      mapsFromJson(await _request(
          'GET', '/groups/${Uri.encodeComponent(groupId)}/messages'))
          .map(HumanGroupMessage.fromJson).toList(growable: false);

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
          controller.add(const HumanGroupLiveEvent(
              HumanGroupLiveEventType.accessRevoked));
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
              authenticated.completeError(
                  StateError('The group connection closed before authentication.'));
            }
            if (!disconnectedAttempt.isCompleted) {
              disconnectedAttempt.complete(openedChannel.closeCode);
            }
          });
          openedChannel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
          await authenticated.future.timeout(const Duration(seconds: 10));
          if (cancelled) break;
          controller.add(const HumanGroupLiveEvent(
              HumanGroupLiveEventType.connected));
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
          controller.add(const HumanGroupLiveEvent(
              HumanGroupLiveEventType.reconnecting));
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
    final map = mapFromJson(await _request(
      'PUT',
      '/memories/consent',
      body: {'enabled': enabled},
    ));
    if (map == null || map['enabled'] is! bool) {
      throw const ApiException('服務未確認記憶設定。');
    }
    return map['enabled'] as bool;
  }

  @override
  Future<MemoryRecord> saveConfirmedMemory(
      {required String content,
      required String kind,
      String? sourceMessageId,
      String? topicKey}) async {
    final body = await _request('POST', '/memories/save', body: {
      'content': content,
      'kind': kind,
      if (sourceMessageId != null && sourceMessageId.trim().isNotEmpty)
        'source_message_id': sourceMessageId,
      if (topicKey != null && topicKey.trim().isNotEmpty)
        'topic_key': topicKey,
    });
    return _requireMemory(body);
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
    final map =
        mapFromJson(await _request('GET', '/community/skills/suggestions'));
    return mapsFromJson(map?['items']).map(SkillSuggestion.fromJson).toList();
  }

  @override
  Future<SkillSuggestion> decideSkill(String id,
      {required String decision, String? skill}) async {
    final map = mapFromJson(await _request(
      'POST',
      '/community/skills/${Uri.encodeComponent(id)}/decision',
      body: {'decision': decision, if (skill != null) 'skill': skill},
    ));
    if (map == null) throw const ApiException('服務未確認技能選擇。');
    return SkillSuggestion.fromJson(map);
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
      _ => throw FormatException('Unsupported API origin scheme: ${uri.scheme}'),
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
    final body = await _request('POST', '/memories', body: {
      'content': content,
      'kind': kind,
      if (sourceMessageId != null && sourceMessageId.trim().isNotEmpty)
        'source_message_id': sourceMessageId,
    });
    return _requireMemory(body);
  }

  @override
  Future<MemoryRecord> confirmMemory(String memoryId) async {
    final body = await _request(
      'POST',
      '/memories/${Uri.encodeComponent(memoryId)}/confirm',
    );
    return _requireMemory(body);
  }

  @override
  Future<MemoryRecord> updateMemory(
    String memoryId, {
    String? content,
    bool? suppressed,
  }) async {
    final body = await _request(
      'PATCH',
      '/memories/${Uri.encodeComponent(memoryId)}',
      body: {
        if (content != null) 'content': content,
        if (suppressed != null) 'suppressed': suppressed,
      },
    );
    return _requireMemory(body);
  }

  @override
  Future<void> deleteMemory(String memoryId) async {
    await _request(
      'DELETE',
      '/memories/${Uri.encodeComponent(memoryId)}',
    );
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
    final body = await _request('POST', '/stories', body: {
      'title': title,
      'content': content,
      'memory_ids': memoryIds,
    });
    final map = mapFromJson(body);
    if (map == null) throw const ApiException('服務未回覆故事資料。');
    final story = StoryRecord.fromJson(map);
    if (story.id.isEmpty) throw const ApiException('服務未回覆故事編號。');
    return story;
  }

  @override
  Future<void> deleteStory(String storyId) async {
    await _request('DELETE', '/stories/${Uri.encodeComponent(storyId)}');
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
  }) async {
    final body = await _request(
      'POST',
      '/family-messages',
      body: {
        'recipient_id': recipientId,
        'content': content,
        'client_message_id': clientMessageId,
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
