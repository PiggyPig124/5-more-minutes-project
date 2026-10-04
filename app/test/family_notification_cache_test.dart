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
  testWidgets('family removal clears already rendered care notification cache',
      (tester) async {
    final api = RestApiClient(
        accessToken: 'synthetic',
        client: MockClient((request) async {
          final body = request.url.path == '/notifications'
              ? {
                  'notifications': [
                    {
                      'id': 'old-notice',
                      'kind': 'family_reply',
                      'body': 'Previously shared private notice',
                      'status': 'sent',
                      'created_at': '2026-10-04T00:00:00Z'
                    }
                  ]
                }
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
                  displayName: 'Synthetic elder',
                  email: 'elder@example.invalid',
                  role: UserRole.elder));
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        locale: englishLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: CareControlsScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('Previously shared private notice'), findsOneWidget);
    await controller.revokeInvitation(const FamilyInvitation(
        id: 'link',
        email: 'care@example.invalid',
        elderId: 'elder',
        caregiverId: 'care',
        status: InvitationStatus.accepted,
        scopes: ['care_tasks', 'family_messages']));
    await tester.pumpAndSettle();
    expect(find.text('Previously shared private notice'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
