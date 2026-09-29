class HumanGroup {
  const HumanGroup({required this.id, required this.title, required this.ownerId,
    required this.ownerName, required this.memberCount});

  final String id;
  final String title;
  final String ownerId;
  final String ownerName;
  final int memberCount;

  factory HumanGroup.fromJson(Map<String, dynamic> json) => HumanGroup(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    ownerId: json['owner_id'] as String? ?? '',
    ownerName: json['owner_name'] as String? ?? '',
    memberCount: json['member_count'] as int? ?? 0,
  );
}

class HumanGroupInvitation {
  const HumanGroupInvitation({required this.id, required this.groupId,
    required this.groupTitle, required this.inviterName});

  final String id;
  final String groupId;
  final String groupTitle;
  final String inviterName;

  factory HumanGroupInvitation.fromJson(Map<String, dynamic> json) =>
      HumanGroupInvitation(
        id: json['id'] as String? ?? '',
        groupId: json['group_id'] as String? ?? '',
        groupTitle: json['group_title'] as String? ?? '',
        inviterName: json['inviter_name'] as String? ?? '',
      );
}

class HumanGroupMember {
  const HumanGroupMember({required this.accountId, required this.displayName,
    required this.role});

  final String accountId;
  final String displayName;
  final String role;

  factory HumanGroupMember.fromJson(Map<String, dynamic> json) => HumanGroupMember(
    accountId: json['account_id'] as String? ?? '',
    displayName: json['display_name'] as String? ?? '',
    role: json['role'] as String? ?? 'member',
  );
}

class HumanGroupMessage {
  const HumanGroupMessage({required this.id, required this.groupId,
    required this.senderId, required this.senderName, required this.ordinal,
    required this.content});

  final String id;
  final String groupId;
  final String senderId;
  final String senderName;
  final int ordinal;
  final String content;

  factory HumanGroupMessage.fromJson(Map<String, dynamic> json) =>
      HumanGroupMessage(
        id: json['id'] as String? ?? '',
        groupId: json['group_id'] as String? ?? '',
        senderId: json['sender_id'] as String? ?? '',
        senderName: json['sender_name'] as String? ?? '',
        ordinal: json['ordinal'] as int? ?? 0,
        content: json['content'] as String? ?? '',
      );
}

enum HumanGroupLiveEventType {
  connected,
  messagesChanged,
  reconnecting,
  accessRevoked,
}

class HumanGroupLiveEvent {
  const HumanGroupLiveEvent(this.type);

  final HumanGroupLiveEventType type;
}
