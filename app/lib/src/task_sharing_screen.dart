import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'localization.dart';
import 'models.dart';
import 'task_presentation.dart';

/// Consent is given for this freshly loaded content and one chosen recipient.
class TaskSharingScreen extends StatefulWidget {
  const TaskSharingScreen({
    required this.controller,
    required this.taskId,
    super.key,
  });

  final AppController controller;
  final String taskId;

  @override
  State<TaskSharingScreen> createState() => _TaskSharingScreenState();
}

class _TaskSharingScreenState extends State<TaskSharingScreen> {
  String? _selectedLinkId;
  bool _loading = true;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _selectedLinkId = null;
      _notice = null;
    });
    final preview = await widget.controller.prepareTaskShare(widget.taskId);
    if (preview != null) {
      await widget.controller.refreshTaskShares(widget.taskId);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _confirm(CareTask preview, FamilyInvitation recipient) async {
    final ok = await widget.controller.confirmTaskShare(preview, recipient);
    if (!mounted) return;
    setState(() {
      _notice = ok
          ? tr(
              context,
              '已分享給 ${widget.controller.familyCounterpartLabel(recipient)}。',
              'Shared with ${widget.controller.familyCounterpartLabel(recipient)}.')
          : null;
      if (ok) _selectedLinkId = null;
    });
  }

  Future<void> _revoke(CareTask preview, TaskShare share) async {
    final ok = await widget.controller.revokeTaskShare(preview, share);
    if (!mounted) return;
    setState(() {
      _notice = ok
          ? tr(
              context,
              '已停止 ${widget.controller.taskShareRecipientLabel(share)} 的後續存取。',
              'Future access stopped for ${widget.controller.taskShareRecipientLabel(share)}.')
          : null;
    });
  }

  Widget _field(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            SelectableText(value),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final preview = controller.taskSharePreviews[widget.taskId];
          final ownedTasks =
              controller.tasks.where((task) => task.id == widget.taskId);
          final ownedTask =
              preview ?? (ownedTasks.isEmpty ? null : ownedTasks.first);
          final recipients = controller.eligibleTaskSharingLinks;
          final matching =
              recipients.where((link) => link.id == _selectedLinkId);
          final selected = matching.isEmpty ? null : matching.first;
          final shares =
              controller.taskSharesByTask[widget.taskId] ?? const <TaskShare>[];
          final busy = _loading ||
              controller.sharingTaskIds.contains(widget.taskId) ||
              shares.any((share) =>
                  controller.revokingTaskShareIds.contains(share.id));
          return Scaffold(
            appBar:
                AppBar(title: Text(tr(context, '分享此任務', 'Share this task'))),
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(tr(context, '家屬只可讀取下列任務內容與目前狀態。私人對話不會分享。',
                    'Your recipient can read the task below and its current status. Private conversations stay private.')),
                const SizedBox(height: 16),
                if (_loading) const LinearProgressIndicator(),
                if (!_loading && preview == null)
                  Text(tr(context, '請重新載入目前內容，再選擇家屬並確認。',
                      'Reload the current content, then choose a recipient and confirm.')),
                if (!_loading && preview != null) ...[
                  _field(tr(context, '標題', 'Title'), preview.title),
                  _field(
                      tr(context, '完整內容', 'Full description'),
                      preview.description.isEmpty
                          ? tr(context, '無', 'None')
                          : preview.description),
                  _field(tr(context, '任務類型', 'Task type'),
                      taskTypeLabel(context, preview.taskType)),
                  _field(tr(context, '到期日期與時間', 'Due date and time'),
                      formatTaskHongKongTime(context, preview.dueAt)),
                  _field(
                      tr(context, '目前狀態', 'Current status'),
                      Localizations.localeOf(context).languageCode == 'en'
                          ? preview.status.apiValue.replaceAll('_', ' ')
                          : preview.status.label),
                  Text(tr(context, '內容或日期改變後，需要重新確認分享。',
                      'Changes to the content or due date require a new sharing confirmation.')),
                  const SizedBox(height: 16),
                  if (recipients.isEmpty)
                    Text(tr(context, '目前沒有已確認且允許任務分享的家屬連結。',
                        'No confirmed family links currently allow task sharing.'))
                  else
                    DropdownButtonFormField<String>(
                      key: ValueKey('${preview.contentHash}-${selected?.id}'),
                      initialValue: selected?.id,
                      isExpanded: true,
                      isDense: false,
                      itemHeight: null,
                      decoration: InputDecoration(
                          labelText:
                              tr(context, '選擇一位家屬', 'Choose one recipient')),
                      hint: Text(tr(context, '請明確選擇', 'Select a recipient')),
                      items: [
                        for (final link in recipients)
                          DropdownMenuItem(
                              value: link.id,
                              child: Text(
                                  controller.familyCounterpartLabel(link))),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                                _selectedLinkId = value;
                                _notice = null;
                              }),
                    ),
                  const SizedBox(height: 16),
                  if (selected != null)
                    _field(tr(context, '指定家屬', 'Selected recipient'),
                        controller.familyCounterpartLabel(selected)),
                  FilledButton(
                    onPressed: busy || selected == null
                        ? null
                        : () => _confirm(preview, selected),
                    child: Text(tr(
                        context, '確認分享以上內容', 'Confirm sharing this content')),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton(
                    onPressed: busy ? null : _load,
                    child: Text(tr(context, '重新載入內容與分享記錄',
                        'Reload content and sharing history'))),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr(context, '取消／返回', 'Cancel / Back'))),
                if (_notice != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_notice!,
                          style: const TextStyle(fontWeight: FontWeight.w700))),
                if (controller.taskSharingError != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(controller.taskSharingError!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                const Divider(height: 32),
                Text(tr(context, '分享記錄', 'Sharing history'),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(tr(context, '停止分享會阻止後續存取，但無法收回家屬已看過或保存的內容。',
                    'Stopping sharing prevents future access. It cannot recall content already viewed or saved.')),
                for (final share in shares)
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(controller.taskShareRecipientLabel(share),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                Text(share.isActive
                                    ? tr(context, '分享中', 'Shared')
                                    : tr(context, '已停止分享', 'Sharing stopped')),
                                Text(
                                    '${tr(context, '確認時間', 'Confirmed')}: ${formatTaskHongKongTime(context, share.consentedAt)}'),
                                if (share.revokedAt != null)
                                  Text(
                                      '${tr(context, '停止時間', 'Stopped')}: ${formatTaskHongKongTime(context, share.revokedAt)}'),
                                if (share.isActive &&
                                    ownedTask != null &&
                                    controller.canShareTask(ownedTask))
                                  OutlinedButton(
                                      onPressed: busy ||
                                              controller.revokingTaskShareIds
                                                  .contains(share.id)
                                          ? null
                                          : () => _revoke(ownedTask, share),
                                      child: Text(tr(
                                          context, '停止此分享', 'Stop sharing'))),
                              ]))),
              ],
            ),
          );
        },
      );
}
