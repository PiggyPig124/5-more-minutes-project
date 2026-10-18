import 'dart:async';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class ControlledHelpApi extends FakeApi implements GuestResourceApi {
  final pending =
      <({String query, bool guest, Completer<ResourceSearchResult> result})>[];
  Future<ResourceSearchResult> _request(String query, bool guest) {
    final result = Completer<ResourceSearchResult>();
    pending.add((query: query, guest: guest, result: result));
    return result.future;
  }

  @override
  Future<ResourceSearchResult> searchResources(
          {required String query, int? limit}) =>
      _request(query, false);
  @override
  Future<ResourceSearchResult> searchGuestResources(
          {required String query, int? limit}) =>
      _request(query, true);
}

ResourceSearchResult helpResult(String id) =>
    ResourceSearchResult(query: id, retrievalMode: 'keyword', items: [
      ResourceItem(
          id: id,
          title: id,
          excerpt: 'Synthetic public guidance',
          url: 'https://www.swd.gov.hk/',
          verifiedAt: DateTime(2026, 9, 20),
          nextSteps: const ['Read the official source.'])
    ]);

AuthSession helpSession(String id) => AuthSession(
    accessToken: 'synthetic-$id',
    user: AppUser(
        id: id,
        displayName: 'Synthetic',
        email: '$id@example.invalid',
        role: UserRole.elder));

AppController helpController(ControlledHelpApi api, {bool guest = false}) {
  final result =
      AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()));
  if (!guest) result.session = helpSession('first-owner');
  return result;
}

void main() {
  test('blank input performs no resource request', () async {
    final api = ControlledHelpApi();
    final controller = helpController(api);
    await controller.searchHelp('   ');
    expect(api.pending, isEmpty);
    controller.dispose();
  });
  for (final guest in [false, true]) {
    final role = guest ? 'guest' : 'signed-in';
    test('$role delayed old success cannot replace the latest submitted query',
        () async {
      final api = ControlledHelpApi();
      final controller = helpController(api, guest: guest);
      final old = controller.searchHelp('old query');
      final current = controller.searchHelp('current query');
      api.pending[1].result.complete(helpResult('current-result'));
      await current;
      api.pending[0].result.complete(helpResult('old-result'));
      await old;
      expect(controller.guestHelpResources.single.id, 'current-result');
      expect(api.pending.every((item) => item.guest == guest), isTrue);
      controller.dispose();
    });

    test(
        '$role delayed old failure cannot clear the latest results or set a global error',
        () async {
      final api = ControlledHelpApi();
      final controller = helpController(api, guest: guest);
      final old = controller.searchHelp('old query');
      final current = controller.searchHelp('current query');
      api.pending[1].result.complete(helpResult('current-result'));
      await current;
      api.pending[0].result
          .completeError(const ApiException('Old search failed'));
      await old;
      expect(controller.guestHelpResources.map((item) => item.id),
          ['current-result']);
      expect(controller.errorMessage, isNull);
      controller.dispose();
    });

    test('$role repeated click on the same pending query issues one request',
        () async {
      final api = ControlledHelpApi();
      final controller = helpController(api, guest: guest);
      final first = controller.searchHelp('  same query  ');
      final repeated = controller.searchHelp('same query');
      final requests = api.pending.length;
      for (final call in api.pending) {
        call.result.complete(helpResult('one-result'));
      }
      await Future.wait([first, repeated]);
      expect(requests, 1);
      controller.dispose();
    });
  }

  test('ordinary Help does not overwrite unrelated global status', () async {
    final api = ControlledHelpApi();
    final controller = helpController(api)
      ..errorMessage = 'Unrelated operation warning';
    final search = controller.searchHelp('public query');
    expect(controller.loading, isFalse);
    api.pending.single.result.complete(helpResult('result'));
    await search;
    expect(controller.errorMessage, 'Unrelated operation warning');
    controller.dispose();
  });

  test('ending a guest session invalidates old ordinary Help work', () async {
    final api = ControlledHelpApi();
    final controller = helpController(api, guest: true)
      ..guestSession = GuestSession(id: 'old-guest', expiresAt: DateTime(2099));
    final stale = controller.searchHelp('old public query');
    await controller.endGuestSession();
    controller.guestSession =
        GuestSession(id: 'new-guest', expiresAt: DateTime(2099));
    api.pending.single.result.complete(helpResult('old-guest-result'));
    await stale;
    expect(controller.guestHelpResources, isEmpty);
    controller.dispose();
  });

  test('logout and account replacement preserve newer owner results', () async {
    final api = ControlledHelpApi();
    final controller = helpController(api);
    final stale = controller.searchHelp('old owner query');
    await controller.logout();
    controller.session = helpSession('second-owner');
    final current = controller.searchHelp('new owner query');
    api.pending[1].result.complete(helpResult('new-owner-result'));
    await current;
    api.pending[0].result
        .completeError(const ApiException('Old owner failure'));
    await stale;
    expect(controller.guestHelpResources.single.id, 'new-owner-result');
    expect(controller.errorMessage, isNull);
    controller.dispose();
  });

  test('late ordinary Help completion after controller disposal is ignored',
      () async {
    final api = ControlledHelpApi();
    final controller = helpController(api);
    final pending = controller.searchHelp('public query');
    controller.dispose();
    api.pending.single.result.complete(helpResult('late-result'));
    await expectLater(pending, completes);
  });
}
