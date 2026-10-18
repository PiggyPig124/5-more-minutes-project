import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'memory_controls_widget_test.dart' as controls;

// These tests catch a missing/wrong kind label before consent, or a label-only
// change that accidentally mutates the saved kind or saves before confirmation.
class _Fixture {
  final requests = <http.Request>[];
  late final controller = AppController(
      api: RestApiClient(client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST' && request.url.path == '/memories/save') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
              jsonEncode({
                'id': 'saved-memory',
                'revision': 4,
                'content': body['content'],
                'kind': body['kind'],
                'status': 'confirmed',
                'suppressed': false,
                'event_time': null,
                'source_message_id': body['source_message_id'],
                'capture_method': 'user_saved',
                'created_at': '2026-10-15T00:00:00Z',
                'updated_at': '2026-10-15T00:00:00Z',
              }),
              201);
        }
        throw StateError(
            'Unexpected request: ${request.method} ${request.url}');
      })),
      sessionStore: SessionStore(MemoryLocalStore()))
    ..session = controls.session
    ..memoryConsentEnabled = true
    ..memoryControlState = const MemoryControlState(
        enabled: true, revision: 3, counts: {'total': 0, 'current': 0});
}

ChatMessage _suggestion(String kind) => ChatMessage(
        id: 'manual-$kind',
        conversationId: 'conversation',
        body: 'Synthetic response',
        isFromUser: false,
        createdAt: null,
        metadata: {
          'memory_suggestion': {
            'content': 'Synthetic draft body',
            'kind': kind,
            'revision': 3,
            'source_message_id': 'source-message',
            'sensitivity': 'ordinary',
            'requires_confirmation': true,
          },
        });

Future<void> _mount(
        WidgetTester tester, _Fixture fixture, String kind, Locale locale,
        {double scale = 1}) =>
    controls.mount(tester, fixture.controller,
        locale: locale,
        scale: scale,
        home: Scaffold(
            body: SingleChildScrollView(
                child: MessageBubble(message: _suggestion(kind)))));

void main() {
  const labels = [
    ('fact', 'Life fact', '生活事實'),
    ('experience', 'Experience', '生活經歷'),
    ('preference', 'Preference', '喜好'),
    ('emotion', 'Emotion', '心情'),
  ];
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    final en = locale == englishLocale;
    for (final (kind, english, chinese) in labels) {
      testWidgets('$kind category is reviewable before Save in $locale',
          (tester) async {
        final fixture = _Fixture();
        final label = en ? 'Suggested category: $english' : '建議類別：$chinese';
        await _mount(tester, fixture, kind, locale);
        expect(find.text(label), findsOneWidget);
        expect(fixture.requests, isEmpty);

        await tester.tap(find.text(en ? 'Edit and save' : '修改並保存'));
        await tester.pumpAndSettle();
        expect(
            find.descendant(
                of: find.byType(AlertDialog), matching: find.text(label)),
            findsOneWidget);
        expect(fixture.requests, isEmpty);

        await tester.tap(find.text(en ? 'Cancel' : '取消'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.requests, isEmpty);
      });
    }

    testWidgets(
        'category and confirmation remain reachable at 320px 2x $locale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture();
      final label = en ? 'Suggested category: Experience' : '建議類別：生活經歷';
      await _mount(tester, fixture, 'experience', locale, scale: 2);
      expect(find.text(label), findsOneWidget);
      await controls.tapVisible(
          tester, find.text(en ? 'Edit and save' : '修改並保存'));
      expect(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.text(label)),
          findsOneWidget);
      await controls.tapVisible(tester, find.text(en ? 'Cancel' : '取消'));
      expect(tester.takeException(), isNull);
      expect(fixture.requests, isEmpty);
    });
  }

  testWidgets('explicit Save keeps reviewed kind and only edited final body',
      (tester) async {
    final fixture = _Fixture();
    await _mount(tester, fixture, 'emotion', englishLocale);
    expect(find.text('Suggested category: Emotion'), findsOneWidget);
    await tester.tap(find.text('Edit and save'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Suggested category: Emotion')),
        findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Edited final body');
    expect(fixture.requests, isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fixture.requests, hasLength(1));
    final request = fixture.requests.single;
    expect(request.url.path, '/memories/save');
    expect(request.headers['X-Memory-Revision'], '3');
    expect(jsonDecode(request.body), {
      'content': 'Edited final body',
      'kind': 'emotion',
      'source_message_id': 'source-message',
    });
    expect(fixture.controller.memories.single.kind, 'emotion');
    expect(fixture.controller.memories.single.content, 'Edited final body');
  });
}
