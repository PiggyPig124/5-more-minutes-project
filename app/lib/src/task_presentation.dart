import 'package:flutter/material.dart';

import 'localization.dart';
import 'models.dart';

String formatTaskHongKongTime(BuildContext context, DateTime? value) {
  if (value == null) return tr(context, '未設定', 'Not set');
  final hongKong = value.toUtc().add(const Duration(hours: 8));
  final material = MaterialLocalizations.of(context);
  final date = material.formatFullDate(hongKong);
  final time = material.formatTimeOfDay(
      TimeOfDay(hour: hongKong.hour, minute: hongKong.minute),
      alwaysUse24HourFormat: true);
  return '$date $time · ${tr(context, '香港時間 (UTC+8)', 'Hong Kong time (UTC+8)')}';
}

String taskTypeLabel(BuildContext context, String value) => switch (value) {
      'task' => tr(context, '照顧事項', 'Care task'),
      'reminder' => tr(context, '提醒', 'Reminder'),
      'appointment' => tr(context, '預約', 'Appointment'),
      'medication' => tr(context, '用藥提醒', 'Medication reminder'),
      _ => value,
    };

String taskStatusLabel(BuildContext context, TaskStatus value) =>
    Localizations.localeOf(context).languageCode == 'en'
        ? value.apiValue.replaceAll('_', ' ')
        : value.label;
