import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class RevisionFixture {
  int revision = 3;
  bool enabled = true;
  String content = 'Memory reviewed before deletion';
  final deletions = <http.Request>[];
  Completer<http.Response>? delayedRows;
  final rowsStarted = Completer<void>();
  Map<String, Object> get control => {
        'revision': revision,
        'enabled': enabled,
        'counts': {'total': 1, 'current': 1, 'memories': 1}
      };
  Map<String, Object> get row => {
        'id': 'm',
        'content': content,
        'revision': revision,
        'kind': 'experience',
        'status': 'confirmed'
      };
  late final controller = AppController(
      api: RestApiClient(client: MockClient((r) async {
        if (r.url.path == '/memories/consent') {
          expect(r.headers['X-Memory-Revision'], '$revision');
          enabled = jsonDecode(r.body)['enabled'];
          revision++;
          return http.Response(jsonEncode(control), 200);
        }
        if (r.url.path == '/memories/control-state') {
          return http.Response(jsonEncode(control), 200);
        }
        if (r.url.path == '/memories') {
          if (delayedRows != null) {
            if (!rowsStarted.isCompleted) {
              rowsStarted.complete();
            }
            final pending = delayedRows!;
            delayedRows = null;
            return pending.future;
          }
          return http.Response(jsonEncode([row]), 200);
        }
        if (r.url.path == '/memories/deletions') {
          deletions.add(r);
          revision++;
          return http.Response(
              jsonEncode({
                'request_id': 'receipt',
                'revision': revision,
                'counts': {'memories': 1}
              }),
              200);
        }
        if (r.url.path == '/auth/logout') return http.Response('', 204);
        return http.Response('[]', 200);
      })),
      sessionStore: SessionStore(MemoryLocalStore()))
    ..session = const AuthSession(
        accessToken: 't',
        demoMode: true,
        user: AppUser(
            id: 'elder',
            displayName: 'Long Synthetic Account Name For Small Screen Testing',
            email: 'long.synthetic.account.name@example.test',
            role: UserRole.elder))
    ..memoryControlState = MemoryControlState.fromJson(control)
    ..memoryConsentEnabled = enabled
    ..memories = [MemoryRecord.fromJson(row)];
}

Future<void> mount(WidgetTester t, AppController c,
    {Widget home = const MemoriesScreen(),
    Locale locale = englishLocale,
    double scale = 1}) async {
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

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  for (final enabled in [false, true]) {
    test('consent $enabled refreshes reviewed rows without rebasing deletion',
        () async {
      final f = RevisionFixture()..enabled = !enabled;
      final c = f.controller;
      addTearDown(c.dispose);
      expect(await c.setMemoryConsent(enabled), true);
      expect(c.memories.single.revision, f.revision);
      expect(c.memories.single.content, f.content);
      final p =
          await c.prepareMemoryDeletion(mode: 'selected', memoryIds: ['m']);
      expect(p, isNotNull);
      c.cancelMemoryDeletion(p!);
      expect(await c.confirmMemoryDeletion(p), false);
      expect(f.deletions, isEmpty);
    });
  }
  test('remote change after consent still rejects cached selected revision',
      () async {
    final f = RevisionFixture();
    final c = f.controller;
    addTearDown(c.dispose);
    await c.setMemoryConsent(false);
    f.revision++;
    f.content = 'Remote replacement requiring review';
    expect(await c.prepareMemoryDeletion(mode: 'selected', memoryIds: ['m']),
        isNull);
    expect(f.deletions, isEmpty);
  });
  test('late consent rows cannot restore memories after logout', () async {
    final f = RevisionFixture();
    final c = f.controller;
    addTearDown(c.dispose);
    final rows = Completer<http.Response>();
    f.delayedRows = rows;
    final pending = c.setMemoryConsent(false);
    await f.rowsStarted.future;
    await c.logout();
    rows.complete(http.Response(jsonEncode([f.row]), 200));
    await pending;
    expect(c.memories, isEmpty);
    expect(c.user, isNull);
  });
  test('late off refresh cannot overwrite a newer on revision', () async {
    final f = RevisionFixture();
    final c = f.controller;
    addTearDown(c.dispose);
    final rows = Completer<http.Response>();
    f.delayedRows = rows;
    final off = c.setMemoryConsent(false);
    await f.rowsStarted.future;
    final oldRow = Map<String, Object>.from(f.row);
    expect(await c.setMemoryConsent(true), true);
    rows.complete(http.Response(jsonEncode([oldRow]), 200));
    expect(await off, false);
    expect(c.memoryConsentEnabled, true);
    expect(c.memoryRevision, 5);
    expect(c.memories.single.revision, 5);
    expect(f.deletions, isEmpty);
  });
  testWidgets('turn off then select and cancel deletion needs no Retry',
      (t) async {
    final f = RevisionFixture();
    await mount(t, f.controller);
    await tap(t, find.byKey(const ValueKey('toggle-memory')));
    await tap(t, find.byKey(const ValueKey('view-saved-memories')));
    await tap(t, find.byKey(const ValueKey('select-memory-m')));
    await tap(t, find.byKey(const ValueKey('delete-selected-memories')));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Delete 1 selected memories?'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('cancel-memory-deletion')));
    expect(f.deletions, isEmpty);
  });
  testWidgets(
      'old selection is cleared on off and on instead of adopting new revision',
      (t) async {
    final f = RevisionFixture();
    await mount(t, f.controller);
    await tap(t, find.byKey(const ValueKey('view-saved-memories')));
    await tap(t, find.byKey(const ValueKey('select-memory-m')));
    expect(find.text('Delete selected (1)'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('toggle-memory')));
    expect(find.text('Delete selected (0)'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('select-memory-m')));
    await tap(t, find.byKey(const ValueKey('toggle-memory')));
    expect(find.text('Delete selected (0)'), findsOneWidget);
    expect(f.deletions, isEmpty);
  });
  testWidgets('refreshed remote revision clears old selected IDs', (t) async {
    final f = RevisionFixture();
    await mount(t, f.controller);
    await tap(t, find.byKey(const ValueKey('view-saved-memories')));
    await tap(t, find.byKey(const ValueKey('select-memory-m')));
    f.revision++;
    f.content = 'Changed elsewhere';
    await f.controller.refreshMemoryControlState();
    await f.controller.refreshMemories(silent: true);
    await t.pumpAndSettle();
    expect(find.text('Delete selected (0)'), findsOneWidget);
    expect(f.deletions, isEmpty);
  });
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets(
        'long account menu ${locale.languageCode} scrolls all actions at 320px 200%',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = RevisionFixture();
      await mount(t, f.controller,
          locale: locale,
          scale: 2,
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          showDragHandle: true,
                          builder: (_) =>
                              AccountSheet(user: f.controller.user!)),
                      child: const Text('Open')))));
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      for (final icon in [
        Icons.health_and_safety_outlined,
        Icons.notifications_active_outlined,
        Icons.settings_outlined,
        Icons.logout_rounded
      ]) {
        final button = find.ancestor(
            of: find.byIcon(icon), matching: find.byType(OutlinedButton));
        await t.ensureVisible(button);
        await t.pumpAndSettle();
        final r = t.getRect(button);
        expect(r.top, greaterThanOrEqualTo(0));
        expect(r.bottom, lessThanOrEqualTo(1000));
      }
      // Focus traversal must scroll the focused last action into view.
      final first = find.byIcon(Icons.health_and_safety_outlined);
      Focus.of(t.element(first)).requestFocus();
      await t.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pumpAndSettle();
      }
      expect(t.takeException(), isNull);
      final logout = find.ancestor(
          of: find.byIcon(Icons.logout_rounded),
          matching: find.byType(OutlinedButton));
      expect(
          FocusManager.instance.primaryFocus!.context!
              .findAncestorWidgetOfExactType<OutlinedButton>(),
          same(t.widget<OutlinedButton>(logout)));
      expect(t.getRect(logout).bottom, lessThanOrEqualTo(1000));
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(f.controller.user, isNull);
      expect(f.deletions, isEmpty);
    });
  }
}
