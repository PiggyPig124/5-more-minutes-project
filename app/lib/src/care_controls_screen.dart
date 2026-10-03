import 'dart:math';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'app_controller.dart';
import 'care_models.dart';
import 'localization.dart';
import 'models.dart';
import 'reminder_settings_screen.dart';

class CareControlsScreen extends StatefulWidget {
  const CareControlsScreen({
    required this.controller,
    this.initialTab = 0,
    super.key,
  });

  final AppController controller;
  final int initialTab;

  @override
  State<CareControlsScreen> createState() => _CareControlsScreenState();
}

class _CareControlsScreenState extends State<CareControlsScreen> {
  CareFeaturesApi? get _api => widget.controller.api is CareFeaturesApi
      ? widget.controller.api as CareFeaturesApi
      : null;
  late final String? _userId;
  late final String? _token;
  late final bool _elder;
  late int _tab;
  bool _loading = false;
  bool _busy = false;
  bool _dirty = false;
  String? _error;
  String? _notice;
  final _loaded = <int>{};
  CheckInSchedule _schedule = const CheckInSchedule();
  List<CareNotification> _notifications = [];
  List<EmergencyContact> _contacts = [];
  List<FamilyInvitation> _links = [];
  List<SafetyEvent> _events = [];

  bool get _active =>
      mounted &&
      _userId != null &&
      widget.controller.user?.id == _userId &&
      widget.controller.session?.accessToken == _token;

  @override
  void initState() {
    super.initState();
    _userId = widget.controller.user?.id;
    _token = widget.controller.session?.accessToken;
    _elder = widget.controller.isElder;
    _tab = widget.initialTab.clamp(0, _elder ? 2 : 1);
    Future<void>.microtask(_load);
  }

  String _failure(Object error) {
    if (error is ApiException) {
      if (error.statusCode == 404 || error.statusCode == 501) {
        return tr(context, '這個服務版本尚未支援此功能。你仍可使用本機提醒。',
            'This service version does not support this feature yet. Local reminders remain available.');
      }
      if (error.statusCode == 401 || error.statusCode == 403) {
        return tr(context, '請重新登入，或檢查你的帳戶及家庭授權。',
            'Please sign in again or check your account and family permissions.');
      }
    }
    return tr(context, '未能完成要求。請檢查連線後重試；相同的求助訊息會沿用重試編號。',
        'The request could not be completed. Check your connection and retry; identical support requests reuse their retry ID.');
  }

  Future<void> _load() async {
    if (!_active || _api == null || _loading || _busy) return;
    final tab = _tab;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (tab == 0) {
        final items = await _api!.listNotifications();
        if (!mounted || !_active) return;
        _notifications = items;
      } else if (tab == 1) {
        final schedule = await _api!.getCheckInSchedule();
        if (!mounted || !_active) return;
        _schedule = (schedule ?? const CheckInSchedule()).copyWith(
          enabled: _elder && (schedule?.enabled ?? false),
        );
        _dirty = false;
      } else if (_elder) {
        final values = await Future.wait<Object>([
          _api!.listEmergencyContacts(),
          widget.controller.api.listLinks(),
          _api!.listSafetyEvents(),
        ]);
        if (!mounted || !_active) return;
        _contacts = values[0] as List<EmergencyContact>;
        _links = (values[1] as List<FamilyInvitation>)
            .where((link) =>
                link.status == InvitationStatus.accepted &&
                link.allowsFamilyMessages)
            .toList();
        _events = values[2] as List<SafetyEvent>;
      }
      _loaded.add(tab);
    } on Object catch (error) {
      if (_active) _error = _failure(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (!_active || _api == null || _busy || _loading) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await operation();
    } on Object catch (error) {
      if (_active) _error = _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _change(CheckInSchedule schedule) => setState(() {
        _schedule = schedule;
        _dirty = true;
        _notice = null;
      });

  Future<void> _save() => _run(() async {
        final saved = await _api!.saveCheckInSchedule(
          _schedule.copyWith(enabled: _elder && _schedule.enabled),
        );
        if (!mounted || !_active) return;
        _schedule = saved;
        _dirty = false;
        _notice = tr(context, '雲端設定已儲存。本機提醒沒有改動。',
            'Cloud settings saved. Local reminders have not changed.');
      });

  Future<void> _chooseTime(String current, void Function(String) update) async {
    final parts = current.split(':');
    final time = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (!_active || time == null) return;
    update(
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}');
  }

  Future<void> _pauseUntil() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: DateTime(now.year + 2, now.month, now.day),
    );
    if (!mounted || !_active || date == null) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(now));
    if (!_active || time == null) return;
    final until =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!until.isAfter(DateTime.now())) {
      setState(() => _error = tr(context, '請選擇未來時間。', 'Choose a future time.'));
      return;
    }
    _change(_schedule.copyWith(pausedUntil: until));
  }

  Future<void> _skipToday() => _run(() async {
        await _api!.skipCheckInToday();
        if (!mounted || !_active) return;
        _notice = tr(
            context, '今天的雲端問候已略過。', 'Today’s cloud check-in has been skipped.');
        // Read the server date rather than guessing the scheduler's timezone.
        final schedule = await _api!.getCheckInSchedule();
        if (_active && schedule != null) _schedule = schedule;
      });

  Future<void> _trigger() => _run(() async {
        final result = await _api!.triggerCheckIn();
        if (!mounted || !_active) return;
        _notice = result.triggered
            ? tr(context, '已建立到期的雲端問候。請查看收件匣或聊天。',
                'A due cloud check-in was created. Check your inbox or chats.')
            : tr(context, '目前沒有到期的問候，沒有強制發送。',
                'No check-in is due. Nothing was forced or sent.');
        if (result.assistantText.isNotEmpty) {
          _notice = '$_notice\n${result.assistantText}';
        }
        _loaded.remove(0);
        if (result.triggered) await widget.controller.refreshHome(silent: true);
      });

  Future<void> _mark(CareNotification item, CareNotificationAction status) =>
      _run(() async {
        final updated = await _api!
            .updateNotification(notificationId: item.id, status: status);
        if (!mounted || !_active) return;
        _notifications = [
          for (final entry in _notifications)
            if (entry.id == item.id) updated else entry
        ];
      });

  Future<void> _addContact() async {
    final choice = await showDialog<_ContactChoice>(
      context: context,
      builder: (_) => _ContactDialog(links: _links),
    );
    if (!_active || choice == null) return;
    await _run(() async {
      final contact = await _api!.addEmergencyContact(
          familyLinkId: choice.linkId, label: choice.label);
      if (!mounted || !_active) return;
      _contacts = [
        ..._contacts.where((item) => item.id != contact.id),
        contact
      ];
      _notice = tr(context, '已指定聯絡人。不會自動發送訊息。',
          'Contact designated. No message is sent automatically.');
    });
  }

  Future<void> _removeContact(EmergencyContact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, '移除指定聯絡人？', 'Remove designated contact?')),
        content: Text('${contact.label} · ${contact.caregiverName}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, '取消', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, '移除', 'Remove'))),
        ],
      ),
    );
    if (!_active || confirmed != true) return;
    await _run(() async {
      await _api!.deleteEmergencyContact(contact.id);
      if (!mounted || !_active) return;
      _contacts = _contacts.where((item) => item.id != contact.id).toList();
    });
  }

  Future<void> _support({String? eventId}) async {
    final enabled = _contacts.where((contact) => contact.isEnabled).toList();
    if (!_active || enabled.isEmpty) return;
    final preview = await showDialog<_SupportPreview>(
      context: context,
      builder: (_) => _SupportDialog(contacts: enabled),
    );
    if (!_active || preview == null) return;
    await _run(() async {
      final store = widget.controller.sessionStore;
      final recipient = 'safety:${preview.contact.id}';
      var retryId = await store.readFamilyMessageClientId(
        recipientId: recipient,
        content: preview.message,
        userId: _userId,
      );
      if (!mounted || !_active) return;
      retryId ??=
          'support-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
      await store.saveFamilyMessageClientId(
        recipientId: recipient,
        content: preview.message,
        userId: _userId,
        clientId: retryId,
      );
      if (!mounted || !_active) return;
      await _api!.sendSupportRequest(
        emergencyContactId: preview.contact.id,
        message: preview.message,
        idempotencyKey: retryId,
        safetyEventId: eventId,
      );
      if (!mounted || !_active) return;
      // Retain the ID even after success so reopening and retrying cannot duplicate delivery.
      _notice = tr(context, '訊息已送達所選聯絡人的應用程式內收件匣。這不是緊急派遣，也不代表對方已閱讀。',
          'Delivered IN APP to the chosen contact. This is not emergency dispatch and does not mean they have read it.');
      _events = [
        for (final event in _events)
          if (event.id == eventId)
            SafetyEvent(
                id: event.id,
                triggerMessageId: event.triggerMessageId,
                createdAt: event.createdAt,
                resolvedAt: event.resolvedAt,
                supportRequestSent: true)
          else
            event,
      ];
    });
  }

  String _date(DateTime? value) {
    if (value == null) return tr(context, '沒有日期', 'No date');
    final local = value.toLocal();
    final day = MaterialLocalizations.of(context).formatMediumDate(local);
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: true);
    return '$day $time';
  }

  Widget _card(String title, List<Widget> children) => Card(
        color: Colors.white,
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _localInfo() =>
      _card(tr(context, '雲端與本機提醒', 'Cloud inbox vs local reminders'), [
        Text(tr(
            context,
            '雲端排程由伺服器處理，訊息只會顯示在應用程式內收件匣；沒有推送通知。重新整理以查看新訊息。本機 Android 通知則由此裝置另行安排，兩者設定互不影響。',
            'The server runs cloud schedules; messages appear only in the in-app inbox. There are no push notifications. Refresh to see new messages. Local Android notifications are scheduled separately on this device; these settings do not change them.')),
        if (widget.controller.reminderScheduler != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ReminderSettingsScreen(
                  controller: widget.controller,
                  scheduler: widget.controller.reminderScheduler!),
            )),
            icon: const Icon(Icons.notifications_active_outlined),
            label:
                Text(tr(context, '本機 Android 提醒', 'Local Android reminders')),
          ),
        ],
      ]);

  Widget _inbox() => _card(tr(context, '雲端收件匣', 'Cloud inbox'), [
        if (_notifications.isEmpty)
          Text(tr(context, '目前沒有通知。', 'No notifications yet.')),
        for (final item in _notifications) ...[
          Text(_kind(item.kind),
              style: Theme.of(context).textTheme.titleMedium),
          Text(item.body),
          const SizedBox(height: 6),
          Text('${_status(item.status)} · ${_date(item.createdAt)}'),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (item.status != 'acknowledged' && item.status != 'handled')
              TextButton(
                  onPressed: _busy
                      ? null
                      : () => _mark(item, CareNotificationAction.acknowledged),
                  child: Text(tr(context, '標為已讀', 'Acknowledge'))),
            if (item.status != 'handled')
              TextButton(
                  onPressed: _busy
                      ? null
                      : () => _mark(item, CareNotificationAction.handled),
                  child: Text(tr(context, '標為已處理', 'Mark handled'))),
          ]),
          const Divider(height: 28),
        ],
      ]);

  String _kind(String value) => switch (value) {
        'check_in' => tr(context, '關懷問候', 'Check-in'),
        'task_due' => tr(context, '任務到期', 'Task due'),
        'family_reply' => tr(context, '家人回覆', 'Family reply'),
        _ => value,
      };

  String _status(String value) => switch (value) {
        'pending' => tr(context, '待發送', 'Pending'),
        'sent' => tr(context, '已發送', 'Sent'),
        'acknowledged' => tr(context, '已讀', 'Acknowledged'),
        'handled' => tr(context, '已處理', 'Handled'),
        'failed' => tr(context, '發送失敗', 'Failed'),
        _ => value,
      };

  Widget _timeButton(
          String label, String value, void Function(String) update) =>
      OutlinedButton.icon(
        onPressed: _busy ? null : () => _chooseTime(value, update),
        icon: const Icon(Icons.schedule),
        label: Text('$label · $value'),
      );

  Widget _scheduleForm() =>
      _card(tr(context, '雲端關懷設定', 'Cloud care settings'), [
        if (_elder) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, '開啟關懷問候', 'Enable check-in greetings')),
            value: _schedule.enabled,
            onChanged: _busy
                ? null
                : (value) => _change(_schedule.copyWith(enabled: value)),
          ),
          DropdownButtonFormField<CheckInFrequency>(
            initialValue: _schedule.frequency,
            decoration:
                InputDecoration(labelText: tr(context, '頻率', 'Frequency')),
            items: [
              DropdownMenuItem(
                  value: CheckInFrequency.daily,
                  child: Text(tr(context, '每天', 'Daily'))),
              DropdownMenuItem(
                  value: CheckInFrequency.weekly,
                  child: Text(tr(context, '每週', 'Weekly'))),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      _change(_schedule.copyWith(frequency: value));
                    }
                  },
          ),
          if (_schedule.frequency == CheckInFrequency.weekly) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _schedule.weekday,
              decoration:
                  InputDecoration(labelText: tr(context, '星期幾', 'Day of week')),
              items: [
                for (var day = 1; day <= 7; day++)
                  DropdownMenuItem(value: day, child: Text(_weekday(day)))
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) {
                        _change(_schedule.copyWith(weekday: value));
                      }
                    },
            ),
          ],
          const SizedBox(height: 12),
          _timeButton(
              tr(context, '問候時間', 'Check-in time'),
              _schedule.checkInTime,
              (value) => _change(_schedule.copyWith(checkInTime: value))),
        ] else
          Text(tr(context, '關懷問候只適用於長者。照顧者仍可設定自己的任務及家人回覆通知。',
              'Check-in greetings are for seniors only. Caregivers can still set their own task and family-reply preferences.')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr(context, '任務到期通知', 'Task reminders')),
          value: _schedule.taskReminders,
          onChanged: _busy
              ? null
              : (value) => _change(_schedule.copyWith(taskReminders: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr(context, '家人回覆通知', 'Family replies')),
          value: _schedule.familyReplies,
          onChanged: _busy
              ? null
              : (value) => _change(_schedule.copyWith(familyReplies: value)),
        ),
        const SizedBox(height: 8),
        _timeButton(
            tr(context, '安靜時段開始', 'Quiet hours start'),
            _schedule.quietStart,
            (value) => _change(_schedule.copyWith(quietStart: value))),
        const SizedBox(height: 8),
        _timeButton(
            tr(context, '安靜時段結束', 'Quiet hours end'),
            _schedule.quietEnd,
            (value) => _change(_schedule.copyWith(quietEnd: value))),
        const SizedBox(height: 12),
        Text(tr(context, '時間由伺服器排程解讀，不是本機 Android 通知時間。',
            'Times are interpreted by the server scheduler, not the local Android notification scheduler.')),
        if (_schedule.pausedUntil != null)
          Text(
              '${tr(context, '暫停至：', 'Paused until: ')}${_date(_schedule.pausedUntil)}'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          TextButton(
              onPressed: _busy ? null : _pauseUntil,
              child: Text(tr(context, '暫停至…', 'Pause until…'))),
          if (_schedule.pausedUntil != null)
            TextButton(
                onPressed: _busy
                    ? null
                    : () => _change(_schedule.copyWith(clearPause: true)),
                child: Text(tr(context, '恢復排程', 'Resume schedule'))),
        ]),
        if (_schedule.skipDate != null)
          Text(
              '${tr(context, '略過日期：', 'Skipped date: ')}${_schedule.skipDate}'),
        if (_dirty) Text(tr(context, '有尚未儲存的修改。', 'You have unsaved changes.')),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('save-care-schedule'),
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(tr(context, '儲存雲端設定', 'Save cloud settings')),
        ),
        if (_elder) ...[
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: _busy || _dirty ? null : _skipToday,
              child: Text(tr(context, '略過今天的問候', 'Skip today’s check-in'))),
          const SizedBox(height: 8),
          OutlinedButton(
              onPressed: _busy || _dirty ? null : _trigger,
              child: Text(tr(context, '檢查到期問候', 'Check for a due greeting'))),
          const SizedBox(height: 6),
          Text(tr(context, '只在到期時建立問候；不會繞過暫停、略過或安靜時段。請先儲存修改。',
              'Creates a greeting only when due; it does not bypass pause, skip or quiet hours. Save changes first.')),
        ],
      ]);

  String _weekday(int day) => tr(
      context,
      ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][day - 1],
      [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday'
      ][day - 1]);

  Widget _supportPanel() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _card(tr(context, '指定支援聯絡人', 'Designated support contacts'), [
          Text(tr(
              context,
              '你選擇一位聯絡人、修改訊息並確認後，才會發送應用程式內訊息。不會自動聯絡家人，也沒有緊急派遣。如有即時危險，請致電999或前往急症室。',
              'Choose one contact, edit your message, then confirm to send an in-app message. Family is never contacted automatically; this is not emergency dispatch. For immediate danger, call 999 or go to an emergency department.')),
          const SizedBox(height: 12),
          if (_contacts.isEmpty)
            Text(tr(context, '尚未指定聯絡人。請先在家庭頁面建立並授權家庭訊息連結。',
                'No designated contacts yet. First create a family link with family-message permission in Family.')),
          for (final contact in _contacts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${contact.label} · ${contact.caregiverName}'),
              subtitle: Text(contact.isEnabled
                  ? tr(context, '可選擇傳送', 'Available to choose')
                  : tr(context, '已停用', 'Disabled')),
              trailing: IconButton(
                  tooltip: tr(context, '移除聯絡人', 'Remove contact'),
                  onPressed: _busy ? null : () => _removeContact(contact),
                  icon: const Icon(Icons.person_remove_outlined)),
            ),
          OutlinedButton.icon(
              onPressed: _busy || _links.isEmpty ? null : _addContact,
              icon: const Icon(Icons.person_add_alt),
              label: Text(
                  tr(context, '指定已連結家人', 'Designate a linked family member'))),
          const SizedBox(height: 10),
          FilledButton.icon(
              key: const Key('preview-designated-support'),
              onPressed: _busy || !_contacts.any((contact) => contact.isEnabled)
                  ? null
                  : () => _support(),
              icon: const Icon(Icons.preview_outlined),
              label: Text(tr(context, '預覽求助訊息', 'Preview support request'))),
        ]),
        _card(tr(context, '我的安全紀錄', 'My safety events'), [
          Text(tr(context, '只顯示訊息編號及狀態，不會顯示或分享原始聊天文字。',
              'Only message references and status are shown, not raw chat text.')),
          if (_events.isEmpty)
            Text(tr(context, '目前沒有安全紀錄。', 'No safety events yet.')),
          for (final event in _events) ...[
            const Divider(height: 24),
            Text(_date(event.createdAt)),
            if (event.triggerMessageId != null)
              Text(
                  '${tr(context, '觸發訊息編號：', 'Trigger message ID: ')}${event.triggerMessageId}'),
            Text(event.resolvedAt == null
                ? tr(context, '未解決', 'Unresolved')
                : '${tr(context, '已解決：', 'Resolved: ')}${_date(event.resolvedAt)}'),
            Text(event.supportRequestSent
                ? tr(context, '已發送應用程式內求助訊息', 'In-app support request sent')
                : tr(context, '尚未發送求助訊息', 'No support request sent')),
            if (!event.supportRequestSent && event.resolvedAt == null)
              TextButton(
                  onPressed:
                      _busy || !_contacts.any((contact) => contact.isEnabled)
                          ? null
                          : () => _support(eventId: event.id),
                  child: Text(tr(context, '為此紀錄預覽求助訊息',
                      'Preview support for this event'))),
          ],
        ]),
      ]);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => PopScope(
          canPop: !_busy,
          child: Scaffold(
            backgroundColor: const Color(0xFFFFF8EF),
            appBar: AppBar(
              title: Text(tr(context, '收件匣及關懷設定', 'Inbox and care settings')),
              actions: [
                IconButton(
                    tooltip: tr(context, '重新整理', 'Refresh'),
                    onPressed:
                        _loading || _busy || _dirty || !_active || _api == null
                            ? null
                            : _load,
                    icon: const Icon(Icons.refresh))
              ],
            ),
            body: SafeArea(
                child: !_active
                    ? Center(
                        child: Text(tr(context, '請先登入。', 'Please sign in.')))
                    : ListView(padding: const EdgeInsets.all(20), children: [
                        _localInfo(),
                        if (_api == null)
                          _card(tr(context, '功能尚未提供', 'Feature unavailable'), [
                            Text(tr(context, '目前的連線尚未支援雲端關懷功能。聊天及本機提醒仍可使用。',
                                'This connection does not support cloud care features. Chat and local reminders still work.'))
                          ])
                        else ...[
                          if (_loading || _busy)
                            const LinearProgressIndicator(),
                          if (_error != null)
                            _card(tr(context, '未能完成', 'Could not complete'), [
                              Text(_error!),
                              if (!_loading &&
                                  !_busy &&
                                  !_loaded.contains(_tab))
                                TextButton(
                                    onPressed: _load,
                                    child: Text(tr(context, '重試', 'Retry'))),
                            ]),
                          if (_notice != null)
                            Semantics(
                                liveRegion: true,
                                child: _card(tr(context, '最新狀態', 'Update'),
                                    [Text(_notice!)])),
                          if (!_loading && _loaded.contains(_tab))
                            switch (_tab) {
                              0 => _inbox(),
                              1 => _scheduleForm(),
                              _ => _supportPanel()
                            },
                        ],
                      ])),
            bottomNavigationBar: _api == null || !_active
                ? null
                : NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: _busy || _loading
                        ? null
                        : (index) {
                            setState(() {
                              _tab = index;
                              _error = null;
                              _notice = null;
                            });
                            if (!_loaded.contains(index)) _load();
                          },
                    destinations: [
                      NavigationDestination(
                          icon: const Icon(Icons.inbox_outlined),
                          label: tr(context, '收件匣', 'Inbox')),
                      NavigationDestination(
                          icon: const Icon(Icons.tune),
                          label: tr(context, '排程', 'Schedule')),
                      if (_elder)
                        NavigationDestination(
                            icon: const Icon(Icons.support_outlined),
                            label: tr(context, '指定支援', 'Support')),
                    ],
                  ),
          ),
        ),
      );
}

class _ContactChoice {
  const _ContactChoice(this.linkId, this.label);
  final String linkId;
  final String label;
}

class _ContactDialog extends StatefulWidget {
  const _ContactDialog({required this.links});
  final List<FamilyInvitation> links;
  @override
  State<_ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends State<_ContactDialog> {
  String? _linkId;
  final _label = TextEditingController();
  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(tr(context, '指定一位家人', 'Designate one family member')),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            isExpanded: true,
            decoration: InputDecoration(
                labelText: tr(context, '已授權連結', 'Authorized family link')),
            items: [
              for (final link in widget.links)
                DropdownMenuItem(
                    value: link.id,
                    child: Text(link.caregiverName ?? link.name ?? link.email))
            ],
            onChanged: (value) => setState(() => _linkId = value),
          ),
          const SizedBox(height: 12),
          TextField(
              controller: _label,
              maxLength: 100,
              decoration: InputDecoration(
                  labelText: tr(context, '聯絡人標籤', 'Contact label')),
              onChanged: (_) => setState(() {})),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, '取消', 'Cancel'))),
          FilledButton(
              onPressed: _linkId == null || _label.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                      context, _ContactChoice(_linkId!, _label.text.trim())),
              child: Text(tr(context, '指定聯絡人', 'Designate contact'))),
        ],
      );
}

class _SupportPreview {
  const _SupportPreview(this.contact, this.message);
  final EmergencyContact contact;
  final String message;
}

class _SupportDialog extends StatefulWidget {
  const _SupportDialog({required this.contacts});
  final List<EmergencyContact> contacts;
  @override
  State<_SupportDialog> createState() => _SupportDialogState();
}

class _SupportDialogState extends State<_SupportDialog> {
  EmergencyContact? _contact;
  final _message = TextEditingController();
  bool _initialized = false;
  bool _review = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _message.text = tr(context, '我現在可能需要一些支援。方便時請聯絡我。',
        'I may need some support. Please contact me when you can.');
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_review
            ? tr(context, '確認一位收件人及訊息', 'Confirm one recipient and message')
            : tr(context, '選擇及編輯', 'Choose and edit')),
        content: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              if (_review) ...[
                Text(
                    '${tr(context, '唯一收件人：', 'Only recipient: ')}${_contact!.label} · ${_contact!.caregiverName}',
                    key: const Key('support-recipient-preview')),
                const SizedBox(height: 12),
                Text(_message.text.trim(),
                    key: const Key('support-message-preview')),
              ] else ...[
                DropdownButtonFormField<String>(
                  key: const Key('support-contact-picker'),
                  initialValue: _contact?.id,
                  isExpanded: true,
                  decoration: InputDecoration(
                      labelText: tr(context, '選擇一位指定聯絡人',
                          'Choose one designated contact')),
                  items: [
                    for (final contact in widget.contacts)
                      DropdownMenuItem(
                          value: contact.id,
                          child: Text(
                              '${contact.label} · ${contact.caregiverName}'))
                  ],
                  onChanged: (id) => setState(() => _contact = widget.contacts
                      .firstWhere((contact) => contact.id == id)),
                ),
                const SizedBox(height: 12),
                TextField(
                    key: const Key('support-message-editor'),
                    controller: _message,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 2000,
                    decoration: InputDecoration(
                        labelText: tr(context, '可修改的訊息', 'Editable message')),
                    onChanged: (_) => setState(() {})),
              ],
              const SizedBox(height: 12),
              Text(tr(
                  context,
                  '只會向你確認的一位聯絡人傳送此訊息，不會分享聊天記錄。送達應用程式內不等於已讀或緊急派遣。如有即時危險，請致電999。',
                  'Only this message goes to the one contact you confirm; chat history is not shared. In-app delivery is not a read receipt or emergency dispatch. Call 999 for immediate danger.')),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, '取消', 'Cancel'))),
          if (_review)
            TextButton(
                onPressed: () => setState(() => _review = false),
                child: Text(tr(context, '修改', 'Edit'))),
          FilledButton(
            key: Key(_review
                ? 'confirm-designated-support'
                : 'review-designated-support'),
            onPressed: _contact == null || _message.text.trim().isEmpty
                ? null
                : () {
                    if (_review) {
                      Navigator.pop(context,
                          _SupportPreview(_contact!, _message.text.trim()));
                    } else {
                      setState(() => _review = true);
                    }
                  },
            child: Text(_review
                ? tr(context, '確認並傳送', 'Confirm and send')
                : tr(context, '預覽', 'Review')),
          ),
        ],
      );
}
