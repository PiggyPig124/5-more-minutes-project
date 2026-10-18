import 'package:flutter/material.dart';
import 'localization.dart';
import 'models.dart';

enum MemoryBrowseCategory {
  people,
  places,
  preferences,
  skillsAndExperience,
  routines,
  traditions,
  importantDates,
  lifeStories,
  other
}

/// View labels only. Never infer a person/place/story from free text or rewrite a record.
MemoryBrowseCategory browseCategory(MemoryRecord record) =>
    switch (record.kind.trim().toLowerCase()) {
      'preference' => MemoryBrowseCategory.preferences,
      'experience' => MemoryBrowseCategory.skillsAndExperience,
      _ => MemoryBrowseCategory.other,
    };

List<MemoryRecord> browseMemories(
        Iterable<MemoryRecord> records, MemoryBrowseCategory? category) =>
    List.unmodifiable(category == null
        ? records
        : records.where((record) => browseCategory(record) == category));

String memoryBrowseLabel(BuildContext context, MemoryBrowseCategory category) =>
    switch (category) {
      MemoryBrowseCategory.people => tr(context, '人物', 'People'),
      MemoryBrowseCategory.places => tr(context, '地點', 'Places'),
      MemoryBrowseCategory.preferences => tr(context, '喜好', 'Preferences'),
      MemoryBrowseCategory.skillsAndExperience =>
        tr(context, '技能與經歷', 'Skills and experience'),
      MemoryBrowseCategory.routines => tr(context, '日常習慣', 'Routines'),
      MemoryBrowseCategory.traditions => tr(context, '傳統', 'Traditions'),
      MemoryBrowseCategory.importantDates =>
        tr(context, '重要日子', 'Important dates'),
      MemoryBrowseCategory.lifeStories => tr(context, '人生故事', 'Life stories'),
      MemoryBrowseCategory.other =>
        tr(context, '其他／未分類', 'Other / not classified'),
    };

class MemoryBrowseSelector extends StatelessWidget {
  const MemoryBrowseSelector(
      {required this.records,
      required this.selected,
      required this.onChanged,
      super.key});
  final List<MemoryRecord> records;
  final MemoryBrowseCategory? selected;
  final ValueChanged<MemoryBrowseCategory?> onChanged;
  @override
  Widget build(BuildContext context) => Column(
          key: const ValueKey('memory-browse-category'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, '按類別瀏覽（只改顯示）', 'Browse by category (view only)')),
            DropdownButton<String>(
                key: const ValueKey('memory-browse-select'),
                value: selected?.name ?? 'all',
                isExpanded: true,
                itemHeight: null,
                items: [
                  DropdownMenuItem(
                      value: 'all',
                      child: Text(tr(context, '全部（${records.length}）',
                          'All (${records.length})'))),
                  for (final category in MemoryBrowseCategory.values)
                    DropdownMenuItem(
                        value: category.name,
                        child: Text(
                            '${memoryBrowseLabel(context, category)} (${browseMemories(records, category).length})',
                            softWrap: true))
                ],
                onChanged: (value) => onChanged(value == 'all'
                    ? null
                    : MemoryBrowseCategory.values
                        .firstWhere((item) => item.name == value))),
            Text(tr(context, '只沿用已保存的類型；不會從文字猜測人物、地點或故事。不明確的項目保留在「其他／未分類」。',
                'Uses existing saved types only; people, places and stories are not guessed from the text. Unclear items stay in Other / not classified.')),
          ]);
}
