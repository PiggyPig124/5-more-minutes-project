import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/care_controls_screen.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
      'support recipient missing stable pair identity cannot be reviewed',
      (tester) async {
    final api = RestApiClient(client: MockClient((request) async {
      final body = request.url.path == '/safety/emergency-contacts'
          ? [
              {
                'id': 'unbound',
                'label': 'Caregiver',
                'caregiver_name': 'Sam',
                'is_enabled': true
              }
            ]
          : <Object?>[];
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    final controller =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = const AuthSession(
              accessToken: 'synthetic',
              user: AppUser(
                  id: 'elder',
                  displayName: 'Elder',
                  email: 'elder@example.invalid',
                  role: UserRole.elder));
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        locale: englishLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: CareControlsScreen(controller: controller, initialTab: 2)));
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(
        find.byKey(const Key('preview-designated-support')));
    expect(button.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
