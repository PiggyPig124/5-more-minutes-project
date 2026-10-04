import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'localization.dart';
import 'task_access_refresh.dart';
import 'task_presentation.dart';

/// Displays only a freshly authorized detail response; list summaries are not used.
class TaskDetailsScreen extends StatelessWidget {
  const TaskDetailsScreen(
      {required this.controller, required this.taskId, super.key});

  final AppController controller;
  final String taskId;

  Widget _field(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          SelectableText(value),
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr(context, '完整任務', 'Full task'))),
        body: TaskAccessRefresh(
          controller: controller,
          taskId: taskId,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final task = controller.taskDetails[taskId];
              final loading = controller.loadingTaskDetailIds.contains(taskId);
              final error = controller.taskDetailErrors[taskId];
              return ListView(padding: const EdgeInsets.all(20), children: [
                if (loading) const LinearProgressIndicator(),
                if (task != null) ...[
                  _field(tr(context, '標題', 'Title'), task.title),
                  if (task.isReadOnly) ...[
                    _field(
                        tr(context, '所屬長者', 'Senior'), task.ownerDisplayName!),
                    Text(tr(context, '已授權分享，只供閱讀。',
                        'Shared with permission. Read-only.')),
                    const SizedBox(height: 12),
                  ] else
                    _field(tr(context, '擁有人', 'Owner'),
                        controller.user?.displayName ?? ''),
                  _field(
                      tr(context, '完整內容', 'Full description'),
                      task.description.isEmpty
                          ? tr(context, '無', 'None')
                          : task.description),
                  _field(tr(context, '任務類型', 'Task type'),
                      taskTypeLabel(context, task.taskType)),
                  _field(tr(context, '到期日期與時間', 'Due date and time'),
                      formatTaskHongKongTime(context, task.dueAt)),
                  _field(tr(context, '目前狀態', 'Current status'),
                      taskStatusLabel(context, task.status)),
                ],
                if (task == null && !loading)
                  Text(error ??
                      tr(context, '請重新驗證任務的存取權限。',
                          'Recheck access to view this task.')),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: loading
                      ? null
                      : () => controller.refreshTaskDetail(taskId),
                  child:
                      Text(tr(context, '重新驗證並載入', 'Recheck access and reload')),
                ),
              ]);
            },
          ),
        ),
      );
}
