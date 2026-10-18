import 'package:anxin_companion/src/community_prompt_handoff.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const prompt = CommunityMemoryPrompt(
    memoryId: 'synthetic',
    memoryContent: 'PRIVATE_LOCAL_INTEREST',
    topic: 'unsupported interest',
    promptZh: '想看看公開活動嗎？',
    promptEn: 'Would you like public activities?');
void main() {
  for (final english in [true, false]) {
    testWidgets(
        'explicit handoff at 320px 200 percent ${english ? "en" : "zh"}',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      bool? answer;
      int browses = 0;
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
                      builder: (context, setState) => CommunityPromptHandoff(
                          prompt: prompt,
                          answer: answer,
                          onAnswered: (value) => setState(() => answer = value),
                          onBrowsePublicActivities: () => browses++))))));
      expect(browses, 0);
      await t.tap(find.text(english ? 'Yes, interested' : '有興趣'));
      await t.pumpAndSettle();
      expect(answer, isTrue);
      expect(browses, 0);
      expect(find.textContaining(english ? 'not guaranteed' : '不保證'),
          findsOneWidget);
      await t
          .ensureVisible(find.byKey(const ValueKey('community-prompt-browse')));
      await t.tap(find.byKey(const ValueKey('community-prompt-browse')));
      await t.pumpAndSettle();
      expect(browses, 1);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('Not now has no Browse action or lookup', (t) async {
    bool? answer;
    int browses = 0;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, setState) => CommunityPromptHandoff(
                    prompt: prompt,
                    answer: answer,
                    onAnswered: (value) => setState(() => answer = value),
                    onBrowsePublicActivities: () => browses++)))));
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect(answer, isFalse);
    expect(browses, 0);
    expect(find.byKey(const ValueKey('community-prompt-browse')), findsNothing);
  });
  testWidgets(
      'unavailable opportunity wording does not invent a match or registration',
      (t) async {
    await t.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Text(confirmedSkillHandoffText(context,
                    listedCount: 0, searchState: 'unavailable'))))));
    expect(find.textContaining('no match is confirmed'), findsOneWidget);
    expect(find.textContaining('nothing was registered'), findsOneWidget);
    expect(
        find.textContaining('Matching opportunities are shown'), findsNothing);
  });
}
