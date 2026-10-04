import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'helpers.dart';

Map<String, dynamic> activity(String id) => {
      'id': id,
      'title': '太極班',
      'title_en': 'Tai Chi class',
      'summary': '康體課程',
      'summary_en': 'Recreation course',
      'organization': '康樂及文化事務署',
      'organization_en': 'LCSD',
      'area': '深水埗',
      'area_en': 'Sham Shui Po',
      'event_start_at': '2026-10-05T00:00:00+08:00',
      'event_end_at': '2026-10-28T23:59:59+08:00',
      'date_text': '2026年10月5日至28日；星期一、三（10月19日除外）；10:00–12:00',
      'date_text_en':
          '5–28 October 2026; Mon,Wed (Exclude 19 Oct 2026); 10:00–12:00',
      'eligibility': '60歲或以上',
      'eligibility_en': 'Aged 60 or above',
      'availability_note': '報名及名額請以官方詳情為準',
      'availability_note_en':
          'Confirm enrolment and places in official details.',
      'kind': 'activity',
      'source_name': '香港特別行政區政府 / 康文署 / DATA.GOV.HK',
      'source_name_en': 'HKSARG / LCSD / DATA.GOV.HK',
      'source_url': 'https://www.smartplay.lcsd.gov.hk/programme?lang=tc&id=1',
      'source_url_en':
          'https://www.smartplay.lcsd.gov.hk/programme?lang=en&id=1',
    };
CommunitySearchResult<CommunityActivity> page(String id,
        {int offset = 0, bool more = true}) =>
    CommunitySearchResult.fromJson({
      'items': [activity(id)],
      'search_state': 'live',
      'total_count': 2,
      'offset': offset,
      'limit': 1,
      'has_more': more,
      'checked_at': '2026-10-04T01:02:00Z'
    }, CommunityActivity.fromJson);

class PagingApi extends FakeApi implements CommunityApi, PagedCommunityApi {
  final requests =
      <({String? topic, String? area, String target, int offset})>[];
  final pending = <Completer<CommunitySearchResult<CommunityActivity>>>[];
  bool deferred = false;
  @override
  Future<CommunitySearchResult<CommunityActivity>> searchCommunityActivityPage(
      {String? topic,
      String? area,
      String targetGroup = 'elderly',
      int offset = 0,
      int limit = 20}) {
    requests
        .add((topic: topic, area: area, target: targetGroup, offset: offset));
    if (deferred) {
      final result = Completer<CommunitySearchResult<CommunityActivity>>();
      pending.add(result);
      return result.future;
    }
    return Future.value(page(offset == 0 ? 'first' : 'second',
        offset: offset, more: offset == 0));
  }

  @override
  Future<List<SkillSuggestion>> listSkillSuggestions() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppController controllerFor(PagingApi api) =>
    AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
void main() {
  test(
      'page API sends UTF8 area, audience and paging; parses optional bilingual fields',
      () async {
    late Uri uri;
    final api = RestApiClient(
        origin: 'https://example.test',
        client: MockClient((request) async {
          uri = request.url;
          return http.Response.bytes(
              utf8.encode(jsonEncode({
                'items': [activity('official')],
                'total_count': 31,
                'offset': 20,
                'limit': 20,
                'has_more': false,
                'search_state': 'live'
              })),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    final result = await api.searchCommunityActivityPage(
        topic: 'tai_chi', area: ' 深水埗 ', targetGroup: 'all', offset: 20);
    expect(uri.path, '/community/activities');
    expect(uri.queryParameters, {
      'topic': 'tai_chi',
      'area': '深水埗',
      'target_group': 'all',
      'offset': '20',
      'limit': '20'
    });
    expect(result.totalCount, 31);
    expect(result.offset, 20);
    expect(result.limit, 20);
    expect(result.hasMore, false);
    expect(result.items.single.title, '太極班');
    expect(result.items.single.titleEn, 'Tai Chi class');
    expect(result.items.single.sourceUrlEn, contains('lang=en'));
    final legacy = CommunitySearchResult.fromJson({
      'items': [activity('legacy')]
    }, CommunityActivity.fromJson);
    expect(legacy.hasMore, false);
    expect(legacy.offset, 0);
  });
  test('paging appends once, defaults elderly, and resets offsets for filters',
      () async {
    final api = PagingApi();
    final c = controllerFor(api);
    await c.searchCommunity(topic: 'tai_chi', area: '深水埗');
    expect(api.requests.single.target, 'elderly');
    await c.loadMoreCommunity();
    expect(api.requests.last.offset, 1);
    expect(c.communityActivities.map((a) => a.id), ['first', 'second']);
    expect(c.communityHasMore, false);
    await c.loadMoreCommunity();
    expect(api.requests.length, 2);
    await c.searchCommunity(topic: 'dance', targetGroup: 'all');
    expect(api.requests.last.offset, 0);
    expect(api.requests.last.target, 'all');
    expect(c.communityActivities.map((a) => a.id), ['first']);
  });
  test('late page cannot refill a newer filter and duplicate taps are ignored',
      () async {
    final api = PagingApi();
    final c = controllerFor(api);
    await c.searchCommunity(topic: 'tai_chi');
    api.deferred = true;
    final old = c.loadMoreCommunity();
    final duplicate = c.loadMoreCommunity();
    expect(api.pending.length, 1);
    final next = c.searchCommunity(topic: 'dance', targetGroup: 'all');
    api.pending[1].complete(page('dance'));
    await next;
    api.pending[0].complete(page('old', offset: 1, more: false));
    await old;
    await duplicate;
    expect(c.communityActivities.map((a) => a.id), ['dance']);
    expect(c.communitySearchLoading, false);
    expect(c.communityHasMore, true);
  });
  test('session change discards pending page and resets busy and paging state',
      () async {
    final api = PagingApi();
    final c = controllerFor(api);
    await c.searchCommunity();
    api.deferred = true;
    final old = c.loadMoreCommunity();
    await c.logout();
    api.pending.single.complete(page('late', offset: 1));
    await old;
    expect(c.communityActivities, isEmpty);
    expect(c.communitySearchLoading, false);
    expect(c.communityHasMore, false);
  });
  test('failed subsequent page retains earlier results and allows retry',
      () async {
    final api = PagingApi();
    final c = controllerFor(api);
    await c.searchCommunity();
    api.deferred = true;
    final more = c.loadMoreCommunity();
    api.pending.single.completeError(const ApiException('RAW ERROR'));
    await more;
    expect(c.communityActivities.map((a) => a.id), ['first']);
    expect(c.communityHasMore, true);
    expect(c.communitySearchReason, 'request_failed');
    expect(c.communitySearchLoading, false);
  });
  testWidgets(
      'changing displayed topic or participants starts a fresh first page',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = PagingApi();
    final c = controllerFor(api);
    await tester.pumpWidget(ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => c)],
        child: MaterialApp(
            locale: englishLocale,
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            home: const Scaffold(body: CommunityScreen()))));
    await tester.pumpAndSettle();
    await c.loadMoreCommunity();
    await tester.pumpAndSettle();
    expect(c.communityActivities.length, 2);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tai Chi').last);
    await tester.pumpAndSettle();
    expect(api.requests.last.topic, 'tai_chi');
    expect(api.requests.last.offset, 0);
    expect(c.communityActivities.length, 1);
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All participants').last);
    await tester.pumpAndSettle();
    expect(api.requests.last.target, 'all');
    expect(api.requests.last.offset, 0);
    // Editing area makes the previous filter's next page unavailable until search.
    await tester.enterText(find.byType(TextField).last, 'Sham Shui Po');
    await tester.pumpAndSettle();
    final more = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Load more activities'));
    expect(more.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
  for (final english in [false, true]) {
    testWidgets(
        'official cards, audience and pagination in ${english ? 'English' : 'Chinese'} at large text',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = PagingApi();
      final c = controllerFor(api);
      await tester.pumpWidget(ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => c)],
          child: MaterialApp(
              locale: english ? englishLocale : traditionalChineseLocale,
              supportedLocales: appSupportedLocales,
              localizationsDelegates: appLocalizationsDelegates,
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(1.8)),
                  child: child!),
              home: const Scaffold(body: CommunityScreen()))));
      await tester.pumpAndSettle();
      expect(api.requests.single.target, 'elderly');
      expect(
          find.text(english
              ? 'Activities come from the LCSD public snapshot. Topic and district filters stay within Echo; confirm details with the organizer before attending.'
              : '資料來自康文署公開快照；主題及地區只在安心伴內篩選，報名前請向主辦機構確認。'),
          findsOneWidget);
      c.session = const AuthSession(
          accessToken: 'fake-token',
          user: AppUser(
              id: 'elder-test',
              displayName: 'Elder',
              email: 'elder@example.test',
              role: UserRole.elder));
      c.memoryConsentEnabled = true;
      c.skillSuggestions = const [
        SkillSuggestion(
            id: 'skill', suggestion: 'Teaching', status: 'confirmed')
      ];
      await c.searchCommunity();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.text(english ? 'Volunteer opportunity search is not enabled yet.'
              : '義工機會搜尋尚未接入資料來源。'), 180,
          scrollable: find.byType(Scrollable).first);
      expect(
          find.text(english
              ? 'Volunteer opportunity search is not enabled yet.'
              : '義工機會搜尋尚未接入資料來源。'),
          findsOneWidget);
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
          find.text(english ? 'Tai Chi class' : '太極班'), 220,
          scrollable: scrollable);
      expect(find.text(english ? 'Tai Chi class' : '太極班'), findsOneWidget);
      expect(find.textContaining(english ? 'Aged 60 or above' : '60歲或以上'),
          findsOneWidget);
      expect(
          find.textContaining(
              english ? 'Mon,Wed (Exclude 19 Oct 2026)' : '星期一、三（10月19日除外）'),
          findsOneWidget);
      expect(find.textContaining('10:00–12:00'), findsOneWidget);
      expect(find.textContaining('2026/10/4'), findsNothing);
      expect(find.textContaining('DATA.GOV.HK'), findsWidgets);
      expect(
          find.text(english
              ? 'Data © HKSAR Government and LCSD; source DATA.GOV.HK.'
              : '資料版權屬香港特別行政區政府及康文署；來源 DATA.GOV.HK。'),
          findsOneWidget);
      await tester.scrollUntilVisible(
          find.text(english ? 'View official activity details' : '查看官方活動詳情'),
          160,
          scrollable: scrollable);
      expect(find.text(english ? 'View official activity details' : '查看官方活動詳情'),
          findsOneWidget);
      expect(find.text('Registration details'), findsNothing);
      await tester.scrollUntilVisible(
          find.text(english ? 'Load more activities' : '載入更多活動'), 160,
          scrollable: scrollable);
      await tester.tap(find.text(english ? 'Load more activities' : '載入更多活動'));
      await tester.pumpAndSettle();
      expect(c.communityActivities.length, 2);
      expect(api.requests.last.offset, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
