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

void main() {
  testWidgets(
      'same-name recipients show verified email in picker and preview and send exact selected ID',
      (t) async {
    String? recipient;
    final c = AppController(
        api: RestApiClient(client: MockClient((r) async {
          if (r.url.path == '/family-messages' && r.method == 'POST') {
            final body = jsonDecode(r.body);
            recipient = body['recipient_id'];
            return http.Response(
                jsonEncode({
                  'id': 'sent',
                  'sender_id': 'elder',
                  'recipient_id': recipient,
                  'content': body['content']
                }),
                201);
          }
          return http.Response('[]', 200);
        })),
        sessionStore: SessionStore(MemoryLocalStore()))
      ..session = widgets.session;
    c.links = [
      for (final id in ['a', 'b'])
        FamilyInvitation(
            id: 'link-$id',
            email: '$id@example.invalid',
            status: InvitationStatus.accepted,
            elderId: 'elder',
            caregiverId: id,
            caregiverName: 'Same Name',
            caregiverEmail: '$id@example.invalid',
            scopes: ['family_messages'])
    ];
    await widgets.mount(t, c, home: const FamilyMessagesScreen());
    await widgets.tapVisible(
        t, find.byType(DropdownButtonFormField<FamilyInvitation>));
    expect(find.text('Same Name\na@example.invalid'), findsWidgets);
    expect(find.text('Same Name\nb@example.invalid'), findsWidgets);
    await widgets.tapVisible(t, find.text('Same Name\nb@example.invalid').last);
    await t.enterText(find.byType(TextField), 'Explicit selected content');
    await widgets.tapVisible(
        t, find.widgetWithText(FilledButton, 'Review before sending'));
    expect(find.text('To: Same Name\nb@example.invalid'), findsOneWidget);
    await widgets.tapVisible(
        t, find.widgetWithText(FilledButton, 'Confirm send'));
    expect(recipient, 'b');
  });
}
