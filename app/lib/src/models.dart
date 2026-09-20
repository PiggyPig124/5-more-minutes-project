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
    return ChatMessage(
      id: _string(json, const ['id', 'message_id', 'client_message_id']) ??
          _stableId(json),
      conversationId: conversationId ??
          (_string(json, const ['conversation_id', 'conversationId']) ?? ''),
      body: _string(json, const ['content', 'body', 'text', 'message']) ?? '',
      isFromUser: resolvedIsFromUser,
      createdAt: _date(json, const ['created_at', 'createdAt', 'timestamp']),
      pending: _bool(json, const ['pending', 'is_pending']) ?? false,
      metadata: _map(json['metadata_json'] ?? json['metadata']) ?? const <String, dynamic>{},
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
  });

  final String id;
  final String email;
  final InvitationStatus status;
  final String? name;
  final DateTime? createdAt;
  final String? token;

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
  return null;
}

List<Map<String, dynamic>> mapsFromJson(Object? value) {
  if (value is List) {
    return value.map(_map).whereType<Map<String, dynamic>>().toList();
  }
  final map = _map(value);
  if (map == null) return const [];
  for (final key in const ['items', 'data', 'results', 'conversations', 'messages', 'tasks', 'invitations']) {
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
