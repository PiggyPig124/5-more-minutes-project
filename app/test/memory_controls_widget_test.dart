import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'helpers.dart';

class Fixture {
  final writes = <http.Request>[];
  bool enabled = false;
  bool controlAvailable = true;
  bool timeout = false;
  bool conflict = false;
  late final controller = AppController(
      api: RestApiClient(client: MockClient((r) async {
        if (r.method != 'GET') writes.add(r);
        if (r.url.path == '/memories/consent') {
          enabled = jsonDecode(r.body)['enabled'];
          return http.Response(jsonEncode(control), 200);
        }
        if (r.url.path == '/memories/control-state') {
          if (!controlAvailable) {
            return http.Response('{"detail":"Please try again."}', 503);
          }
          return http.Response(jsonEncode(control), 200);
        }
        if (r.url.path == '/memories') {
          return http.Response(
              jsonEncode([
                {
                  'id': 'm',
                  'content': 'I enjoy painting',
                  'status': 'confirmed',
                  'revision': 3
                }
              ]),
              200);
        }
        if (r.url.path == '/memories/deletions') {
          if (timeout) throw TimeoutException('timeout');
          if (conflict) {
            return http.Response(
                '{"detail":"Memory changed. Review and confirm again."}', 409);
          }
          return http.Response(
              jsonEncode({
                'request_id': 'receipt',
                'revision': 4,
                'counts': {'memories': 7}
              }),
              200);
        }
        return http.Response('[]', 200);
      })),
      sessionStore: SessionStore(MemoryLocalStore()))
    ..session = session;
  Map<String, Object> get control => {
        'enabled': enabled,
        'revision': 3,
        'counts': {'total': 7, 'current': 1, 'memories': 7, 'stories': 2}
      };
}

const session = AuthSession(
    accessToken: 't',
    user: AppUser(
        id: 'elder',
        displayName: 'Senior',
        email: 'e@example.com',
        role: UserRole.elder));
Future<void> mount(WidgetTester t, AppController c,
    {Locale locale = englishLocale,
    double scale = 1,
    Widget home = const MemoriesScreen()}) async {
  await t.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
          locale: locale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: home)));
  await t.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
      'missing memory state prevents old draft and refresh requires a fresh Create action',
      (t) async {
    final f = Fixture()..controlAvailable = false;
    await mount(t, f.controller, home: const StoriesScreen());
    final create = find.widgetWithText(FilledButton, 'Create story card');
    expect(f.controller.memoryRevision, isNull);
    expect(t.widget<FilledButton>(create).onPressed, isNull);
    expect(find.byType(StoryComposerDialog), findsNothing);
    expect(f.writes, isEmpty);
    f.controlAvailable = true;
    await tapVisible(t, find.text('Refresh memories'));
    expect(f.controller.memoryRevision, 3);
    expect(find.byType(StoryComposerDialog), findsNothing);
    expect(f.writes, isEmpty);
    await tapVisible(t, create);
    expect(find.byType(StoryComposerDialog), findsOneWidget);
    expect(f.writes, isEmpty);
  });
  testWidgets(
      'off allows view with independent deletion and toggle sends no deletion',
      (t) async {
    final f = Fixture();
    await mount(t, f.controller);
    expect(find.text('Memory is off'), findsOneWidget);
    expect(find.text('View saved memories'), findsOneWidget);
    expect(find.text('Delete selected (0)'), findsOneWidget);
    expect(find.text('Delete all memories (7)'), findsOneWidget);
    await tapVisible(t, find.text('Turn memory on'));
    expect(f.writes.single.url.path, '/memories/consent');
    await tapVisible(t, find.text('Turn memory off'));
    expect(f.writes.where((r) => r.url.path == '/memories/deletions'), isEmpty);
  });
  testWidgets('selected cancel preserves data and sends no mutation',
      (t) async {
    final f = Fixture();
    await mount(t, f.controller);
    await tapVisible(t, find.text('View saved memories'));
    await t.scrollUntilVisible(
        find.byKey(const ValueKey('select-memory-m')), 300,
        scrollable: find.byType(Scrollable).first);
    await tapVisible(t, find.byKey(const ValueKey('select-memory-m')));
    await t.drag(find.byType(ListView), const Offset(0, 600));
    await t.pumpAndSettle();
    await tapVisible(t, find.text('Delete selected (1)'));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('I enjoy painting')),
        findsOneWidget);
    expect(find.textContaining('Independent tasks'), findsOneWidget);
    await tapVisible(t, find.text('Cancel'));
    expect(f.writes, isEmpty);
    expect(f.controller.memories.single.content, 'I enjoy painting');
  });
  testWidgets('all includes hidden states and waits for confirmation',
      (t) async {
    final f = Fixture();
    await mount(t, f.controller);
    await tapVisible(t, find.text('Delete all memories (7)'));
    expect(f.writes, isEmpty);
    expect(find.text('Delete all 7 memories?'), findsOneWidget);
    await tapVisible(t, find.text('Confirm deletion'));
    expect(f.writes.single.url.path, '/memories/deletions');
    expect(jsonDecode(f.writes.single.body)['mode'], 'all');
    expect(find.text('Deletion confirmed.'), findsOneWidget);
  });
  testWidgets('old API keeps reading and disables dangerous controls',
      (t) async {
    final c = AppController(
        api: FakeApi(), sessionStore: SessionStore(MemoryLocalStore()))
      ..session = session;
    await mount(t, c);
    expect(
        t
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('delete-all-memories')))
            .onPressed,
        isNull);
    expect(find.text('View saved memories'), findsOneWidget);
  });
  testWidgets(
      'timeout hides content and retries the same deletion without fake success',
      (t) async {
    final f = Fixture()..timeout = true;
    await mount(t, f.controller);
    await tapVisible(t, find.text('Delete all memories (7)'));
    await tapVisible(t, find.text('Confirm deletion'));
    expect(find.text('Deletion confirmed.'), findsNothing);
    expect(f.controller.memories, isEmpty);
    expect(
        find.textContaining('Deletion is not yet confirmed'), findsOneWidget);
    expect(f.controller.pendingMemoryDeletion, isNotNull);
    final original = f.writes.single.body;
    f.timeout = false;
    await tapVisible(t, find.text('Retry deletion confirmation'));
    expect(f.writes.length, 2);
    expect(f.writes.last.body, original);
    expect(f.controller.memoryDeletionReceipt, isNotNull);
    // The longer policy explanation keeps the list scrollable after the
    // pending panel shrinks. Return to its receipt before checking visibility.
    await t.drag(find.byType(ListView).first, const Offset(0, 1000));
    await t.pumpAndSettle();
    expect(find.text('Deletion confirmed.'), findsOneWidget);
  });
  testWidgets('409 requires a new explicit deletion review', (t) async {
    final f = Fixture()..conflict = true;
    await mount(t, f.controller);
    await tapVisible(t, find.text('Delete all memories (7)'));
    await tapVisible(t, find.text('Confirm deletion'));
    expect(find.text('Deletion confirmed.'), findsNothing);
    expect(f.controller.pendingMemoryDeletion, isNull);
    final all = find.byKey(const ValueKey('delete-all-memories'));
    await tapVisible(t, all);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(f.writes.length, 1);
    await tapVisible(t, find.text('Cancel'));
    expect(f.writes.length, 1);
  });
  testWidgets('per-item delete reviews actual text before mutation', (t) async {
    final f = Fixture();
    await mount(t, f.controller);
    await tapVisible(t, find.text('View saved memories'));
    await t.scrollUntilVisible(find.text('Delete'), 300,
        scrollable: find.byType(Scrollable).first);
    await tapVisible(t, find.text('Delete'));
    expect(find.text('Delete 1 selected memories?'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('I enjoy painting')),
        findsOneWidget);
    expect(f.writes, isEmpty);
    await tapVisible(t, find.text('Confirm deletion'));
    expect(jsonDecode(f.writes.single.body)['memory_ids'], ['m']);
  });
  for (final locale in [
    englishLocale,
    const Locale.fromSubtags(
        languageCode: 'zh', scriptCode: 'Hant', countryCode: 'HK')
  ]) {
    testWidgets('320px 2x controls and dialog $locale', (t) async {
      await t.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final f = Fixture();
      await mount(t, f.controller, locale: locale, scale: 2);
      expect(t.takeException(), isNull);
      await tapVisible(t, find.byKey(const ValueKey('view-saved-memories')));
      await t.scrollUntilVisible(
          find.byKey(const ValueKey('select-memory-m')), 250,
          scrollable: find.byType(Scrollable).first);
      expect(t.takeException(), isNull);
      await t.drag(find.byType(ListView), const Offset(0, 3000));
      await t.pumpAndSettle();
      await tapVisible(t, find.byKey(const ValueKey('delete-all-memories')));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(t.takeException(), isNull);
      await tapVisible(t, find.byKey(const ValueKey('cancel-memory-deletion')));
      expect(t.takeException(), isNull);
      expect(f.writes, isEmpty);
    });
  }
}
