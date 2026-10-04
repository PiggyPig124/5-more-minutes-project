import 'package:anxin_companion/src/localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'catalog_metadata_test.dart' show item, showCard;

void main() {
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    final en = locale == englishLocale;
    testWidgets('general copy does not imply exclusion ${locale.languageCode}',
        (t) async {
      await showCard(t, item({'recommendation_basis': 'general'}),
          locale: locale);
      expect(
          find.text(en
              ? 'Not personalized. These suggestions may include activities you dislike.'
              : '非個人化建議，仍可能包含你不喜歡的活動。'),
          findsOneWidget);
    });
    testWidgets('skill relevance is not interest ${locale.languageCode}',
        (t) async {
      await showCard(
          t,
          item({
            'recommendation_basis': 'memory',
            'recommendation_reasons': [
              {
                'memory_id': 's',
                'source_type': 'skill',
                'source_text': 'Gardening',
                'matched_tag': 'gardening'
              }
            ]
          }),
          locale: locale);
      expect(
          find.text(en
              ? 'Skill-related match; this does not imply liking or willingness to participate.'
              : '僅表示技能相關，不代表喜歡或願意參加。'),
          findsOneWidget);
    });
  }
}
