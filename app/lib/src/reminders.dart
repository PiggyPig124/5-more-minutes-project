import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'models.dart';

final reminderSchedulerProvider =
    Provider<ReminderScheduler>((ref) => ReminderScheduler());

DateTime calculateCheckInDateTime(
  DateTime now,
  TimeOfDay selected, {
  required bool weekly,
  required int weekday,
  required bool afterInteraction,
}) {
  final hour = selected.hour < 9 || selected.hour >= 21 ? 9 : selected.hour;
  final minute = selected.hour < 9 || selected.hour >= 21 ? 0 : selected.minute;
  var dayOffset = weekly ? (weekday - now.weekday + 7) % 7 : 0;
  if (afterInteraction) {
    if (!weekly) {
      dayOffset = 1;
    } else if (dayOffset == 0) {
      dayOffset = 7;
    }
  }
  var scheduled = DateTime(
    now.year,
    now.month,
    now.day + dayOffset,
    hour,
    minute,
  );
  if (!afterInteraction && !scheduled.isAfter(now)) {
    dayOffset += weekly ? 7 : 1;
    scheduled = DateTime(
      now.year,
      now.month,
      now.day + dayOffset,
      hour,
      minute,
    );
  }
  return scheduled;
}

DateTime respectQuietHours(DateTime dueAt) {
  if (dueAt.hour >= 21) {
    return DateTime(dueAt.year, dueAt.month, dueAt.day + 1, 9);
  }
  if (dueAt.hour < 9) {
    return DateTime(dueAt.year, dueAt.month, dueAt.day, 9);
  }
  return dueAt;
}

class ReminderScheduler {
  ReminderScheduler({
    FlutterLocalNotificationsPlugin? notifications,
    SharedPreferencesAsync? preferences,
  })  : _notifications = notifications ?? FlutterLocalNotificationsPlugin(),
        _preferences = preferences ?? SharedPreferencesAsync();

  static const int _checkInNotificationId = 900000;
  static const String _channelId = 'anxin_reminders';
  final FlutterLocalNotificationsPlugin _notifications;
  final SharedPreferencesAsync _preferences;
  Future<void>? _initialization;

  Future<bool> get supported async =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _initialize() async {
    final current = _initialization;
    if (current != null) {
      return current;
    }
    final attempt = _initializePlatform();
    _initialization = attempt;
    try {
      await attempt;
    } on Object {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _initializePlatform() async {
    if (!await supported) {
      throw UnsupportedError(
          'Scheduled notifications are available in the Android app.');
    }
    timezone_data.initializeTimeZones();
    final localTimezone = await FlutterTimezone.getLocalTimezone();
    timezone.setLocalLocation(timezone.getLocation(localTimezone));
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        'Anxin reminders',
        description: 'Opt-in check-ins and due task reminders.',
        importance: Importance.defaultImportance,
      ),
    );
  }

  Future<bool> requestPermission() async {
    await _initialize();
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? false;
  }

  Future<bool> readDailyCheckInEnabled(String userId) async =>
      await _preferences.getBool(_key(userId, 'daily_check_in')) ?? false;

  Future<TimeOfDay> readDailyCheckInTime(String userId) async {
    final value =
        await _preferences.getString(_key(userId, 'daily_check_in_time'));
    if (value == null) return const TimeOfDay(hour: 10, minute: 0);
    final parts = value.split(':');
    if (parts.length != 2) return const TimeOfDay(hour: 10, minute: 0);
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return const TimeOfDay(hour: 10, minute: 0);
    }

    return TimeOfDay(hour: hour, minute: minute);
  }

  Future<bool> readWeeklyCheckIn(String userId) async =>
      await _preferences.getBool(_key(userId, 'weekly_check_in')) ?? false;

  Future<int> readCheckInWeekday(String userId) async {
    final weekday = await _preferences.getInt(_key(userId, 'check_in_weekday'));
    return weekday != null && weekday >= 1 && weekday <= 7 ? weekday : 1;
  }

  Future<void> setDailyCheckIn({
    required String userId,
    required bool enabled,
    required TimeOfDay time,
    required bool weekly,
    required int weekday,
  }) async {
    await _preferences.setBool(_key(userId, 'daily_check_in'), enabled);
    await _preferences.setString(
      _key(userId, 'daily_check_in_time'),
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    );
    await _preferences.setBool(_key(userId, 'weekly_check_in'), weekly);
    await _preferences.setInt(_key(userId, 'check_in_weekday'), weekday);
    if (!enabled) {
      if (await supported) {
        await _initialize();
        await _notifications.cancel(_checkInNotificationId);
      }
      return;
    }
    try {
      await _initialize();
      final allowed = await requestPermission();
      if (!allowed) {
        throw StateError('Notification permission was not granted.');
      }
      final activityDay =
          await _preferences.getString(_key(userId, 'last_activity_day'));
      await _scheduleCheckIn(
        userId,
        time,
        weekly: weekly,
        weekday: weekday,
        fromTomorrow: activityDay == _dayStamp(DateTime.now()),
      );
    } on Object {
      await _preferences.setBool(_key(userId, 'daily_check_in'), false);
      if (await supported) {
        await _notifications.cancel(_checkInNotificationId);
      }
      rethrow;
    }
  }

  Future<bool> readTaskRemindersEnabled(String userId) async =>
      await _preferences.getBool(_key(userId, 'task_reminders')) ?? false;

  Future<void> setTaskReminders({
    required String userId,
    required bool enabled,
    required List<CareTask> tasks,
  }) async {
    await _preferences.setBool(_key(userId, 'task_reminders'), enabled);
    if (!enabled) {
      await _cancelTaskReminders(userId);
      return;
    }
    try {
      await _initialize();
      if (!await requestPermission()) {
        throw StateError('Notification permission was not granted.');
      }
      await syncDueTasks(userId, tasks);
    } on Object {
      await _preferences.setBool(_key(userId, 'task_reminders'), false);
      await _cancelTaskReminders(userId);
      rethrow;
    }
  }

  Future<void> syncDueTasks(String userId, List<CareTask> tasks) async {
    if (await readDailyCheckInEnabled(userId)) {
      await _initialize();
      final time = await readDailyCheckInTime(userId);
      final weekly = await readWeeklyCheckIn(userId);
      final weekday = await readCheckInWeekday(userId);
      final activityDay =
          await _preferences.getString(_key(userId, 'last_activity_day'));
      await _scheduleCheckIn(
        userId,
        time,
        weekly: weekly,
        weekday: weekday,
        fromTomorrow: activityDay == _dayStamp(DateTime.now()),
      );
    }
    if (!await readTaskRemindersEnabled(userId)) {
      await _cancelTaskReminders(userId);
      return;
    }
    await _initialize();
    final previous = await _readScheduledTaskIds(userId);
    final dueTasks = tasks
        .where((task) =>
            task.dueAt != null &&
            task.dueAt!.isAfter(DateTime.now()) &&
            task.status != TaskStatus.completed &&
            task.status != TaskStatus.dismissed)
        .toList(growable: false);
    final nextIds =
        dueTasks.map((task) => _stableNotificationId(task.id)).toSet();
    await _preferences.setString(
      _scheduledIdsKey(userId),
      jsonEncode(nextIds.toList(growable: false)),
    );
    for (final staleId in previous.difference(nextIds)) {
      await _notifications.cancel(staleId);
    }
    for (final task in dueTasks) {
      await _notifications.zonedSchedule(
        _stableNotificationId(task.id),
        'Anxin reminder',
        'You have a care task due. Open Anxin Companion to review it.',
        timezone.TZDateTime.from(
          respectQuietHours(task.dueAt!),
          timezone.local,
        ),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Anxin reminders',
            channelDescription: 'Opt-in check-ins and due task reminders.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  Future<void> markConversationActivity(String userId) async {
    if (!await readDailyCheckInEnabled(userId)) return;
    await _preferences.setString(
      _key(userId, 'last_activity_day'),
      _dayStamp(DateTime.now()),
    );
    await _initialize();
    final time = await readDailyCheckInTime(userId);
    final weekly =
        await _preferences.getBool(_key(userId, 'weekly_check_in')) ?? false;
    final weekday =
        await _preferences.getInt(_key(userId, 'check_in_weekday')) ?? 1;
    await _scheduleCheckIn(
      userId,
      time,
      weekly: weekly,
      weekday: weekday,
      fromTomorrow: true,
    );
  }

  Future<void> cancelUserNotifications(String userId) async {
    if (!await supported) return;
    final checkInEnabled = await readDailyCheckInEnabled(userId);
    final taskIds = await _readScheduledTaskIds(userId);
    if (!checkInEnabled && taskIds.isEmpty) return;
    await _initialize();
    await _cancelTaskReminders(userId);
    if (checkInEnabled) {
      await _notifications.cancel(_checkInNotificationId);
    }
  }

  Future<void> _cancelTaskReminders(String userId) async {
    final taskIds = await _readScheduledTaskIds(userId);
    if (taskIds.isEmpty) return;
    await _initialize();
    for (final id in taskIds) {
      await _notifications.cancel(id);
    }
    await _preferences.remove(_scheduledIdsKey(userId));
  }

  Future<void> _scheduleCheckIn(
    String userId,
    TimeOfDay selected, {
    required bool weekly,
    required int weekday,
    required bool fromTomorrow,
  }) async {
    final now = timezone.TZDateTime.now(timezone.local);
    final firstLocal = calculateCheckInDateTime(
      now,
      selected,
      weekly: weekly,
      weekday: weekday,
      afterInteraction: fromTomorrow,
    );
    final first = timezone.TZDateTime(
      timezone.local,
      firstLocal.year,
      firstLocal.month,
      firstLocal.day,
      firstLocal.hour,
      firstLocal.minute,
    );
    await _notifications.zonedSchedule(
      _checkInNotificationId,
      'Anxin Companion',
      'A gentle check-in is ready when you are.',
      first,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Anxin reminders',
          channelDescription: 'Opt-in check-ins and due task reminders.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: weekly
          ? DateTimeComponents.dayOfWeekAndTime
          : DateTimeComponents.time,
    );
    await _preferences.setString(
        _key(userId, 'last_check_in_schedule'), first.toIso8601String());
  }

  Future<Set<int>> _readScheduledTaskIds(String userId) async {
    final raw = await _preferences.getString(_scheduledIdsKey(userId));
    if (raw == null) return <int>{};
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Invalid scheduled task id list.');
    }
    return decoded.map((value) {
      if (value is! int ||
          value <= 0 ||
          value > 0x7fffffff ||
          value == _checkInNotificationId) {
        throw const FormatException('Invalid scheduled notification id.');
      }
      return value;
    }).toSet();
  }

  static int _stableNotificationId(String value) {
    var hash = 2166136261;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ byte) * 16777619) & 0xffffffff;
    }
    final id = hash % 0x7ffffffe + 1;
    return id == _checkInNotificationId ? id + 1 : id;
  }

  static String _key(String userId, String setting) => 'anxin.$userId.$setting';
  static String _scheduledIdsKey(String userId) =>
      _key(userId, 'scheduled_task_ids');
  static String _dayStamp(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}
