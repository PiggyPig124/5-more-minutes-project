import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/care_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object? value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test('care API is an optional interface and schedule may be null', () async {
    final api = RestApiClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/check-ins/schedule');
          expect(request.headers['Authorization'], 'Bearer care-token');
          return jsonResponse(null);
        }),
        accessToken: 'care-token');
    expect(api, isA<AnxinApi>());
    expect(api, isA<CareFeaturesApi>());
    expect(await api.getCheckInSchedule(), isNull);
  });

  test('schedule defaults and all editable fields round-trip without id',
      () async {
    const defaults = CheckInSchedule();
    expect(defaults.quietStart, '21:00');
    expect(defaults.quietEnd, '09:00');
    final minimal = CheckInSchedule.fromJson({'id': null});
    expect(minimal.id, isNull);
    expect(minimal.quietStart, '21:00');
    expect(minimal.quietEnd, '09:00');
    final schedule = CheckInSchedule(
      id: 'schedule-1',
      enabled: true,
      frequency: CheckInFrequency.weekly,
      checkInTime: '15:25',
      weekday: 7,
      taskReminders: true,
      familyReplies: true,
      quietStart: '22:30',
      quietEnd: '08:15',
      pausedUntil: DateTime.utc(2026, 10, 4, 8),
      skipDate: '2026-10-02',
    );
    final api = RestApiClient(client: MockClient((request) async {
      expect(request.method, 'PUT');
      expect(request.url.path, '/check-ins/schedule');
      expect(jsonDecode(request.body), {
        'enabled': true,
        'frequency': 'weekly',
        'check_in_time': '15:25',
        'weekday': 7,
        'task_reminders': true,
        'family_replies': true,
        'quiet_start': '22:30',
        'quiet_end': '08:15',
        'paused_until': '2026-10-04T08:00:00.000Z',
        'skip_date': '2026-10-02',
      });
      return jsonResponse({'id': 'schedule-1', ...schedule.toJson()});
    }));
    final saved = await api.saveCheckInSchedule(schedule);
    expect(saved.id, 'schedule-1');
    expect(saved.toJson(), schedule.toJson());
    final resumed = saved.copyWith(clearPause: true, clearSkip: true);
    expect(resumed.toJson()['paused_until'], isNull);
    expect(resumed.toJson()['skip_date'], isNull);
  });

  test('skip has no body; trigger sends empty object and respects not due',
      () async {
    var triggers = 0;
    final api = RestApiClient(client: MockClient((request) async {
      expect(request.method, 'POST');
      if (request.url.path == '/check-ins/skip') {
        expect(request.body, isEmpty);
        return http.Response('', 204);
      }
      expect(request.url.path, '/check-ins/trigger');
      expect(jsonDecode(request.body), isEmpty);
      triggers += 1;
      return jsonResponse({
        'triggered': triggers == 2,
        'message_id': triggers == 2 ? 'message-1' : null,
        'assistant_text': triggers == 2 ? 'How are you today?' : '',
        'conversation_id': triggers == 2 ? 'conversation-1' : null,
      });
    }));
    await api.skipCheckInToday();
    final notDue = await api.triggerCheckIn();
    expect(notDue.triggered, isFalse);
    expect(notDue.messageId, isNull);
    expect(notDue.conversationId, isNull);
    final due = await api.triggerCheckIn();
    expect(due.triggered, isTrue);
    expect(due.assistantText, 'How are you today?');
    expect(due.messageId, 'message-1');
    expect(due.conversationId, 'conversation-1');
  });

  test('inbox preserves every status and patches only explicit actions',
      () async {
    final records = [
      for (final status in [
        'pending',
        'sent',
        'acknowledged',
        'handled',
        'failed'
      ])
        {
          'id': status,
          'kind': status == 'sent'
              ? 'family_reply'
              : status == 'pending'
                  ? 'task_due'
                  : 'check_in',
          'body': 'A care update',
          'status': status,
          'created_at': '2026-10-02T02:00:00Z',
        },
    ];
    final api = RestApiClient(client: MockClient((request) async {
      if (request.method == 'GET') {
        expect(request.url.path, '/notifications');
        return jsonResponse(records);
      }
      expect(request.method, 'PATCH');
      expect(request.url.pathSegments, ['notifications', 'item/1']);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.keys, ['status']);
      expect(body['status'], anyOf('acknowledged', 'handled'));
      return jsonResponse(
          {...records.first, 'id': 'item/1', 'status': body['status']});
    }));
    final items = await api.listNotifications();
    expect(items.map((item) => item.status),
        ['pending', 'sent', 'acknowledged', 'handled', 'failed']);
    expect(items.first.kind, 'task_due');
    expect(items[1].kind, 'family_reply');
    expect(items.first.createdAt, DateTime.utc(2026, 10, 2, 2));
    for (final status in CareNotificationAction.values) {
      final updated = await api.updateNotification(
          notificationId: 'item/1', status: status);
      expect(updated.status, status.name);
    }
  });

  test('contact CRUD uses designated family link and contact ID', () async {
    const contact = {
      'id': 'contact/1',
      'label': 'Daughter',
      'caregiver_name': 'Alex',
      'is_enabled': true
    };
    final methods = <String>[];
    final api = RestApiClient(client: MockClient((request) async {
      methods.add(request.method);
      if (request.method == 'DELETE') {
        expect(request.url.pathSegments,
            ['safety', 'emergency-contacts', 'contact/1']);
        expect(request.body, isEmpty);
        return http.Response('', 204);
      }
      expect(request.url.path, '/safety/emergency-contacts');
      if (request.method == 'POST') {
        expect(jsonDecode(request.body),
            {'family_link_id': 'link-1', 'label': 'Daughter'});
        return jsonResponse(contact, 201);
      }
      return jsonResponse([contact]);
    }));
    final added = await api.addEmergencyContact(
        familyLinkId: 'link-1', label: 'Daughter');
    expect(added.caregiverName, 'Alex');
    expect(added.isEnabled, isTrue);
    final contacts = await api.listEmergencyContacts();
    expect(contacts.single.id, added.id);
    await api.deleteEmergencyContact(added.id);
    expect(methods, ['POST', 'GET', 'DELETE']);
  });

  test('safety event parses reference and status without using raw chat text',
      () async {
    final api = RestApiClient(client: MockClient((request) async {
      expect(request.url.path, '/safety/events');
      expect(request.method, 'GET');
      return jsonResponse([
        {
          'id': 'event-1',
          'trigger_message_id': 'message-1',
          'trigger_text': 'Must never be rendered',
          'created_at': '2026-10-02T02:00:00Z',
          'resolved_at': null,
          'support_request_sent': false,
        }
      ]);
    }));
    final event = (await api.listSafetyEvents()).single;
    expect(event.triggerMessageId, 'message-1');
    expect(event.resolvedAt, isNull);
    expect(event.supportRequestSent, isFalse);
  });

  test('support requires retry ID in body and preserves nullable event',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final api = RestApiClient(client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/safety/support-request');
      expect(request.headers['Idempotency-Key'], 'stable-support-id');
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return jsonResponse({'delivered': true}, 201);
    }));
    await expectLater(
        api.sendSupportRequest(
            emergencyContactId: 'contact-1',
            message: 'Please call me',
            idempotencyKey: ''),
        throwsArgumentError);
    expect(bodies, isEmpty);
    for (final eventId in [null, 'event-1']) {
      await api.sendSupportRequest(
          emergencyContactId: 'contact-1',
          message: 'Please call me',
          familyLinkId: 'captured-link',
          expectedAuthorizationEpoch: 3,
          idempotencyKey: 'stable-support-id',
          safetyEventId: eventId);
      expect(bodies.last, {
        'emergency_contact_id': 'contact-1',
        'message': 'Please call me',
        'idempotency_key': 'stable-support-id',
        'family_link_id': 'captured-link',
        'expected_authorization_epoch': 3,
        'safety_event_id': eventId,
      });
    }
  });

  test('care errors are not converted into false delivery success', () async {
    final api = RestApiClient(
        client: MockClient(
            (_) async => jsonResponse({'detail': 'Contact unavailable'}, 403)));
    await expectLater(
      api.sendSupportRequest(
          emergencyContactId: 'contact-1',
          message: 'Please call me',
          familyLinkId: 'captured-link',
          expectedAuthorizationEpoch: 3,
          idempotencyKey: 'retry-1'),
      throwsA(isA<ApiException>()
          .having((error) => error.statusCode, 'status', 403)),
    );
  });
}
