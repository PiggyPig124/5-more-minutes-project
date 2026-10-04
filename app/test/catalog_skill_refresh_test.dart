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

const elderSession = AuthSession(
    accessToken: 'token',
    user: AppUser(
        id: 'elder',
        displayName: 'Senior',
        email: 'e@example.com',
        role: UserRole.elder));
const oldRecommendation = CatalogActivity(
    id: 'old', title: 'Old skill recommendation', description: 'Class');
const suggestion = SkillSuggestion(
    id: 'skill', suggestion: 'Gardening', status: 'confirmed', revision: 0);

void main() {
  for (final decision in ['confirm', 'edit', 'reject']) {
    test(
        'skill $decision clears visible recommendations and rejects late old matches',
        () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final api = RestApiClient(client: MockClient((request) async {
        if (request.url.path == '/community/catalog/recommendations') {
          started.complete();
          return response.future;
        }
        if (request.url.path == '/community/skills/skill/decision') {
          expect(request.headers['X-Memory-Revision'], '0');
          return http.Response(
              jsonEncode({
                'id': 'skill',
                'revision': 0,
                'suggestion': 'Cooking',
                'status': decision == 'reject' ? 'rejected' : 'confirmed'
              }),
              200);
        }
        if (request.url.path == '/community/opportunities') {
          return http.Response(
              jsonEncode({'items': [], 'search_state': 'success'}), 200);
        }
        throw StateError('Unexpected route ${request.url.path}');
      }));
      final controller = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = elderSession
        ..memoryConsentEnabled = true
        ..catalogRecommendations = [oldRecommendation];
      addTearDown(controller.dispose);
      final pending = controller.refreshCatalogRecommendations(silent: true);
      await started.future;
      expect(
          await controller.decideSkill(suggestion,
              decision: decision, skill: decision == 'edit' ? 'Cooking' : null),
          isTrue);
      final visible = controller.catalogRecommendations.toList();
      response.complete(http.Response(
          jsonEncode({
            'recommendations': [
              {'id': 'late', 'title': 'Old skill match'}
            ]
          }),
          200));
      await pending;
      expect(visible, isEmpty,
          reason: 'The saved skill changed, so old matches must disappear');
      expect(controller.catalogRecommendations, isEmpty,
          reason: 'Old response must not restore removed skill provenance');
    });
  }
  for (final decision in ['confirm', 'edit']) {
    test(
        'skill $decision notifies cleared recommendations before opportunity search finishes',
        () async {
      final searchStarted = Completer<void>();
      final searchResponse = Completer<http.Response>();
      final api = RestApiClient(client: MockClient((request) async {
        if (request.url.path == '/community/skills/skill/decision') {
          expect(request.headers['X-Memory-Revision'], '0');
          return http.Response(
              jsonEncode({
                'id': 'skill',
                'revision': 0,
                'suggestion': 'Cooking',
                'status': 'confirmed'
              }),
              200);
        }
        if (request.url.path == '/community/opportunities') {
          searchStarted.complete();
          return searchResponse.future;
        }
        throw StateError('Unexpected route ${request.url.path}');
      }));
      final controller = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = elderSession
        ..memoryConsentEnabled = true
        ..catalogRecommendations = [oldRecommendation];
      addTearDown(controller.dispose);
      var notifiedOfClear = false;
      controller.addListener(() {
        if (controller.catalogRecommendations.isEmpty) notifiedOfClear = true;
      });
      final pending = controller.decideSkill(suggestion,
          decision: decision, skill: decision == 'edit' ? 'Cooking' : null);
      await searchStarted.future;
      final visibleWhilePending = controller.catalogRecommendations.toList();
      final notifiedWhilePending = notifiedOfClear;
      searchResponse.complete(
          http.Response('{"items": [], "search_state": "success"}', 200));
      expect(await pending, isTrue);
      expect(visibleWhilePending, isEmpty);
      expect(notifiedWhilePending, isTrue,
          reason:
              'The UI must update before the second network request finishes');
    });
  }
  test('newer catalog refresh wins over late older response', () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final secondResponse = Completer<http.Response>();
    var requests = 0;
    final api = RestApiClient(client: MockClient((request) async {
      if (request.url.path != '/community/catalog/recommendations') {
        throw StateError('Unexpected route');
      }
      requests++;
      if (requests == 1) {
        firstStarted.complete();
        return firstResponse.future;
      }
      secondStarted.complete();
      return secondResponse.future;
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = elderSession;
    addTearDown(controller.dispose);
    final first = controller.refreshCatalogRecommendations(silent: true);
    await firstStarted.future;
    final second = controller.refreshCatalogRecommendations(silent: true);
    await secondStarted.future;
    secondResponse.complete(http.Response(
        '{"recommendations": [{"id": "new", "title": "Current result"}]}',
        200));
    await second;
    firstResponse.complete(http.Response(
        '{"recommendations": [{"id": "old", "title": "Stale result"}]}', 200));
    await first;
    expect(controller.catalogRecommendations.single.id, 'new');
  });
  test(
      'failed refresh clears old actionable recommendations and notifies even when silent',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final api = RestApiClient(client: MockClient((request) async {
      started.complete();
      return response.future;
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = elderSession
          ..catalogRecommendations = [oldRecommendation];
    addTearDown(controller.dispose);
    var notifiedOfClear = false;
    controller.addListener(() {
      if (controller.catalogRecommendations.isEmpty) notifiedOfClear = true;
    });
    final pending = controller.refreshCatalogRecommendations(silent: true);
    await started.future;
    final visibleWhilePending = controller.catalogRecommendations.toList();
    final notifiedWhilePending = notifiedOfClear;
    response.complete(
        http.Response('{"detail": "Recommendation service unavailable"}', 503));
    await pending;
    expect(visibleWhilePending, isEmpty);
    expect(notifiedWhilePending, isTrue);
    expect(controller.catalogRecommendations, isEmpty);
    expect(controller.errorMessage, isNotNull);
  });
  test(
      'obsolete refresh failure does not set error or finish newer request loading',
      () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final secondResponse = Completer<http.Response>();
    var requests = 0;
    final api = RestApiClient(client: MockClient((request) async {
      requests++;
      if (requests == 1) {
        firstStarted.complete();
        return firstResponse.future;
      }
      secondStarted.complete();
      return secondResponse.future;
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = elderSession;
    addTearDown(controller.dispose);
    final first = controller.refreshCatalogRecommendations();
    await firstStarted.future;
    final second = controller.refreshCatalogRecommendations();
    await secondStarted.future;
    firstResponse
        .complete(http.Response('{"detail": "Obsolete failure"}', 503));
    await first;
    final errorWhileNewerPending = controller.errorMessage;
    final loadingWhileNewerPending = controller.loading;
    secondResponse.complete(http.Response(
        '{"recommendations": [{"id": "new", "title": "Current result"}]}',
        200));
    await second;
    expect(errorWhileNewerPending, isNull);
    expect(loadingWhileNewerPending, isTrue);
    expect(controller.catalogRecommendations.single.id, 'new');
    expect(controller.errorMessage, isNull);
    expect(controller.loading, isFalse);
  });
  test(
      'silent newer refresh finishes inherited loading before older request returns',
      () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final secondResponse = Completer<http.Response>();
    var requests = 0;
    final api = RestApiClient(client: MockClient((request) async {
      requests++;
      if (requests == 1) {
        firstStarted.complete();
        return firstResponse.future;
      }
      secondStarted.complete();
      return secondResponse.future;
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = elderSession;
    addTearDown(controller.dispose);
    final first = controller.refreshCatalogRecommendations();
    await firstStarted.future;
    expect(controller.loading, isTrue);
    final second = controller.refreshCatalogRecommendations(silent: true);
    await secondStarted.future;
    secondResponse.complete(http.Response('{"recommendations": []}', 200));
    await second;
    final loadingAfterSilent = controller.loading;
    firstResponse.complete(http.Response('{"recommendations": []}', 200));
    await first;
    expect(loadingAfterSilent, isFalse);
    expect(controller.loading, isFalse);
  });
  test(
      'skill decision invalidating pending catalog request does not leave loading stuck',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final api = RestApiClient(client: MockClient((request) async {
      if (request.url.path == '/community/catalog/recommendations') {
        started.complete();
        return response.future;
      }
      if (request.url.path == '/community/skills/skill/decision') {
        expect(request.headers['X-Memory-Revision'], '0');
        return http.Response(
            '{"id": "skill", "suggestion": "Gardening", "status": "rejected", "revision": 0}',
            200);
      }
      throw StateError('Unexpected route ${request.url.path}');
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = elderSession
          ..memoryConsentEnabled = true;
    addTearDown(controller.dispose);
    final pending = controller.refreshCatalogRecommendations();
    await started.future;
    expect(controller.loading, isTrue);
    expect(
        await controller.decideSkill(suggestion, decision: 'reject'), isTrue);
    response.complete(http.Response(
        '{"recommendations": [{"id": "old", "title": "Old skill"}]}', 200));
    await pending;
    expect(controller.catalogRecommendations, isEmpty);
    expect(controller.loading, isFalse);
  });
  test('account switch rejects delayed recommendation from previous owner',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final api = RestApiClient(client: MockClient((request) async {
      if (request.url.path == '/community/catalog/recommendations') {
        started.complete();
        return response.future;
      }
      if (request.url.path == '/auth/logout') return http.Response('{}', 200);
      throw StateError('Unexpected route ${request.url.path}');
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = elderSession;
    addTearDown(controller.dispose);
    final pending = controller.refreshCatalogRecommendations(silent: true);
    await started.future;
    await controller.logout();
    controller.session = const AuthSession(
        accessToken: 'next',
        user: AppUser(
            id: 'next-elder',
            displayName: 'Another Senior',
            email: 'next@example.com',
            role: UserRole.elder));
    controller.catalogRecommendations = const [
      CatalogActivity(
          id: 'new-owner', title: 'New owner match', description: '')
    ];
    response.complete(http.Response(
        jsonEncode({
          'recommendations': [
            {'id': 'old-owner', 'title': 'Private previous owner match'}
          ]
        }),
        200));
    await pending;
    expect(controller.catalogRecommendations.single.id, 'new-owner');
  });
  testWidgets(
      'catalog refresh removes a recommendation no longer returned by the server',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var recommendationRequests = 0;
    final api = RestApiClient(client: MockClient((request) async {
      switch (request.url.path) {
        case '/community/catalog/recommendations':
          recommendationRequests++;
          return http.Response(
              jsonEncode({
                'recommendations': recommendationRequests == 1
                    ? [
                        {
                          'id': 'old',
                          'title': 'Old skill recommendation',
                          'description': 'Class',
                          'verified': true
                        }
                      ]
                    : []
              }),
              200);
        case '/community/catalog/activities':
          return http.Response('{"activities": []}', 200);
        case '/community/catalog/interests':
          return http.Response('{"interests": []}', 200);
        default:
          throw StateError('Unexpected route ${request.url.path}');
      }
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = elderSession;
    await tester.pumpWidget(ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
            locale: englishLocale,
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            home: const ActivityCatalogScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Old skill recommendation'), findsOneWidget);
    final refresh =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await refresh.onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('Old skill recommendation'), findsNothing);
    expect(controller.catalogRecommendations, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
