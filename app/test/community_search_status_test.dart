import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';

class StatusApi extends FakeApi implements CommunityApi {
  StatusApi(this.reason,
      {this.requestFailure = false, this.state = 'unavailable'});
  final String reason, state;
  final bool requestFailure;
  @override
  Future<CommunitySearchResult<CommunityActivity>> searchCommunityActivities(
      {String? topic, String? area}) async {
    if (requestFailure) {
      throw ApiException('RAW BACKEND ERROR',
          statusCode: reason == 'invalid_query'
              ? 422
              : reason == 'service_error'
                  ? 500
                  : null);
    }
    return CommunitySearchResult.fromJson({
      'items': [],
      'sources': [],
      'search_state': state,
      'search_reason': reason,
      'no_results': true,
      'message':
          'Community sources could not be reached, so no current result can be confirmed.'
    }, CommunityActivity.fromJson);
  }

  @override
  Future<List<SkillSuggestion>> listSkillSuggestions() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final cases = {
    'sources_disabled': [
      '社區活動搜尋尚未啟用。你可以直接查看以下機構網站。',
      'Community activity search is not enabled yet. You can visit the provider websites below.'
    ],
    'source_unavailable': [
      '搜尋來源暫時無法回應。請稍後重試，或直接查看機構網站。',
      'Search sources are temporarily unavailable. Try later or visit the provider websites.'
    ],
    'parse_failed': [
      '搜尋來源的頁面格式已變更，暫時無法讀取活動。請直接查看機構網站。',
      'The source page format has changed and listings cannot be read. Visit the provider websites.'
    ],
    'no_matches': [
      '這次搜尋沒有找到符合條件的活動。可更改主題或地區再搜尋。',
      'No matching activities were found. Try another topic or area.'
    ],
    'request_failed': [
      '暫時無法連接搜尋服務。請稍後重試。',
      'The search service could not be reached. Please try again later.'
    ],
    'invalid_query': [
      '搜尋條件無效。請檢查主題或地區後重試。',
      'The search criteria are invalid. Check the topic or area and retry.'
    ],
    'service_error': [
      '搜尋服務暫時出現問題。請稍後重試。',
      'The search service encountered a problem. Please try again later.'
    ],
    'stale_cache': [
      '來源暫時無法更新，這些是先前的快取結果，並非即時資料。',
      'Sources could not be refreshed. These are earlier cached results, not live information.'
    ],
  };
  for (final entry in cases.entries) {
    for (final english in [false, true]) {
      testWidgets(
          '${entry.key} uses one localized notice in ${english ? 'English' : 'Chinese'}',
          (tester) async {
        tester.view.physicalSize = const Size(1000, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = AppController(
            api: StatusApi(entry.key,
                requestFailure: [
                  'request_failed',
                  'invalid_query',
                  'service_error'
                ].contains(entry.key),
                state: entry.key == 'no_matches'
                    ? 'live'
                    : entry.key == 'stale_cache'
                        ? 'cache'
                        : 'unavailable'),
            sessionStore: SessionStore(MemoryLocalStore()));
        await tester.pumpWidget(ProviderScope(
            overrides: [
              appControllerProvider.overrideWith((ref) => controller)
            ],
            child: MaterialApp(
                locale: english ? englishLocale : traditionalChineseLocale,
                supportedLocales: appSupportedLocales,
                localizationsDelegates: appLocalizationsDelegates,
                home: const Scaffold(body: CommunityScreen()))));
        await tester.pumpAndSettle();
        expect(find.text(entry.value[english ? 1 : 0]), findsOneWidget);
        expect(
            find.textContaining('could not be reached, so no current result'),
            findsNothing);
        expect(find.text('RAW BACKEND ERROR'), findsNothing);
        expect(find.textContaining('請檢查網絡'), findsNothing);
        if (entry.key == 'sources_disabled') {
          expect(
              find.text(english
                  ? 'SmartPLAY official activities website'
                  : 'SmartPLAY 官方活動網站'),
              findsOneWidget);
          expect(find.text(english ? 'HKCMIS activity website' : '培道聯愛會活動網站'),
              findsOneWidget);
          expect(
              find.text(english ? 'JCVTP volunteering website' : '賽馬會眾心行善義工網站'),
              findsOneWidget);
          expect(find.textContaining(english ? 'not search results' : '並非搜尋結果'),
              findsOneWidget);
        }
      });
    }
  }
}
