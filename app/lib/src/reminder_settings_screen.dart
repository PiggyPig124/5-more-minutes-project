import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'app_controller.dart';
import 'localization.dart';
import 'reminders.dart';

class ReminderSettingsScreen extends StatefulWidget {
  const ReminderSettingsScreen({
    required this.controller,
    required this.scheduler,
    super.key,
  });

  final AppController controller;
  final ReminderScheduler scheduler;
  @override
  State<ReminderSettingsScreen> createState() => _ReminderSettingsScreenState();
}

class _ReminderSettingsScreenState extends State<ReminderSettingsScreen> {
  ReminderScheduler get _scheduler => widget.scheduler;
  bool _loading = true;
  bool _saving = false;
  bool _checkInEnabled = false;
  bool _taskRemindersEnabled = false;
  bool _weekly = false;
  int _weekday = 1;
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  String? _error;

  @override
  void initState() {
    super.initState();
    Future<void>(_load);
  }

  Future<void> _load() async {
    final userId = widget.controller.user?.id;
    if (userId == null) {
      setState(() {
        _loading = false;
        _error = tr(context, '請先登入以設定提醒。', 'Sign in to configure reminders.');
      });
      return;
    }
    final scheduler = _scheduler;
    try {
      final values = await Future.wait<Object>([
        scheduler.readDailyCheckInEnabled(userId),
        scheduler.readDailyCheckInTime(userId),
        scheduler.readTaskRemindersEnabled(userId),
      ]);
      final weekly = await scheduler.readWeeklyCheckIn(userId);
      final weekday = await scheduler.readCheckInWeekday(userId);
      if (!mounted) return;
      setState(() {
        _checkInEnabled = values[0] as bool;
        _time = values[1] as TimeOfDay;
        _taskRemindersEnabled = values[2] as bool;
        _weekly = weekly;
        _weekday = weekday;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _saveCheckIn({bool? enabled}) async {
    final userId = widget.controller.user?.id;
    if (userId == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _scheduler.setDailyCheckIn(
        userId: userId,
        enabled: enabled ?? _checkInEnabled,
        time: _time,
        weekly: _weekly,
        weekday: _weekday,
      );
      if (!mounted) return;
      setState(() {
        _checkInEnabled = enabled ?? _checkInEnabled;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _notificationError(context, error);
        _checkInEnabled = false;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveTaskReminders(bool enabled) async {
    final controller = widget.controller;
    final userId = controller.user?.id;
    if (userId == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _scheduler.setTaskReminders(
        userId: userId,
        enabled: enabled,
        tasks: controller.tasks,
      );
      if (mounted) setState(() => _taskRemindersEnabled = enabled);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = _notificationError(context, error);
          _taskRemindersEnabled = false;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseTime() async {
    final selected = await showTimePicker(context: context, initialTime: _time);
    if (selected == null || !mounted) return;
    if (selected.hour < 9 || selected.hour >= 21) {
      setState(() {
        _error = tr(
          context,
          '提醒時間需在上午9時至晚上9時前，避免夜間打擾。',
          'Choose a time from 9:00 AM up to 9:00 PM to avoid quiet hours.',
        );
      });
      return;
    }
    setState(() => _time = selected);
    if (_checkInEnabled) await _saveCheckIn();
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.controller.user?.id;
    final supported =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, '提醒及安全支援', 'Reminders and safety')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  tr(context, '主動關心', 'Proactive check-ins'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(tr(
                  context,
                  '所有提醒預設關閉。你可選擇每日或每週一次；靜音時段為晚上9時至早上9時。今天已成功聊天後，下一次關心會順延，避免當日重複。',
                  'Notifications are off by default. Choose a daily or weekly check-in. Quiet hours are 9:00 PM–9:00 AM. After a successful chat today, the next check-in is moved forward so it does not repeat that day.',
                )),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title:
                      Text(tr(context, '開啟定時關心', 'Enable scheduled check-ins')),
                  value: _checkInEnabled,
                  onChanged: _saving || !supported || userId == null
                      ? null
                      : (value) => _saveCheckIn(enabled: value),
                ),
                if (_checkInEnabled) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, '頻率', 'Frequency')),
                    trailing: DropdownButton<bool>(
                      value: _weekly,
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => _weekly = value);
                              _saveCheckIn();
                            },
                      items: [
                        DropdownMenuItem(
                          value: false,
                          child: Text(tr(context, '每日', 'Daily')),
                        ),
                        DropdownMenuItem(
                          value: true,
                          child: Text(tr(context, '每週', 'Weekly')),
                        ),
                      ],
                    ),
                  ),
                  if (_weekly)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, '每週哪一天', 'Day of week')),
                      trailing: DropdownButton<int>(
                        value: _weekday,
                        onChanged: _saving
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() => _weekday = value);
                                _saveCheckIn();
                              },
                        items: List.generate(
                          7,
                          (index) => DropdownMenuItem(
                            value: index + 1,
                            child: Text(_weekdayLabel(context, index + 1)),
                          ),
                        ),
                      ),
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, '關心時間', 'Check-in time')),
                    subtitle: Text(
                      _time.format(context),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    trailing: const Icon(Icons.schedule_rounded),
                    onTap: _saving ? null : _chooseTime,
                  ),
                ],
                const Divider(height: 32),
                Text(
                  tr(context, '任務提醒', 'Task reminders'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                      tr(context, '在到期時提醒我', 'Notify me when a task is due')),
                  subtitle: Text(tr(
                    context,
                    '只安排此裝置上已授權且尚未完成的未來任務。',
                    'Schedules future, incomplete tasks authorized for this account on this device only.',
                  )),
                  value: _taskRemindersEnabled,
                  onChanged: _saving || !supported || userId == null
                      ? null
                      : _saveTaskReminders,
                ),
                if (!supported)
                  Text(tr(
                    context,
                    '排程通知目前只支援 Android 應用程式。',
                    'Scheduled notifications are currently supported in the Android app only.',
                  )),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                if (_saving) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: 20),
                Text(
                  tr(
                    context,
                    '安全支援不會自動通知任何人。對話中如出現危急訊號，你可選擇致電999，或在確認收件人和訊息後，向一位已授權家庭成員發送求助訊息。',
                    'Safety support never contacts anyone automatically. If an urgent-risk statement is detected in chat, you can call 999 or confirm the recipient and message before sending a support request to one authorized family member.',
                  ),
                ),
              ],
            ),
    );
  }

  String _weekdayLabel(BuildContext context, int weekday) {
    const zh = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    const en = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    return Localizations.localeOf(context).languageCode == 'en'
        ? en[weekday - 1]
        : zh[weekday - 1];
  }

  String _notificationError(BuildContext context, Object error) {
    if (error is UnsupportedError) {
      return tr(
        context,
        '此裝置不支援排程通知。',
        'Scheduled notifications are not supported on this device.',
      );
    }
    if (error is StateError &&
        error.message == 'Notification permission was not granted.') {
      return tr(
        context,
        '未獲通知權限；提醒仍保持關閉。你可在裝置設定允許通知後重試。',
        'Notification permission was not granted. Reminders remain off; allow notifications in device settings and try again.',
      );
    }
    return error.toString();
  }
}
