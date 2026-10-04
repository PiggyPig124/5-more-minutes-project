import 'package:flutter/material.dart';
import 'app_controller.dart';
import 'localization.dart';
import 'models.dart';

/// Review the exact owner/version captured before any destructive request.
Future<bool> reviewMemoryDeletion(
    BuildContext context, AppController controller,
    {required String mode, List<String> memoryIds = const []}) async {
  final selected = <MemoryRecord>[
    for (final id in memoryIds)
      ...[...controller.memories, ...controller.memorySearchResults]
          .where((m) => m.id == id)
          .take(1),
  ];
  final preview =
      await controller.prepareMemoryDeletion(mode: mode, memoryIds: memoryIds);
  if (preview == null) return false;
  if (!context.mounted) {
    controller.cancelMemoryDeletion(preview);
    return false;
  }
  final count = mode == 'all'
      ? preview.counts['total'] ?? preview.counts['memories'] ?? 0
      : memoryIds.length;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      insetPadding: const EdgeInsets.all(12),
      scrollable: true,
      title: Text(mode == 'all'
          ? tr(context, '刪除全部 $count 項記憶？', 'Delete all $count memories?')
          : tr(
              context, '刪除所選 $count 項記憶？', 'Delete $count selected memories?')),
      content: SizedBox(
          width: double.maxFinite,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mode == 'all')
                Text(tr(context, '包括已暫停、候選及歷史記錄。',
                    'Includes paused, candidate and historical records.')),
              for (final memory in selected)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(memory.content),
                ),
              Text(tr(
                  context,
                  '此操作無法復原。會刪除相關記憶及搜尋索引、技能和整張衍生故事卡，撤回相關家庭分享文字，並遮蓋對話中的來源文字及記憶引用。',
                  'This cannot be undone. Related memories, search embeddings, skills and entire derived story cards will be deleted. Family copies shared from those stories will be withdrawn, and source text and memory references in chats will be redacted.')),
              const SizedBox(height: 12),
              Text(tr(context, '獨立任務、獨立故事及無關家庭訊息會保留。已另存到裝置或外部備份的副本不在此次刪除範圍內。',
                  'Independent tasks, standalone stories and unrelated family messages remain. Separately saved device copies and external backups are outside this deletion.')),
              const SizedBox(height: 16),
              OutlinedButton(
                key: const ValueKey('cancel-memory-deletion'),
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr(context, '取消', 'Cancel'),
                    textAlign: TextAlign.center),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('confirm-memory-deletion'),
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error),
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, '確認刪除', 'Confirm deletion'),
                    textAlign: TextAlign.center),
              ),
            ],
          )),
    ),
  );
  if (accepted != true || !context.mounted) {
    controller.cancelMemoryDeletion(preview);
    return false;
  }
  return controller.confirmMemoryDeletion(preview);
}

class MemoryControlsPanel extends StatelessWidget {
  const MemoryControlsPanel(
      {super.key,
      required this.controller,
      required this.selectedIds,
      required this.onView,
      required this.onDeleted});
  final AppController controller;
  final List<String> selectedIds;
  final VoidCallback onView;
  final VoidCallback onDeleted;
  @override
  Widget build(BuildContext context) {
    final enabled = controller.memoryConsentEnabled;
    final total = controller.memoryControlState?.counts['total'];
    final pending = controller.pendingMemoryDeletion != null;
    final canChange = controller.supportsMemoryControls &&
        !controller.loading &&
        !controller.memoryDeletionBusy &&
        !pending;
    Future<void> remove(String mode) async {
      final deleted = await reviewMemoryDeletion(context, controller,
          mode: mode, memoryIds: mode == 'all' ? const [] : selectedIds);
      if (deleted) onDeleted();
    }

    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                    enabled
                        ? tr(context, '記憶已開啟', 'Memory is on')
                        : tr(context, '記憶已關閉', 'Memory is off'),
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(tr(context, '關閉會停止新記憶收集、檢索及個人化，不會刪除已儲存記憶。',
                    'Turning off stops new memory collection, retrieval and personalization. Saved memories remain.')),
                const SizedBox(height: 12),
                OutlinedButton(
                    key: const ValueKey('toggle-memory'),
                    onPressed: canChange && controller.memoryRevision != null
                        ? () => controller.setMemoryConsent(!enabled)
                        : null,
                    child: Text(
                        enabled
                            ? tr(context, '關閉記憶', 'Turn memory off')
                            : tr(context, '開啟記憶', 'Turn memory on'),
                        textAlign: TextAlign.center)),
                const SizedBox(height: 8),
                OutlinedButton(
                    key: const ValueKey('view-saved-memories'),
                    onPressed: pending ? null : onView,
                    child: Text(tr(context, '查看已儲存記憶', 'View saved memories'),
                        textAlign: TextAlign.center)),
                const SizedBox(height: 12),
                OutlinedButton(
                    key: const ValueKey('delete-selected-memories'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error),
                    onPressed: canChange && selectedIds.isNotEmpty
                        ? () => remove('selected')
                        : null,
                    child: Text(
                        tr(context, '刪除所選（${selectedIds.length}）',
                            'Delete selected (${selectedIds.length})'),
                        textAlign: TextAlign.center)),
                const SizedBox(height: 8),
                OutlinedButton(
                    key: const ValueKey('delete-all-memories'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error),
                    onPressed: canChange ? () => remove('all') : null,
                    child: Text(
                        tr(context, '刪除全部記憶${total == null ? '' : '（$total）'}',
                            'Delete all memories${total == null ? '' : ' ($total)'}'),
                        textAlign: TextAlign.center)),
                if (!controller.supportsMemoryControls) ...[
                  const SizedBox(height: 8),
                  Text(tr(context, '此連線尚未支援記憶管理。仍可查看已儲存記憶。',
                      'Memory controls are unavailable on this connection. You can still view saved memories.')),
                ],
                if (pending) ...[
                  const SizedBox(height: 12),
                  Text(tr(context, '刪除結果尚未確認。相關內容暫時隱藏；重試會查核同一次刪除。',
                      'Deletion is not yet confirmed. Related content is hidden. Retry checks the same deletion request.')),
                  OutlinedButton(
                      key: const ValueKey('retry-memory-deletion'),
                      onPressed: controller.memoryDeletionBusy
                          ? null
                          : () async {
                              if (await controller.retryMemoryDeletion()) {
                                onDeleted();
                              }
                            },
                      child: Text(
                          tr(context, '重試確認刪除', 'Retry deletion confirmation'),
                          textAlign: TextAlign.center)),
                ],
                if (controller.memoryDeletionReceipt != null && !pending) ...[
                  const SizedBox(height: 8),
                  Text(tr(context, '已確認刪除。', 'Deletion confirmed.')),
                ],
              ],
            )));
  }
}
