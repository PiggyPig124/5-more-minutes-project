import 'dart:convert';

enum UserRole {
  elder,
  caregiver;

  static UserRole fromJson(Object? value) {
    final normalized = value?.toString().toLowerCase().trim();
    switch (normalized) {
      case 'caregiver':
      case 'carer':
      case 'family':
      case 'family_member':
        return UserRole.caregiver;
      default:
        return UserRole.elder;
    }
  }

  String get apiValue => this == UserRole.elder ? 'elder' : 'caregiver';

  String get label => this == UserRole.elder ? '長者' : '照顧者';
}

class AppUser {
  const AppUser({
    required this.id,
    required this.displayName,
    required this.email,
    required this.role,
  });

  final String id;
  final String displayName;
  final String email;
  final UserRole role;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: _string(json, const ['id', 'user_id', 'uid']) ?? '',
      displayName: _string(json, const [
            'display_name',
            'displayName',
            'name',
          ]) ??
          '',
      email: _string(json, const ['email', 'mail']) ?? '',
      role: UserRole.fromJson(json['role'] ?? json['user_role']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'display_name': displayName,
        'email': email,
        'role': role.apiValue,
      };
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.user,
    this.demoMode = false,
  });

  final String accessToken;
  final AppUser user;
  final bool demoMode;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final userJson = _map(json['user']) ?? _map(json['account']) ?? json;
    return AuthSession(
      accessToken: _string(json, const [
            'access_token',
            'accessToken',
            'token',
          ]) ??
          '',
      user: AppUser.fromJson(userJson),
      demoMode: _bool(json, const ['demo_mode', 'demoMode', 'is_demo']) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'user': user.toJson(),
        'demo_mode': demoMode,
      };
}

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    this.updatedAt,
    this.preview,
    this.isShared = false,
  });

  final String id;
  final String title;
  final DateTime? updatedAt;
  final String? preview;
  final bool isShared;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: _string(json, const ['id', 'conversation_id']) ?? '',
      title: _string(json, const ['title', 'name', 'subject']) ?? '新對話',
      updatedAt: _date(json, const ['updated_at', 'updatedAt', 'created_at']),
      preview: _string(json, const ['preview', 'last_message', 'summary']),
      isShared: _bool(json, const ['is_shared', 'shared']) ?? false,
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.isFromUser,
    required this.createdAt,
    this.pending = false,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String conversationId;
  final String body;
  final bool isFromUser;
  final DateTime? createdAt;
  final bool pending;
  final Map<String, dynamic> metadata;

  /// The retrieval label and source excerpts returned with an assistant
  /// response. They are informational only; saving a memory always requires
  /// an explicit user action.
  String? get retrievalMode => _string(metadata, const [
        'retrieval_mode',
        'retrievalMode',
        'memory_retrieval_mode',
        'resource_retrieval_mode',
        'mode',
      ]);

  List<MemorySource> get memorySources {
    final raw = metadata['memory_sources'] ?? metadata['memorySources'];
    if (raw is! List) return const [];
    return raw
        .map(_map)
        .whereType<Map<String, dynamic>>()
        .map(MemorySource.fromJson)
        .where((source) => source.content.trim().isNotEmpty)
        .toList(growable: false);
  }

  String? get candidateMemoryId => _string(metadata, const [
        'candidate_memory_id',
        'candidateMemoryId',
      ]);

  factory ChatMessage.fromJson(
    Map<String, dynamic> json, {
    String? conversationId,
    bool? isFromUser,
  }) {
    final sender = _string(json, const ['sender', 'author', 'role', 'from']);
    final resolvedIsFromUser = isFromUser ??
        (sender?.toLowerCase() == 'user' ||
            sender?.toLowerCase() == 'elder' ||
            sender?.toLowerCase() == 'me');
    final resolvedMetadata = <String, dynamic>{
      ...?_map(json['metadata_json'] ?? json['metadata']),
      if (json['retrieval_mode'] != null) 'retrieval_mode': json['retrieval_mode'],
      if (json['memory_retrieval_mode'] != null)
        'memory_retrieval_mode': json['memory_retrieval_mode'],
      if (json['resource_retrieval_mode'] != null)
        'resource_retrieval_mode': json['resource_retrieval_mode'],
      if (json['memory_sources'] != null) 'memory_sources': json['memory_sources'],
    };
    return ChatMessage(
      id: _string(json, const ['id', 'message_id', 'client_message_id']) ??
          _stableId(json),
      conversationId: conversationId ??
          (_string(json, const ['conversation_id', 'conversationId']) ?? ''),
      body: _string(json, const ['content', 'body', 'text', 'message']) ?? '',
      isFromUser: resolvedIsFromUser,
      createdAt: _date(json, const ['created_at', 'createdAt', 'timestamp']),
      pending: _bool(json, const ['pending', 'is_pending']) ?? false,
      metadata: resolvedMetadata,
    );
  }
}

enum TaskStatus {
  pending,
  inProgress,
  completed,
  dismissed,
  failed;

  static TaskStatus fromJson(Object? value) {
    switch (value?.toString().toLowerCase().replaceAll('-', '_')) {
      case 'in_progress':
      case 'doing':
        return TaskStatus.inProgress;
      case 'completed':
      case 'complete':
      case 'done':
        return TaskStatus.completed;
      case 'dismissed':
      case 'cancelled':
      case 'canceled':
        return TaskStatus.dismissed;
      case 'failed':
      case 'error':
        return TaskStatus.failed;
      default:
        return TaskStatus.pending;
    }
  }

  String get apiValue {
    switch (this) {
      case TaskStatus.pending:
        return 'pending';
      case TaskStatus.inProgress:
        return 'in_progress';
      case TaskStatus.completed:
        return 'completed';
      case TaskStatus.dismissed:
        return 'dismissed';
      case TaskStatus.failed:
        return 'failed';
    }
  }

  String get label {
    switch (this) {
      case TaskStatus.pending:
        return '待處理';
      case TaskStatus.inProgress:
        return '進行中';
      case TaskStatus.completed:
        return '已完成';
      case TaskStatus.dismissed:
        return '已略過';
      case TaskStatus.failed:
        return '需要重試';
    }
  }
}

class CareTask {
  const CareTask({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    this.dueAt,
    this.isShared = true,
  });

  final String id;
  final String title;
  final String description;
  final TaskStatus status;
  final DateTime? dueAt;
  final bool isShared;

  factory CareTask.fromJson(Map<String, dynamic> json) {
    return CareTask(
      id: _string(json, const ['id', 'task_id']) ?? '',
      title: _string(json, const ['title', 'name']) ?? '照顧事項',
      description: _string(json, const ['description', 'details', 'content']) ?? '',
      status: TaskStatus.fromJson(json['status']),
      dueAt: _date(json, const ['due_at', 'dueAt', 'scheduled_for']),
      isShared: _bool(json, const ['is_shared', 'shared']) ?? true,
    );
  }
}

enum ActionKind {
  task,
  message,
  invitation,
  unknown;

  static ActionKind fromJson(Object? value) {
    switch (value?.toString().toLowerCase()) {
      case 'task':
      case 'reminder':
      case 'care_task':
      case 'appointment':
        return ActionKind.task;
      case 'message':
      case 'family_message':
        return ActionKind.message;
      case 'invitation':
      case 'family_invitation':
        return ActionKind.invitation;
      default:
        return ActionKind.unknown;
    }
  }
}

class ActionProposal {
  const ActionProposal({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    this.conversationId,
    this.recipientLabel,
    this.confirmed = false,
    this.dismissed = false,
  });

  final String id;
  final ActionKind kind;
  final String title;
  final String description;
  final String? conversationId;
  final String? recipientLabel;
  final bool confirmed;
  final bool dismissed;

  factory ActionProposal.fromJson(Map<String, dynamic> json) {
    final recipient = _map(json['recipient']);
    final payload = _map(json['payload']);
    final status = (json['status'] ?? payload?['status'])?.toString().toLowerCase();
    final source = <String, dynamic>{
      ...?payload,
      ...json,
    };
    return ActionProposal(
      id: _string(source, const ['id', 'action_id']) ?? '',
      kind: ActionKind.fromJson(source['kind'] ?? source['type'] ?? source['action_type']),
      title: _string(source, const ['title', 'name']) ?? '需要你確認的事項',
      description: _string(source, const ['description', 'preview', 'content']) ?? '',
      conversationId: _string(source, const ['conversation_id', 'conversationId']),
      recipientLabel: _string(source, const [
            'recipient_label',
            'recipientLabel',
            'recipient',
          ]) ??
          _string(recipient, const ['name', 'email']),
      confirmed: _bool(source, const ['confirmed', 'is_confirmed']) ??
          (status == 'confirmed' || status == 'executed' || status == 'completed'),
      dismissed: _bool(source, const ['dismissed', 'is_dismissed']) ??
          (status == 'dismissed' || status == 'cancelled' || status == 'canceled'),
    );
  }
}

enum InvitationStatus {
  pending,
  accepted,
  revoked,
  expired,
  unknown;

  static InvitationStatus fromJson(Object? value) {
    switch (value?.toString().toLowerCase()) {
      case 'pending':
      case 'sent':
        return InvitationStatus.pending;
      case 'accepted':
      case 'active':
        return InvitationStatus.accepted;
      case 'revoked':
      case 'cancelled':
      case 'canceled':
        return InvitationStatus.revoked;
      case 'expired':
        return InvitationStatus.expired;
      default:
        return InvitationStatus.unknown;
    }
  }

  String get label {
    switch (this) {
      case InvitationStatus.pending:
        return '等待接受';
      case InvitationStatus.accepted:
        return '已連結';
      case InvitationStatus.revoked:
        return '已撤回';
      case InvitationStatus.expired:
        return '已過期';
      case InvitationStatus.unknown:
        return '未知道狀態';
    }
  }
}

class FamilyInvitation {
  const FamilyInvitation({
    required this.id,
    required this.email,
    required this.status,
    this.name,
    this.createdAt,
    this.token,
    this.scopes = const ['care_tasks'],
    this.elderId,
    this.caregiverId,
    this.elderName,
    this.caregiverName,
  });

  final String id;
  final String email;
  final InvitationStatus status;
  final String? name;
  final DateTime? createdAt;
  final String? token;
  final List<String> scopes;
  final String? elderId;
  final String? caregiverId;
  final String? elderName;
  final String? caregiverName;

  bool get allowsFamilyMessages => scopes.contains('family_messages');

  factory FamilyInvitation.fromJson(Map<String, dynamic> json) {
    final elder = _map(json['elder']);
    final caregiver = _map(json['caregiver']);
    final counterpart = caregiver ?? elder;
    return FamilyInvitation(
      id: _string(json, const ['id', 'invitation_id', 'link_id']) ?? '',
      email: _string(json, const [
            'email',
            'invitee_email',
            'inviter_email',
          ]) ??
          _string(counterpart, const ['email']) ?? '',
      status: InvitationStatus.fromJson(json['status']),
      name: _string(json, const [
        'name',
        'invitee_name',
        'inviter_name',
      ]) ??
          _string(counterpart, const ['display_name', 'name']),
      createdAt: _date(json, const ['created_at', 'createdAt']),
      token: _string(json, const ['token', 'invitation_token']),
      scopes: (_stringList(json['scopes'] ?? json['permissions']) ??
              const ['care_tasks'])
          .where((scope) => scope.isNotEmpty)
          .toList(growable: false),
      elderId: _string(json, const ['elder_id', 'elderId']) ??
          _string(elder, const ['id', 'user_id']),
      caregiverId: _string(json, const ['caregiver_id', 'caregiverId']) ??
          _string(caregiver, const ['id', 'user_id']),
      elderName: _string(json, const ['elder_name', 'elderName']) ??
          _string(elder, const ['display_name', 'name']),
      caregiverName: _string(json, const ['caregiver_name', 'caregiverName']) ??
          _string(caregiver, const ['display_name', 'name']),
    );
  }
}

/// A memory candidate or saved personal memory. Candidate records are shown
/// to the account owner and are never silently confirmed by the client.
class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.content,
    required this.kind,
    this.status = 'candidate',
    this.suppressed = false,
    this.createdAt,
    this.updatedAt,
    this.sourceMessageId,
  });

  final String id;
  final String content;
  final String kind;
  final String status;
  final bool suppressed;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? sourceMessageId;

  bool get isCandidate => status.toLowerCase() == 'candidate' ||
      status.toLowerCase() == 'pending' ||
      status.isEmpty;
  bool get isConfirmed => status.toLowerCase() == 'confirmed' ||
      status.toLowerCase() == 'active' ||
      status.toLowerCase() == 'saved';

  factory MemoryRecord.fromJson(Map<String, dynamic> json) {
    return MemoryRecord(
      id: _string(json, const ['id', 'memory_id']) ?? '',
      content: _string(json, const ['content', 'text', 'summary']) ?? '',
      kind: _string(json, const ['kind', 'type', 'memory_kind']) ?? 'note',
      status: _string(json, const ['status', 'state']) ?? 'candidate',
      suppressed: _bool(json, const ['suppressed', 'is_suppressed']) ?? false,
      createdAt: _date(json, const ['created_at', 'createdAt']),
      updatedAt: _date(json, const ['updated_at', 'updatedAt']),
      sourceMessageId: _string(json, const [
        'source_message_id',
        'sourceMessageId',
      ]),
    );
  }
}

class MemorySearchResult {
  const MemorySearchResult({
    this.items = const [],
    this.retrievalMode,
  });

  final List<MemoryRecord> items;
  final String? retrievalMode;
}

class StoryRecord {
  const StoryRecord({
    required this.id,
    required this.title,
    required this.content,
    this.memoryIds = const [],
    this.createdAt,
  });

  final String id;
  final String title;
  final String content;
  final List<String> memoryIds;
  final DateTime? createdAt;

  factory StoryRecord.fromJson(Map<String, dynamic> json) {
    return StoryRecord(
      id: _string(json, const ['id', 'story_id']) ?? '',
      title: _string(json, const ['title', 'name']) ?? '我的故事',
      content: _string(json, const ['content', 'body', 'text']) ?? '',
      memoryIds: _stringList(json['memory_ids'] ?? json['memoryIds']) ?? const [],
      createdAt: _date(json, const ['created_at', 'createdAt']),
    );
  }
}

class ResourceItem {
  const ResourceItem({
    required this.id,
    required this.title,
    required this.excerpt,
    this.url,
    this.verifiedAt,
    this.effectiveDate,
    this.conditions = const [],
    this.missingInformation = const [],
    this.nextSteps = const [],
  });

  final String id;
  final String title;
  final String excerpt;
  final String? url;
  final DateTime? verifiedAt;
  final DateTime? effectiveDate;
  final List<String> conditions;
  final List<String> missingInformation;
  final List<String> nextSteps;

  factory ResourceItem.fromJson(Map<String, dynamic> json) {
    return ResourceItem(
      id: _string(json, const ['id', 'resource_id']) ?? '',
      title: _string(json, const ['title', 'name']) ?? '資料',
      excerpt: _string(json, const ['excerpt', 'summary', 'content']) ?? '',
      url: _string(json, const ['url', 'link']),
      verifiedAt: _date(json, const ['verified_at', 'verifiedAt']),
      effectiveDate: _date(json, const ['effective_date', 'effectiveDate']),
      conditions: _stringList(json['conditions']) ?? const [],
      missingInformation: _stringList(
            json['missing_information'] ?? json['missingInformation'],
          ) ??
          const [],
      nextSteps: _stringList(json['next_steps'] ?? json['nextSteps']) ?? const [],
    );
  }
}

class ResourceConflict {
  const ResourceConflict({
    this.title = '',
    this.summary = '',
    this.sources = const [],
  });

  final String title;
  final String summary;
  final List<String> sources;

  factory ResourceConflict.fromJson(Object? value) {
    final map = _map(value);
    if (map == null) {
      return ResourceConflict(summary: value?.toString() ?? '資料內容有差異');
    }
    return ResourceConflict(
      title: _string(map, const ['title', 'topic', 'name']) ?? '',
      summary: _string(map, const ['summary', 'description', 'details', 'content']) ??
          '資料內容有差異',
      sources: _stringList(map['sources'] ?? map['source_urls']) ?? const [],
    );
  }
}

class ResourceSearchResult {
  const ResourceSearchResult({
    this.query = '',
    this.retrievalMode,
    this.items = const [],
    this.conflicts = const [],
  });

  final String query;
  final String? retrievalMode;
  final List<ResourceItem> items;
  final List<ResourceConflict> conflicts;
}

class FamilyMessage {
  const FamilyMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    this.createdAt,
    this.sourceStoryId,
    this.senderName,
    this.recipientName,
  });

  final String id;
  final String senderId;
  final String recipientId;
  final String content;
  final DateTime? createdAt;
  final String? sourceStoryId;
  final String? senderName;
  final String? recipientName;

  factory FamilyMessage.fromJson(Map<String, dynamic> json) {
    final sender = _map(json['sender']);
    final recipient = _map(json['recipient']);
    return FamilyMessage(
      id: _string(json, const ['id', 'message_id']) ?? '',
      senderId: _string(json, const ['sender_id', 'senderId']) ??
          _string(sender, const ['id', 'user_id']) ??
          '',
      recipientId: _string(json, const ['recipient_id', 'recipientId']) ??
          _string(recipient, const ['id', 'user_id']) ??
          '',
      content: _string(json, const ['content', 'body', 'text']) ?? '',
      createdAt: _date(json, const ['created_at', 'createdAt', 'timestamp']),
      sourceStoryId: _string(json, const ['source_story_id', 'sourceStoryId']),
      senderName: _string(json, const ['sender_name', 'senderName']) ??
          _string(sender, const ['display_name', 'name']),
      recipientName: _string(json, const ['recipient_name', 'recipientName']) ??
          _string(recipient, const ['display_name', 'name']),
    );
  }
}

class MemorySource {
  const MemorySource({required this.id, required this.content});

  final String id;
  final String content;

  factory MemorySource.fromJson(Map<String, dynamic> json) {
    return MemorySource(
      id: _string(json, const ['id', 'memory_id']) ?? '',
      content: _string(json, const ['content', 'excerpt', 'text']) ?? '',
    );
  }
}

class SendMessageResult {
  const SendMessageResult({
    this.userMessage,
    this.assistantMessage,
    this.action,
    this.demoMode,
  });

  final ChatMessage? userMessage;
  final ChatMessage? assistantMessage;
  final ActionProposal? action;
  final bool? demoMode;
}

String _stableId(Map<String, dynamic> json) {
  final value = jsonEncode(json);
  return value.hashCode.toRadixString(16);
}

String? _string(Map<String, dynamic>? json, List<String> keys) {
  if (json == null) return null;
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is num || value is bool) return value.toString();
  }
  return null;
}

bool? _bool(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is bool) return value;
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
    if (value is num) return value != 0;
  }
  return null;
}

DateTime? _date(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toLocal();
    }
    if (value is num) {
      final millis = value > 100000000000 ? value.toInt() : value.toInt() * 1000;
      return DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    }
  }
  return null;
}

Map<String, dynamic>? _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      // Some older responses store free-form metadata as text.
    }
  }
  return null;
}

List<String>? _stringList(Object? value) {
  if (value is! List) return null;
  return value
      .map((item) {
        if (item is String) return item;
        final map = _map(item);
        return _string(map, const ['label', 'name', 'title', 'text', 'value']);
      })
      .whereType<String>()
      .toList(growable: false);
}

List<Map<String, dynamic>> mapsFromJson(Object? value) {
  if (value is List) {
    return value.map(_map).whereType<Map<String, dynamic>>().toList();
  }
  final map = _map(value);
  if (map == null) return const [];
  for (final key in const [
    'items',
    'data',
    'results',
    'conversations',
    'messages',
    'tasks',
    'invitations',
    'links',
    'memories',
    'stories',
    'family_messages',
    'familyMessages',
    'actions',
  ]) {
    final nested = map[key];
    if (nested is List) {
      return nested.map(_map).whereType<Map<String, dynamic>>().toList();
    }
  }
  return [map];
}

Map<String, dynamic>? mapFromJson(Object? value) {
  final map = _map(value);
  if (map == null) return null;
  final nested = _map(map['data']) ?? _map(map['result']);
  return nested ?? map;
}
