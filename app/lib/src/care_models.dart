enum CheckInFrequency { daily, weekly }

class CheckInSchedule {
  const CheckInSchedule({
    this.id,
    this.enabled = false,
    this.frequency = CheckInFrequency.daily,
    this.checkInTime = '10:00',
    this.weekday = 1,
    this.taskReminders = false,
    this.familyReplies = false,
    this.quietStart = '21:00',
    this.quietEnd = '09:00',
    this.pausedUntil,
    this.skipDate,
  });

  final String? id;
  final bool enabled;
  final CheckInFrequency frequency;
  final String checkInTime;
  final int weekday;
  final bool taskReminders;
  final bool familyReplies;
  final String quietStart;
  final String quietEnd;
  final DateTime? pausedUntil;
  final String? skipDate;

  factory CheckInSchedule.fromJson(Map<String, dynamic> json) =>
      CheckInSchedule(
        id: json['id'] as String?,
        enabled: json['enabled'] == true,
        frequency: json['frequency'] == 'weekly'
            ? CheckInFrequency.weekly
            : CheckInFrequency.daily,
        checkInTime: json['check_in_time'] as String? ?? '10:00',
        weekday: json['weekday'] as int? ?? 1,
        taskReminders: json['task_reminders'] == true,
        familyReplies: json['family_replies'] == true,
        quietStart: json['quiet_start'] as String? ?? '21:00',
        quietEnd: json['quiet_end'] as String? ?? '09:00',
        pausedUntil: _careDate(json['paused_until']),
        skipDate: json['skip_date'] as String?,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'frequency': frequency.name,
        'check_in_time': checkInTime,
        'weekday': weekday,
        'task_reminders': taskReminders,
        'family_replies': familyReplies,
        'quiet_start': quietStart,
        'quiet_end': quietEnd,
        'paused_until': pausedUntil?.toUtc().toIso8601String(),
        'skip_date': skipDate,
      };

  CheckInSchedule copyWith({
    bool? enabled,
    CheckInFrequency? frequency,
    String? checkInTime,
    int? weekday,
    bool? taskReminders,
    bool? familyReplies,
    String? quietStart,
    String? quietEnd,
    DateTime? pausedUntil,
    bool clearPause = false,
    String? skipDate,
    bool clearSkip = false,
  }) =>
      CheckInSchedule(
        id: id,
        enabled: enabled ?? this.enabled,
        frequency: frequency ?? this.frequency,
        checkInTime: checkInTime ?? this.checkInTime,
        weekday: weekday ?? this.weekday,
        taskReminders: taskReminders ?? this.taskReminders,
        familyReplies: familyReplies ?? this.familyReplies,
        quietStart: quietStart ?? this.quietStart,
        quietEnd: quietEnd ?? this.quietEnd,
        pausedUntil: clearPause ? null : pausedUntil ?? this.pausedUntil,
        skipDate: clearSkip ? null : skipDate ?? this.skipDate,
      );
}

class CheckInTriggerResult {
  const CheckInTriggerResult({
    required this.triggered,
    required this.assistantText,
    this.messageId,
    this.conversationId,
  });

  final bool triggered;
  final String assistantText;
  final String? messageId;
  final String? conversationId;

  factory CheckInTriggerResult.fromJson(Map<String, dynamic> json) =>
      CheckInTriggerResult(
        triggered: json['triggered'] == true,
        assistantText: json['assistant_text'] as String? ?? '',
        messageId: json['message_id'] as String?,
        conversationId: json['conversation_id'] as String?,
      );
}

enum CareNotificationAction { acknowledged, handled }

class CareNotification {
  const CareNotification({
    required this.id,
    required this.kind,
    required this.body,
    required this.status,
    this.createdAt,
  });

  final String id;
  final String kind;
  final String body;
  final String status;
  final DateTime? createdAt;

  factory CareNotification.fromJson(Map<String, dynamic> json) =>
      CareNotification(
        id: json['id'] as String,
        kind: json['kind'] as String,
        body: json['body'] as String,
        status: json['status'] as String,
        createdAt: _careDate(json['created_at']),
      );
}

class EmergencyContact {
  const EmergencyContact({
    required this.id,
    required this.label,
    required this.caregiverName,
    required this.isEnabled,
  });

  final String id;
  final String label;
  final String caregiverName;
  final bool isEnabled;

  factory EmergencyContact.fromJson(Map<String, dynamic> json) =>
      EmergencyContact(
        id: json['id'] as String,
        label: json['label'] as String,
        caregiverName: json['caregiver_name'] as String,
        isEnabled: json['is_enabled'] == true,
      );
}

class SafetyEvent {
  const SafetyEvent({
    required this.id,
    this.triggerMessageId,
    this.createdAt,
    this.resolvedAt,
    required this.supportRequestSent,
  });

  final String id;
  final String? triggerMessageId;
  final DateTime? createdAt;
  final DateTime? resolvedAt;
  final bool supportRequestSent;

  factory SafetyEvent.fromJson(Map<String, dynamic> json) => SafetyEvent(
        id: json['id'] as String,
        triggerMessageId: json['trigger_message_id'] as String?,
        createdAt: _careDate(json['created_at']),
        resolvedAt: _careDate(json['resolved_at']),
        supportRequestSent: json['support_request_sent'] == true,
      );
}

DateTime? _careDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
