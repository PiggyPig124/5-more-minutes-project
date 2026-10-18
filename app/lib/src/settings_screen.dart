import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'localization.dart';
import 'interaction_preferences_panel.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
        () => ref.read(appControllerProvider).loadMemoryConsent());
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(localeControllerProvider);
    final app = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '設定', 'Settings'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (app.isElder) ...[
            Text(tr(context, '記憶與個人化', 'Memory and personalisation'),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(tr(
                context,
                '記憶預設關閉。開啟後，只有在已設定的 AI 模型可用時，安心伴才會自動保存清楚、普通的興趣；示範模式不會自動保存。其他或不確定內容若要保存，需逐項確認。你可隨時在「我的記憶」查看、修改、暫停或刪除。關閉後會停止新保存和使用記憶。',
                'Memory is off by default. When enabled, Anxin may automatically save clear, ordinary interests only when a configured AI model is available; demo mode does not auto-save. Other or uncertain details require item-level confirmation before saving. View, edit, pause or delete memories at any time. Turning Memory off stops new saves and use of memories.')),
            const SizedBox(height: 12),
            Card(
                child: SwitchListTile(
              value: app.memoryConsentEnabled,
              onChanged: app.loading
                  ? null
                  : (value) async {
                      final messenger = ScaffoldMessenger.of(context);
                      final ok = await ref
                          .read(appControllerProvider)
                          .setMemoryConsent(value);
                      if (mounted && !ok && app.errorMessage != null) {
                        messenger.showSnackBar(
                            SnackBar(content: Text(app.errorMessage!)));
                      }
                    },
              title: Text(tr(context, '使用記憶功能', 'Use Memory')),
              subtitle: Text(app.memoryConsentEnabled
                  ? tr(context, '已開啟。AI 模型可用時，普通興趣可能自動保存；示範模式不會自動保存。其他內容需逐項確認。',
                      'On. Ordinary interests may be saved automatically when an AI model is available; demo mode does not auto-save. Other details require item-level confirmation.')
                  : tr(context, '已關閉。聊天內容不會成為長期記憶。',
                      'Off. Chat content will not become long-term memory.')),
              secondary: const Icon(Icons.bookmark_outline_rounded),
            )),
            if (app.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(app.errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
            ],
            const SizedBox(height: 26),
          ],
          Text(tr(context, '介面語言', 'Interface language'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(tr(context, '選擇後立即生效，並儲存在此裝置。登出後仍會保留。',
              'Changes apply immediately and are saved on this device, including after sign-out.')),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                _languageTile(context, controller, traditionalChineseLocale,
                    '繁體中文', 'Traditional Chinese'),
                const Divider(height: 1),
                _languageTile(
                    context, controller, englishLocale, 'English', '英文'),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(tr(
              context,
              '此設定只改變介面語言，不會翻譯已有的對話、記憶、故事、家人留言或官方資源內容，也不會指定 AI 回覆的語言。',
              'This changes the interface language. It does not translate existing conversations, memories, stories, family messages or official resources, or set the language of AI replies.')),
          if (controller.loadFailed || controller.saveFailed) ...[
            const SizedBox(height: 20),
            Text(
              controller.saveFailed
                  ? tr(context, '語言已切換，但未能儲存。重新開啟時可能不會保留，請重試。',
                      'The language has changed, but could not be saved. It may reset when you reopen the app. Please retry.')
                  : tr(context, '未能讀取已儲存的語言，暫時使用繁體中文。請選擇語言並重試儲存。',
                      'The saved language could not be read. Traditional Chinese is being used. Select a language to save it again.'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => controller.setLocale(controller.locale),
                child: Text(tr(context, '重試儲存', 'Retry saving')),
              ),
            ),
          ],
          const SizedBox(height: 26),
          const InteractionPreferencesPanel(),
        ],
      ),
    );
  }

  Widget _languageTile(BuildContext context, LocaleController controller,
      Locale locale, String title, String subtitle) {
    final selected = controller.locale.languageCode == locale.languageCode;
    return ListTile(
      key: ValueKey('language-${locale.languageCode}'),
      minVerticalPadding: 16,
      selected: selected,
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      onTap: () => controller.setLocale(locale),
    );
  }
}
