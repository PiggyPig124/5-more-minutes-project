import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'localization.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(localeControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '設定', 'Settings'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
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
