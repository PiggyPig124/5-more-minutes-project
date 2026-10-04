import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'localization.dart';

/// Display stable reason codes, never untrusted/raw server error text.
class CommunitySearchNotice extends StatelessWidget {
  const CommunitySearchNotice(
      {super.key,
      required this.reason,
      required this.state,
      required this.hasItems});
  final String? reason;
  final String state;
  final bool hasItems;

  @override
  Widget build(BuildContext context) {
    if (reason == 'not_searched') return const SizedBox.shrink();
    final effective = reason ??
        (state == 'unavailable'
            ? 'source_unavailable'
            : !hasItems
                ? 'no_matches'
                : null);
    final message = switch (effective) {
      'sources_disabled' => tr(context, '社區活動搜尋尚未啟用。你可以直接查看以下機構網站。',
          'Community activity search is not enabled yet. You can visit the provider websites below.'),
      'parse_failed' => tr(context, '搜尋來源的頁面格式已變更，暫時無法讀取活動。請直接查看機構網站。',
          'The source page format has changed and listings cannot be read. Visit the provider websites.'),
      'invalid_query' => tr(context, '搜尋條件無效。請檢查主題或地區後重試。',
          'The search criteria are invalid. Check the topic or area and retry.'),
      'service_error' => tr(context, '搜尋服務暫時出現問題。請稍後重試。',
          'The search service encountered a problem. Please try again later.'),
      'request_failed' => tr(context, '暫時無法連接搜尋服務。請稍後重試。',
          'The search service could not be reached. Please try again later.'),
      'source_unavailable' => tr(context, '搜尋來源暫時無法回應。請稍後重試，或直接查看機構網站。',
          'Search sources are temporarily unavailable. Try later or visit the provider websites.'),
      'no_matches' => tr(context, '這次搜尋沒有找到符合條件的活動。可更改主題或地區再搜尋。',
          'No matching activities were found. Try another topic or area.'),
      'stale_cache' => tr(context, '來源暫時無法更新，這些是先前的快取結果，並非即時資料。',
          'Sources could not be refreshed. These are earlier cached results, not live information.'),
      null => '',
      _ => tr(context, '搜尋來源暫時無法回應。請稍後重試，或直接查看機構網站。',
          'Search sources are temporarily unavailable. Try later or visit the provider websites.'),
    };
    if (message.isEmpty) return const SizedBox.shrink();
    final showLinks = state == 'unavailable';
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(message),
              if (showLinks) ...[
                const SizedBox(height: 8),
                Text(tr(context, '以下是外部網站入口，並非搜尋結果；地區、日期及名額請到原網站確認。',
                    'These are external website links, not search results. Confirm districts, dates and places on the original websites.')),
                TextButton.icon(
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => _open(
                        context,
                        tr(
                            context,
                            'https://www.smartplay.lcsd.gov.hk/website/tc/index.html',
                            'https://www.smartplay.lcsd.gov.hk/website/en/index.html')),
                    label: Text(tr(context, 'SmartPLAY 官方活動網站',
                        'SmartPLAY official activities website'))),
                TextButton.icon(
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () =>
                        _open(context, 'https://hkcmis.com/embed?unit_id=3'),
                    label: Text(
                        tr(context, '培道聯愛會活動網站', 'HKCMIS activity website'))),
                TextButton.icon(
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => _open(context,
                        'https://www.jcvtplatform.hk/zh/volunteer-opportunities'),
                    label: Text(tr(
                        context, '賽馬會眾心行善義工網站', 'JCVTP volunteering website'))),
              ],
            ])));
  }

  Future<void> _open(BuildContext context, String url) async {
    try {
      if (await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // A platform may have no browser. Keep the feedback local and translated.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '無法開啟瀏覽器。請稍後重試。',
              'The browser could not be opened. Please try again later.'))));
    }
  }
}
