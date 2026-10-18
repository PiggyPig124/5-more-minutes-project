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

class HandoffApi extends FakeApi implements CommunityApi, PagedCommunityApi {
  int searches = 0, privateReads = 0, memoryReads = 0;
  bool failPublic = false;
  String? topic, area;
  @override
  Future<CommunitySearchResult<CommunityActivity>> searchCommunityActivityPage(
      {String? topic,
      String? area,
      String targetGroup = 'elderly',
      int offset = 0,
      int limit = 20}) async {
    searches++;
    if (failPublic) throw const ApiException('Synthetic source outage');
    this.topic = topic;
    this.area = area;
    return CommunitySearchResult.fromJson({
      'items': [],
      'sources': [],
      'search_state': 'live',
      'search_reason': 'no_matches',
      'no_results': true,
      'total_count': 0,
      'offset': 0,
      'limit': 20,
      'has_more': false
    }, CommunityActivity.fromJson);
  }

  @override
  Future<List<SkillSuggestion>> listSkillSuggestions() async {
    privateReads++;
    return [];
  }

  @override
  Future<CommunitySearchResult<CommunityOpportunity>> searchOpportunities(
      String skillId) async {
    privateReads++;
    throw StateError('No private opportunity lookup in public handoff');
  }

  @override
  Future<List<MemoryRecord>> listMemories() async {
    memoryReads++;
    return super.listMemories();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppController controller(HandoffApi api) =>
    AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
      ..session = const AuthSession(
          accessToken: 'synthetic',
          user: AppUser(
              id: 'elder-1',
              displayName: 'Synthetic elder',
              email: 'elder@example.invalid',
              role: UserRole.elder))
      ..memoryConsentEnabled = true;
Widget frame(AppController c, Widget child) => ProviderScope(
    overrides: [appControllerProvider.overrideWith((ref) => c)],
    child: MaterialApp(
        locale: englishLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: child));
const message = ChatMessage(
    id: 'answer',
    conversationId: 'conversation-1',
    body:
        'Original answer. Check the official source; no registration was made.',
    isFromUser: false,
    createdAt: null,
    metadata: {
      'community_memory_prompt': {
        'memory_id': 'memory-1',
        'memory_content': 'SECRET_SAVED_INTEREST',
        'topic': 'private tailoring interest',
        'prompt_zh': '想看看公開活動嗎？',
        'prompt_en': 'Would you like to browse public activities?'
      }
    });

void main() {
  testWidgets(
      'Yes stays local; a second explicit Browse opens public-only search with no private prefill',
      (t) async {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final api = HandoffApi()..fakeMessages['conversation-1'] = [message];
    final c = controller(api)
      ..communityTopic = 'tailoring'
      ..communityArea = 'PRIVATE_PREVIOUS_DISTRICT';
    await t.pumpWidget(frame(
        c,
        const ChatDetailScreen(
            conversation:
                Conversation(id: 'conversation-1', title: 'Synthetic chat'))));
    await t.pumpAndSettle();
    expect(api.searches, 0);
    expect(api.privateReads, 0);
    expect(api.memoryReads, 0);
    await t.tap(find.text('Yes, interested'));
    await t.pumpAndSettle();
    expect(api.searches, 0);
    expect(api.privateReads, 0);
    expect(api.lastMessageClientId, isNull);
    expect(
        find.byKey(const ValueKey('community-prompt-browse')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('community-prompt-browse')));
    await t.pumpAndSettle();
    expect(api.searches, 1);
    expect(api.privateReads, 0);
    expect(api.memoryReads, 0);
    expect(api.topic, isNull);
    expect(api.area, isNull);
    expect(find.text('SECRET_SAVED_INTEREST'), findsNothing);
    expect(
        find.textContaining('Matching opportunities are shown'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('public-only error banner retry never reads private skills',
      (t) async {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final api = HandoffApi()..failPublic = true;
    final c = controller(api)
      ..errorMessage = 'Synthetic previous operation failure';
    await t.pumpWidget(
        frame(c, const Scaffold(body: CommunityScreen(publicOnly: true))));
    await t.pumpAndSettle();
    expect(api.searches, 1);
    expect(api.privateReads, 0);
    api.failPublic = false;
    final retry = find.text('Retry');
    await t.ensureVisible(retry);
    await t.tap(retry);
    await t.pumpAndSettle();
    expect(api.searches, 2);
    expect(api.privateReads, 0);
    expect(api.memoryReads, 0);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'Repeat re-displays original locally and does not send a chat or memory operation',
      (t) async {
    final api = HandoffApi();
    final c = controller(api);
    await t.pumpWidget(frame(
        c,
        const Scaffold(
            body: SingleChildScrollView(
                child: MessageBubble(message: message)))));
    expect(find.byKey(const ValueKey('message-repeat')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('message-repeat')));
    await t.pumpAndSettle();
    expect(find.text(message.body), findsNWidgets(2));
    expect(api.lastMessageClientId, isNull);
    expect(api.memoryReads, 0);
    expect(api.fakeMemories, isEmpty);
  });
  testWidgets(
      'memory library offers view-only nine-category browsing while Memory is off',
      (t) async {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final api = HandoffApi()
      ..fakeMemories.addAll([
        const MemoryRecord(
            id: 'p',
            content: 'Synthetic preference',
            kind: 'preference',
            status: 'confirmed'),
        const MemoryRecord(
            id: 'f',
            content: 'My mother lives nearby',
            kind: 'fact',
            status: 'confirmed')
      ]);
    final c = controller(api)..memoryConsentEnabled = false;
    await t.pumpWidget(frame(c, const MemoriesScreen()));
    await t.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('memory-browse-category')), findsOneWidget);
    expect(find.text('Synthetic preference'), findsOneWidget);
    expect(find.text('My mother lives nearby'), findsOneWidget);
    final readsBeforeFilter = api.memoryReads;
    await t.tap(find.byKey(const ValueKey('memory-browse-select')));
    await t.pumpAndSettle();
    await t.tap(find.text('People (0)').last);
    await t.pumpAndSettle();
    expect(
        find.textContaining('No items are classified here.'), findsOneWidget);
    expect(find.text('Synthetic preference'), findsNothing);
    await t.tap(find.byKey(const ValueKey('memory-browse-select')));
    await t.pumpAndSettle();
    await t.tap(find.text('Preferences (1)').last);
    await t.pumpAndSettle();
    expect(find.text('Synthetic preference'), findsOneWidget);
    expect(find.text('My mother lives nearby'), findsNothing);
    expect(api.memoryReads, readsBeforeFilter);
    expect(c.memoryConsentEnabled, isFalse);
    expect(api.fakeMemories.length, 2);
    expect(api.fakeMemories.map((m) => m.id), ['p', 'f']);
  });
}
