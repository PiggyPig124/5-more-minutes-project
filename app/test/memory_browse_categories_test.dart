import 'package:anxin_companion/src/memory_browse_categories.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nine labels, conservative kinds and unchanged record references', () {
    const preference = MemoryRecord(
        id: 'p',
        content: 'A synthetic preference',
        kind: 'preference',
        status: 'candidate',
        revision: 4);
    const experience = MemoryRecord(
        id: 'e',
        content: 'A life experience, not a confirmed skill',
        kind: 'experience',
        status: 'confirmed',
        suppressed: true,
        revision: 5);
    const fact = MemoryRecord(
        id: 'f',
        content: 'My mother lives at a place',
        kind: 'fact',
        status: 'confirmed');
    const emotion =
        MemoryRecord(id: 'm', content: 'A feeling', kind: 'emotion');
    expect(MemoryBrowseCategory.values.length, 9);
    expect(browseCategory(preference), MemoryBrowseCategory.preferences);
    expect(
        browseCategory(experience), MemoryBrowseCategory.skillsAndExperience);
    expect(browseCategory(fact), MemoryBrowseCategory.other);
    expect(browseCategory(emotion), MemoryBrowseCategory.other);
    final records = [preference, experience, fact, emotion];
    expect(browseMemories(records, MemoryBrowseCategory.people), isEmpty);
    expect(
        identical(
            browseMemories(records, MemoryBrowseCategory.preferences).single,
            preference),
        isTrue);
    expect(browseMemories(records, null), records);
    expect(experience.suppressed, isTrue);
    expect(preference.status, 'candidate');
    expect(() => browseMemories(records, null).clear(), throwsUnsupportedError);
  });
  for (final english in [true, false]) {
    testWidgets(
        'nine-category selector wraps at 320px 200 percent ${english ? "en" : "zh"}',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      MemoryBrowseCategory? selected;
      await t.pumpWidget(MaterialApp(
          locale: english ? englishLocale : traditionalChineseLocale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: StatefulBuilder(
                      builder: (context, setState) => MemoryBrowseSelector(
                          records: const [],
                          selected: selected,
                          onChanged: (value) =>
                              setState(() => selected = value)))))));
      await t.tap(find.byKey(const ValueKey('memory-browse-select')));
      await t.pumpAndSettle();
      final people = find.text(english ? 'People (0)' : '人物 (0)').last;
      await t.ensureVisible(people);
      await t.tap(people);
      await t.pumpAndSettle();
      expect(selected, MemoryBrowseCategory.people);
      expect(t.takeException(), isNull);
    });
  }
}
