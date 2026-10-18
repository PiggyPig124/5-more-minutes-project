import 'package:flutter/material.dart';
import 'localization.dart';
import 'models.dart';

/// Choosing Yes is local. Only the separate zero-payload Browse callback routes.
class CommunityPromptHandoff extends StatelessWidget {
  const CommunityPromptHandoff(
      {required this.prompt,
      required this.answer,
      required this.onAnswered,
      this.onBrowsePublicActivities,
      super.key});
  final CommunityMemoryPrompt prompt;
  final bool? answer;
  final ValueChanged<bool>? onAnswered;
  final VoidCallback? onBrowsePublicActivities;

  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
          color: const Color(0xFFF1EDF8),
          borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr(context, '根據已保存的記憶', 'Based on a saved memory'),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(prompt.memoryContent),
        const SizedBox(height: 7),
        Text(tr(context, prompt.promptZh, prompt.promptEn)),
        if (answer == null) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton.tonal(
                onPressed: onAnswered == null ? null : () => onAnswered!(true),
                child: Text(tr(context, '有興趣', 'Yes, interested'))),
            TextButton(
                onPressed: onAnswered == null ? null : () => onAnswered!(false),
                child: Text(tr(context, '暫時不用', 'Not now'))),
          ]),
        ] else if (answer == false) ...[
          const SizedBox(height: 8),
          Text(tr(context, '好，這次先略過。', 'Okay, we can leave it for now.')),
        ] else ...[
          const SizedBox(height: 8),
          Text(tr(context, '你可以自行開啟公開活動搜尋。目前沒有搜尋或展示任何結果，也沒有把這段記憶用作篩選。',
              'For now, nothing was searched or shown. This memory is not a filter; use Browse to search.')),
          const SizedBox(height: 8),
          Text(tr(
              context,
              'SmartPLAY 提供康體活動；不保證有相關活動。請自行選擇篩選，並向主辦方確認詳情。這裡未提供義工或技能交換配對。',
              'SmartPLAY recreation only; related activities are not guaranteed. Choose filters and verify details with the organizer. No volunteer or skill-exchange matching.')),
          const SizedBox(height: 10),
          SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                  key: const ValueKey('community-prompt-browse'),
                  onPressed: onBrowsePublicActivities,
                  child: Text(tr(context, '瀏覽公開活動', 'Browse public activities'),
                      textAlign: TextAlign.center))),
          if (onBrowsePublicActivities == null)
            Text(tr(context, '此畫面暫時無法開啟活動列表。',
                'This screen cannot open the activity list yet.')),
        ],
      ]));
}

String confirmedSkillHandoffText(BuildContext context,
    {required int listedCount, required String searchState}) {
  if (listedCount > 0) {
    return tr(context, '已確認技能。請另行查看下方機會及來源狀態；尚未替你報名。',
        'Skill confirmed. Review the listed opportunities and source status separately; nothing was registered.');
  }
  if (searchState == 'unavailable') {
    return tr(context, '已確認技能。機會搜尋尚未可用，沒有確認任何配對，也沒有替你報名。',
        'Skill confirmed. Opportunity search is unavailable; no match is confirmed and nothing was registered.');
  }
  return tr(context, '已確認技能。目前沒有列出相關機會，也沒有替你報名。',
      'Skill confirmed. No related opportunities are currently listed; nothing was registered.');
}

String emptyOpportunityText(BuildContext context, String state) => state ==
        'unavailable'
    ? tr(context, '義工機會來源尚未啟用或暫時不可用；目前沒有可確認的配對。',
        'Volunteer opportunity sources are not enabled or are unavailable; no match can be confirmed.')
    : tr(context, '目前沒有相關機會結果。請查看來源狀態；尚未替你報名。',
        'No related opportunity results are currently listed. Check the source status; nothing was registered.');
