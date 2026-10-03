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
  test(
      'late personalized catalog response is discarded after consent withdrawal',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final api = RestApiClient(client: MockClient((request) async {
      if (request.url.path == '/community/catalog/recommendations') {
        started.complete();
        return response.future;
      }
      if (request.url.path == '/memories/consent') {
        return http.Response(jsonEncode({'enabled': false}), 200);
      }
      throw StateError('Unexpected route');
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = AuthSession(
              accessToken: 'token',
              user: const AppUser(
                  id: 'elder',
                  displayName: 'Senior',
                  email: 'elder@example.com',
                  role: UserRole.elder))
          ..memoryConsentEnabled = true;
    final pending = controller.refreshCatalogRecommendations(silent: true);
    await started.future;
    expect(await controller.setMemoryConsent(false), isTrue);
    response.complete(http.Response(
        jsonEncode({
          'recommendations': [
            {
              'id': 'private-match',
              'title': 'Recommendation',
              'description': 'Class',
              'organizer': 'Centre'
            }
          ]
        }),
        200));
    await pending;
    expect(controller.catalogRecommendations, isEmpty);
    controller.dispose();
  });
}
