import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'interaction_preferences.dart';
import 'localization.dart';

/// Shared section for the existing Settings page and guest chat settings.
class InteractionPreferencesPanel extends ConsumerWidget {
  const InteractionPreferencesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(interactionPreferenceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(context, '互動方式', 'Interaction preference'),
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(tr(context, '在此裝置自動儲存。你隨時都可以打字，語音只會在你點按咪高峰並同意後開始。',
            'Saved automatically on this device. You can always type. Voice starts only after you tap the microphone and agree.')),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            for (final mode in InteractionPreference.values)
              ListTile(
                key: ValueKey('interaction-${mode.name}'),
                minVerticalPadding: 16,
                selected: controller.preference == mode,
                leading: Icon(controller.preference == mode
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(switch (mode) {
                  InteractionPreference.speaking =>
                    tr(context, '說話', 'Speaking'),
                  InteractionPreference.typing => tr(context, '打字', 'Typing'),
                  InteractionPreference.both => tr(context, '說話及打字', 'Both'),
                }),
                subtitle: Text(switch (mode) {
                  InteractionPreference.speaking => tr(
                      context,
                      '優先顯示語音提示；仍可打字。',
                      'Voice-oriented hints; typing stays available.'),
                  InteractionPreference.typing => tr(context, '隱藏咪高峰，使用文字輸入。',
                      'Hide the microphone and use text input.'),
                  InteractionPreference.both =>
                    tr(context, '可選擇語音或文字輸入。', 'Choose voice or text input.'),
                }),
                onTap: () => controller.setPreference(mode),
              ),
          ]),
        ),
        if (controller.loading || controller.saving)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(controller.loading
                ? tr(context, '正在讀取偏好…', 'Loading preference…')
                : tr(context, '正在儲存…', 'Saving…')),
          ),
        if (controller.loadFailed || controller.saveFailed) ...[
          const SizedBox(height: 8),
          Text(
              controller.saveFailed
                  ? tr(context, '偏好已更改，但未能儲存。重新開啟時可能會重設，請重試。',
                      'Your preference changed but could not be saved. It may reset when you reopen the app. Please retry.')
                  : tr(context, '未能讀取已儲存的偏好。你仍可打字或自選語音。請重試或重新選擇。',
                      'Your saved preference could not be read. Typing and opt-in voice remain available. Retry or choose again.'),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(
              key: const Key('interaction-retry'),
              onPressed: controller.retry,
              child: Text(tr(context, '重試', 'Retry'))),
        ],
      ],
    );
  }
}
