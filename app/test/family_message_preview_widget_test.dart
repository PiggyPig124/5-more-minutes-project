import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'memory_controls_widget_test.dart' as widgets;

FamilyInvitation pair(int epoch) => FamilyInvitation(
    id: 'link',
    email: 'care@example.invalid',
    caregiverName: 'Sam',
    caregiverEmail: 'care@example.invalid',
    elderId: 'elder',
    caregiverId: 'care',
    authorizationEpoch: epoch,
    status: InvitationStatus.accepted,
    scopes: ['family_messages']);
void main() {
  for (final change in ['epoch', 'account']) {
    testWidgets(
        'complete ordinary preview is retired after $change changes, without an automatic send',
        (t) async {
      final posts = <Object>[];
      final api = RestApiClient(client: MockClient((r) async {
        if (r.method == 'POST') posts.add(jsonDecode(r.body));
        return http.Response('[]', 200);
      }));
      final c = AppController(
          api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = widgets.session
        ..links = [pair(1)];
      await widgets.mount(t, c, home: const FamilyMessagesScreen());
      await widgets.tapVisible(
          t, find.byType(DropdownButtonFormField<FamilyInvitation>));
      await widgets.tapVisible(t, find.text('Sam\ncare@example.invalid').last);
      await t.enterText(
          find.byType(TextField), 'Old complete ordinary preview');
      await widgets.tapVisible(
          t, find.widgetWithText(FilledButton, 'Review before sending'));
      expect(find.widgetWithText(FilledButton, 'Confirm send'), findsOneWidget);
      expect(posts, isEmpty);
      if (change == 'account') {
        c.session = const AuthSession(
            accessToken: 'other',
            user: AppUser(
                id: 'other',
                email: 'other@example.invalid',
                displayName: 'Other',
                role: UserRole.elder));
      }
      c.links = [pair(3)];
      await c.refreshFamilyMessages();
      await t.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Confirm send'), findsNothing);
      expect(posts, isEmpty);
      if (change == 'epoch') {
        expect(
            t
                .widget<DropdownButtonFormField<FamilyInvitation>>(
                    find.byType(DropdownButtonFormField<FamilyInvitation>))
                .initialValue,
            isNull);
      }
      expect(t.takeException(), isNull);
      if (change == 'account') {
        expect(find.text('Old complete ordinary preview'), findsNothing);
      }
    });
  }
}
