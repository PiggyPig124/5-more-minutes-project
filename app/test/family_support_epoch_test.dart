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
      'fresh support preview after a new epoch uses a new key; same epoch retains retry',
      (tester) async {
    var epoch = 1;
    final keys = <String>[];
    final api = RestApiClient(
        accessToken: 'synthetic',
        client: MockClient((request) async {
          Object body = <Object?>[];
          switch (request.url.path) {
            case '/safety/emergency-contacts':
              body = [
                {
                  'id': 'contact',
                  'elder_id': 'elder',
                  'caregiver_id': 'care',
                  'family_link_id': 'link',
                  'label': 'Caregiver',
                  'caregiver_name': 'Sam',
                  'is_enabled': true
                }
              ];
            case '/family-links':
              body = [
                {
                  'id': 'link',
                  'elder_id': 'elder',
                  'caregiver_id': 'care',
                  'authorization_epoch': epoch,
                  'status': 'active',
                  'scopes': ['family_messages'],
                  'email': 'care@example.invalid'
                }
              ];
            case '/safety/support-request':
              keys.add((jsonDecode(request.body) as Map)['idempotency_key']
                  as String);
              body = {'sent': true};
          }
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
    Future<void> share() async {
      await tester.pumpWidget(MaterialApp(
          locale: englishLocale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: CareControlsScreen(
              key: UniqueKey(), controller: controller, initialTab: 2)));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const Key('preview-designated-support')));
      await tester.tap(find.byKey(const Key('preview-designated-support')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('support-contact-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Caregiver \u00b7 Sam').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('support-message-editor')),
          'Same explicitly reviewed text');
      await tester
          .ensureVisible(find.byKey(const Key('review-designated-support')));
      await tester.tap(find.byKey(const Key('review-designated-support')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const Key('confirm-designated-support')));
      await tester.tap(find.byKey(const Key('confirm-designated-support')));
      await tester.pumpAndSettle();
    }

    await share();
    await share();
    epoch = 2;
    await share();
    expect(keys, hasLength(3));
    expect(keys[1], keys[0]);
    expect(keys[2], isNot(keys[0]));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
