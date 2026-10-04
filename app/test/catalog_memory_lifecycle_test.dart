import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final change in ['delete', 'suppress', 'edit', 'remote consent off']) {
    test(
        '$change clears visible provenance and rejects delayed recommendations',
        () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final api = RestApiClient(client: MockClient((request) async {
        if (request.url.path == '/community/catalog/recommendations') {
          started.complete();
          return response.future;
        }
        if (request.url.path == '/memories/control-state') {
          return http.Response(
              jsonEncode({
                'enabled': change != 'remote consent off',
                'revision': 0,
                'counts': {'total': 1, 'current': 1}
              }),
              200);
        }
        if (request.url.path == '/memories') {
          return http.Response(
              jsonEncode([
                {
                  'id': 'm1',
                  'content': 'gardening',
                  'kind': 'preference',
                  'status': 'confirmed',
                  'revision': 0
                }
              ]),
              200);
        }
        if (request.url.path == '/memories/deletions') {
          expect(jsonDecode(request.body)['expected_revision'], 0);
          expect(jsonDecode(request.body)['memory_ids'], ['m1']);
          return http.Response(
              jsonEncode({
                'request_id': 'deleted',
                'revision': 1,
                'counts': {'memories': 1, 'stories': 0}
              }),
              200);
        }
        if (request.url.path == '/memories/m1') {
          return http.Response(
              jsonEncode({
                'id': 'm1',
                'content': 'updated',
                'status': 'confirmed',
                'revision': 1
              }),
              200);
        }
        throw StateError('Unexpected route: ${request.url}');
      }));
      final controller = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = const AuthSession(
            accessToken: 'token',
            user: AppUser(
                id: 'elder',
                displayName: 'Senior',
                email: 'e@example.com',
                role: UserRole.elder))
        ..memoryConsentEnabled = true
        ..catalogRecommendations = [
          CatalogActivity.fromJson({
            'id': 'a',
            'title': 'Private match',
            'recommendation_basis': 'memory'
          })
        ];
      addTearDown(controller.dispose);
      final memory = MemoryRecord.fromJson({
        'id': 'm1',
        'content': 'gardening',
        'status': 'confirmed',
        'revision': 0
      });
      controller.memories = [memory];
      final pending = controller.refreshCatalogRecommendations(silent: true);
      await started.future;
      switch (change) {
        case 'delete':
          expect(await controller.deleteMemory(memory), true);
        case 'suppress':
          expect(await controller.suppressMemory(memory), true);
        case 'edit':
          expect(await controller.editMemory(memory, 'new preference'), true);
        default:
          await controller.loadMemoryConsent();
      }
      final visibleAfterChange = controller.catalogRecommendations.toList();
      response.complete(http.Response(
          jsonEncode({
            'recommendations': [
              {
                'id': 'late',
                'title': 'Private match',
                'recommendation_basis': 'memory'
              }
            ]
          }),
          200));
      await pending;
      expect(visibleAfterChange, isEmpty,
          reason: 'Visible memory-derived cards must disappear after change');
      expect(controller.catalogRecommendations, isEmpty,
          reason: 'Old in-flight response must not resurrect provenance');
    });
  }
  test(
      'unavailable interest is refused locally but historical withdrawal succeeds',
      () async {
    final methods = <String>[];
    final api = RestApiClient(client: MockClient((request) async {
      methods.add(request.method);
      return http.Response(jsonEncode({'interests': []}), 200);
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = const AuthSession(
              accessToken: 'token',
              user: AppUser(
                  id: 'elder',
                  displayName: 'Senior',
                  email: 'e@example.com',
                  role: UserRole.elder));
    addTearDown(controller.dispose);
    final activity = CatalogActivity.fromJson({
      'id': 'expired',
      'available': false,
      'availability_status': 'expired'
    });
    final accepted = await controller.expressInterest(activity);
    final callsBeforeWithdraw = methods.toList();
    expect(await controller.withdrawInterest(activity), true);
    expect(accepted, false);
    expect(callsBeforeWithdraw, isEmpty);
    expect(methods, contains('DELETE'));
  });
}
