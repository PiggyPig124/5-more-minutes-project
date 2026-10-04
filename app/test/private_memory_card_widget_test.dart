import 'dart:async';
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
import 'memory_controls_widget_test.dart' as widgets;

class CardFixture {
  final writes = <http.Request>[];
  bool fail = false;
  bool serverError = false;
  bool removed = false;
  bool edit = false;
  String body = 'Original painting memory';
  late final controller = AppController(
      api: RestApiClient(client: MockClient((r) async {
        if (r.method != 'GET') writes.add(r);
        if (r.url.path == '/memories/control-state') {
          return http.Response(
              '{"enabled":true,"revision":3,"counts":{"total":1}}', 200);
        }
        if (r.url.path == '/memories') {
          if (removed) return http.Response('[]', 200);
          return http.Response(
              jsonEncode([
                {
                  'id': 'm',
                  'content': body,
                  'status': 'confirmed',
                  'revision': 3
                }
              ]),
              200);
        }
        if (r.url.path == '/stories' && r.method == 'GET' && edit) {
          return http.Response(
              '[{"id":"card","title":"Old title","content":"Old body","memory_ids":["m"],"revision":3}]',
              200);
        }
        if ((r.url.path == '/stories' && r.method == 'POST') ||
            (r.url.path == '/stories/card' && r.method == 'PATCH')) {
          if (fail) throw TimeoutException('timeout');
          if (serverError) {
            return http.Response('{"detail":"Server unavailable"}', 500);
          }
          return http.Response(
              jsonEncode({
                'id': 'card',
                'title': jsonDecode(r.body)['title'],
                'content': jsonDecode(r.body)['content'],
                'memory_ids': r.method == 'PATCH'
                    ? ['m']
                    : jsonDecode(r.body)['memory_ids'],
                'revision': 4
              }),
              200);
        }
        return http.Response('[]', 200);
      })),
      sessionStore: SessionStore(MemoryLocalStore()))
    ..session = widgets.session;
}

const shareStory =
    StoryRecord(id: 's', title: 'Title', content: 'Complete body', revision: 3);
const shareLink = FamilyInvitation(
    id: 'link',
    email: 'c@example.com',
    status: InvitationStatus.accepted,
    scopes: ['family_messages'],
    elderId: 'elder',
    caregiverId: 'caregiver');
Future<void> openCardPreview(WidgetTester t, CardFixture f,
    {StoryRecord story = shareStory,
    Locale locale = englishLocale,
    double scale = 1}) async {
  await f.controller.refreshMemoryControlState();
  f.controller.stories = [story];
  f.controller.links = [shareLink];
  await widgets.mount(t, f.controller,
      locale: locale,
      scale: scale,
      home: FamilyMessagesScreen(initialStory: story));
  await t.scrollUntilVisible(
      find.byType(DropdownButtonFormField<FamilyInvitation>), 300,
      scrollable: find.byType(Scrollable).first);
  await widgets.tapVisible(
      t, find.byType(DropdownButtonFormField<FamilyInvitation>));
  await widgets.tapVisible(t, find.text('c@example.com').last);
  await t.scrollUntilVisible(find.byType(FilledButton).last, 300,
      scrollable: find.byType(Scrollable).first);
  await widgets.tapVisible(t, find.byType(FilledButton).last);
  expect(find.byType(FilledButton), findsOneWidget);
}

void main() {
  testWidgets(
      'confirmed memory opens original RAM card draft and cancel sends no write',
      (t) async {
    final f = CardFixture();
    await widgets.mount(t, f.controller);
    await widgets.tapVisible(t, find.text('View saved memories'));
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('create-private-card-m')));
    expect(find.byType(StoryComposerDialog), findsOneWidget);
    final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
    expect(
        fields[fields.length - 2].controller!.text, 'Original painting memory');
    expect(fields.last.controller!.text, 'Original painting memory');
    expect(find.text('Source: m'), findsOneWidget);
    expect(f.writes, isEmpty);
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('cancel-private-card')));
    expect(find.byType(StoryComposerDialog), findsNothing);
    expect(f.writes, isEmpty);
  });
  testWidgets(
      'timeout retains edited RAM body and only explicit save writes captured revision',
      (t) async {
    final f = CardFixture()..fail = true;
    await widgets.mount(t, f.controller);
    await widgets.tapVisible(t, find.text('View saved memories'));
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('create-private-card-m')));
    await t.enterText(
        find.byKey(const ValueKey('private-card-content')), 'My edited body');
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('save-private-card')));
    expect(find.byType(StoryComposerDialog), findsOneWidget);
    expect(
        t
            .widget<TextField>(
                find.byKey(const ValueKey('private-card-content')))
            .controller!
            .text,
        'My edited body');
    expect(f.writes.length, 1);
    expect(f.writes.single.headers['X-Memory-Revision'], '3');
    f.fail = false;
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('save-private-card')));
    expect(find.byType(StoryComposerDialog), findsNothing);
    expect(f.controller.stories.single.content, 'My edited body');
  });
  testWidgets(
      'editing keeps card ID and source IDs read-only and warns before Save',
      (t) async {
    final f = CardFixture()..edit = true;
    await widgets.mount(t, f.controller, home: const StoriesScreen());
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('edit-private-card-card')));
    expect(find.textContaining('withdraws old in-app'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('Source: m'), findsOneWidget);
    await t.enterText(
        find.byKey(const ValueKey('private-card-content')), 'New body');
    expect(f.writes, isEmpty);
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('save-private-card')));
    expect(f.writes.single.method, 'PATCH');
    expect(f.writes.single.url.path, '/stories/card');
    expect(jsonDecode(f.writes.single.body).containsKey('memory_ids'), isFalse);
    expect(f.controller.stories.single.id, 'card');
    expect(find.byType(StoryComposerDialog), findsNothing);
  });
  testWidgets('account exit invalidates open draft and removes edited RAM text',
      (t) async {
    final f = CardFixture();
    await widgets.mount(t, f.controller);
    await widgets.tapVisible(t, find.text('View saved memories'));
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('create-private-card-m')));
    await t.enterText(
        find.byKey(const ValueKey('private-card-content')), 'Secret RAM text');
    await f.controller.logout();
    await t.pumpAndSettle();
    expect(find.byType(StoryComposerDialog), findsNothing);
    expect(find.text('Secret RAM text'), findsNothing);
    expect(f.writes, isEmpty);
  });
  testWidgets('caregiver cannot render private card contents or edit action',
      (t) async {
    final f = CardFixture();
    f.controller.session = const AuthSession(
        accessToken: 'c',
        user: AppUser(
            id: 'caregiver',
            displayName: 'Caregiver',
            email: 'c@example.com',
            role: UserRole.caregiver));
    await widgets.mount(t, f.controller,
        home: Scaffold(
            body: StoryCard(
                story: const StoryRecord(
                    id: 's', title: 'Secret title', content: 'Secret body'),
                onDelete: (_) async {})));
    expect(find.text('Secret title'), findsNothing);
    expect(find.text('Secret body'), findsNothing);
  });
  testWidgets(
      'source removal closes editor and clears old RAM body without Save',
      (t) async {
    final f = CardFixture();
    await widgets.mount(t, f.controller);
    await widgets.tapVisible(t, find.text('View saved memories'));
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('create-private-card-m')));
    await t.enterText(find.byKey(const ValueKey('private-card-content')),
        'Deleted source draft');
    f.removed = true;
    await f.controller.refreshMemories();
    await t.pumpAndSettle();
    expect(find.byType(StoryComposerDialog), findsNothing);
    expect(find.text('Deleted source draft'), findsNothing);
    expect(f.writes, isEmpty);
  });
  testWidgets('5xx keeps editor and original revision with edited RAM content',
      (t) async {
    final f = CardFixture()..serverError = true;
    await widgets.mount(t, f.controller);
    await widgets.tapVisible(t, find.text('View saved memories'));
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('create-private-card-m')));
    await t.enterText(
        find.byKey(const ValueKey('private-card-content')), 'Keep my edit');
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('save-private-card')));
    expect(find.byType(StoryComposerDialog), findsOneWidget);
    expect(
        t
            .widget<TextField>(
                find.byKey(const ValueKey('private-card-content')))
            .controller!
            .text,
        'Keep my edit');
    expect(f.controller.stories, isEmpty);
    expect(f.controller.memoryRevision, 3);
    expect(f.writes.length, 1);
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('cancel-private-card')));
    expect(f.writes.length, 1);
  });
  testWidgets(
      'direct full-card family screen blocks oversized preview explicitly',
      (t) async {
    final f = CardFixture();
    final story = StoryRecord(
        id: 's', title: 'Title', content: List.filled(10001, 'x').join());
    f.controller.stories = [story];
    await widgets.mount(t, f.controller,
        home: FamilyMessagesScreen(initialStory: story));
    expect(find.textContaining('10,000'), findsOneWidget);
    expect(f.writes, isEmpty);
  });
  testWidgets(
      'new card share requires fresh recipient selection before preview',
      (t) async {
    final f = CardFixture();
    f.controller.links = [
      const FamilyInvitation(
          id: 'link',
          email: 'c@example.com',
          status: InvitationStatus.accepted,
          scopes: ['family_messages'],
          elderId: 'elder',
          caregiverId: 'caregiver')
    ];
    await f.controller.refreshMemoryControlState();
    f.controller.stories = [shareStory];
    await widgets.mount(t, f.controller,
        home: const FamilyMessagesScreen(initialStory: shareStory));
    final preview = find.widgetWithText(FilledButton, 'Review before sending');
    expect(t.widget<FilledButton>(preview).onPressed, isNull);
    await widgets.tapVisible(
        t, find.byType(DropdownButtonFormField<FamilyInvitation>));
    await widgets.tapVisible(t, find.text('c@example.com').last);
    expect(t.widget<FilledButton>(preview).onPressed, isNotNull);
    await widgets.tapVisible(t, preview);
    expect(find.text('Title\nComplete body'), findsOneWidget);
    expect(find.text('Confirm send'), findsOneWidget);
    expect(f.writes, isEmpty);
  });
  testWidgets(
      'manual composer account switch closes old draft and cannot post as new owner',
      (t) async {
    final f = CardFixture();
    await widgets.mount(t, f.controller, home: const StoriesScreen());
    await widgets.tapVisible(
        t, find.widgetWithText(FilledButton, 'Create story card'));
    await t.enterText(
        find.byKey(const ValueKey('private-card-title')), 'Old account title');
    await t.enterText(
        find.byKey(const ValueKey('private-card-content')), 'Old account body');
    f.controller.session = const AuthSession(
        accessToken: 'new',
        user: AppUser(
            id: 'other-elder',
            displayName: 'Other',
            email: 'other@example.com',
            role: UserRole.elder));
    await f.controller.refreshMemoryControlState();
    await t.pumpAndSettle();
    expect(find.byType(StoryComposerDialog), findsNothing);
    expect(find.text('Old account body'), findsNothing);
    expect(f.writes, isEmpty);
  });
  testWidgets('manual creation failure retains RAM text without closing',
      (t) async {
    final f = CardFixture()..serverError = true;
    await widgets.mount(t, f.controller, home: const StoriesScreen());
    await widgets.tapVisible(
        t, find.widgetWithText(FilledButton, 'Create story card'));
    await t.enterText(
        find.byKey(const ValueKey('private-card-title')), 'Manual title');
    await t.enterText(
        find.byKey(const ValueKey('private-card-content')), 'Manual body');
    await widgets.tapVisible(
        t, find.byKey(const ValueKey('save-private-card')));
    expect(find.byType(StoryComposerDialog), findsOneWidget);
    expect(
        t
            .widget<TextField>(
                find.byKey(const ValueKey('private-card-content')))
            .controller!
            .text,
        'Manual body');
    expect(f.writes.length, 1);
  });
  for (final reference in [false, true]) {
    testWidgets(
        'manual creation preserves optional source selection reference=$reference',
        (t) async {
      final f = CardFixture();
      await widgets.mount(t, f.controller, home: const StoriesScreen());
      await widgets.tapVisible(
          t, find.widgetWithText(FilledButton, 'Create story card'));
      await t.enterText(
          find.byKey(const ValueKey('private-card-title')), 'Manual title');
      await t.enterText(
          find.byKey(const ValueKey('private-card-content')), 'Manual body');
      if (reference) {
        await widgets.tapVisible(t, find.byType(CheckboxListTile));
      }
      expect(f.writes, isEmpty);
      await widgets.tapVisible(
          t, find.byKey(const ValueKey('save-private-card')));
      expect(f.writes.single.method, 'POST');
      expect(f.writes.single.headers['X-Memory-Revision'], '3');
      expect(jsonDecode(f.writes.single.body)['memory_ids'],
          reference ? ['m'] : []);
      expect(f.controller.stories.single.memoryIds, reference ? ['m'] : []);
      expect(find.byType(StoryComposerDialog), findsNothing);
    });
  }
  testWidgets(
      'candidate and paused memories have no private-card creation action',
      (t) async {
    final f = CardFixture();
    for (final memory in [
      const MemoryRecord(id: 'm', content: 'Candidate', kind: 'note'),
      const MemoryRecord(
          id: 'm',
          content: 'Paused',
          kind: 'note',
          status: 'confirmed',
          suppressed: true)
    ]) {
      await widgets.mount(t, f.controller,
          home: Scaffold(
              body: MemoryCard(
                  memory: memory,
                  onEdit: (_) async {},
                  onDelete: (_) async {},
                  onSuppress: (_) async {})));
      expect(find.byKey(const ValueKey('create-private-card-m')), findsNothing);
    }
    expect(f.writes, isEmpty);
  });
  testWidgets(
      'open card preview clears revoked recipient without selecting replacement',
      (t) async {
    final f = CardFixture();
    await openCardPreview(t, f);
    f.controller.links = [
      const FamilyInvitation(
          id: 'replacement',
          email: 'new@example.com',
          status: InvitationStatus.accepted,
          scopes: ['family_messages'],
          elderId: 'elder',
          caregiverId: 'new-caregiver')
    ];
    await f.controller.refreshFamilyMessages(silent: true);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Confirm send'), findsNothing);
    expect(
        t
            .widget<DropdownButtonFormField<FamilyInvitation>>(
                find.byType(DropdownButtonFormField<FamilyInvitation>))
            .initialValue,
        isNull);
    expect(
        t
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Review before sending'))
            .onPressed,
        isNull);
    expect(f.writes, isEmpty);
  });
  testWidgets('same-version account switch clears card share RAM and preview',
      (t) async {
    final f = CardFixture();
    await openCardPreview(t, f);
    f.controller.session = const AuthSession(
        accessToken: 'new',
        user: AppUser(
            id: 'other-elder',
            displayName: 'Other',
            email: 'other@example.com',
            role: UserRole.elder));
    await f.controller.refreshMemoryControlState();
    await t.pumpAndSettle();
    expect(find.text('Title\nComplete body'), findsNothing);
    expect(find.text('Confirm send'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(f.writes, isEmpty);
  });
  for (final reason in ['version', 'deleted', 'deletion pending']) {
    testWidgets('card share clears old RAM when source $reason', (t) async {
      final f = CardFixture();
      await openCardPreview(t, f);
      if (reason == 'version') {
        f.controller.stories = [
          const StoryRecord(
              id: 's', title: 'New title', content: 'New body', revision: 4)
        ];
      } else if (reason == 'deleted') {
        f.controller.stories = [];
      } else {
        f.controller.memoryDeletionBusy = true;
      }
      await f.controller.refreshFamilyMessages(silent: true);
      await t.pumpAndSettle();
      expect(find.text('Title\nComplete body'), findsNothing);
      expect(find.text('Confirm send'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(f.writes, isEmpty);
    });
  }
  for (final locale in [englishLocale, const Locale('zh', 'HK')]) {
    testWidgets(
        'private editor readable and actions reachable at 320px 2x $locale',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = CardFixture()
        ..body = List.filled(20, 'A long original source line. ').join();
      await f.controller.refreshMemoryControlState();
      await f.controller.refreshMemories();
      await widgets.mount(t, f.controller,
          locale: locale,
          scale: 2,
          home: Scaffold(
              body: SingleChildScrollView(
                  child: MemoryCard(
                      memory: f.controller.memories.single,
                      onEdit: (_) async {},
                      onDelete: (_) async {},
                      onSuppress: (_) async {}))));
      await widgets.tapVisible(
          t, find.byKey(const ValueKey('create-private-card-m')));
      expect(find.byType(StoryComposerDialog), findsOneWidget);
      final save = find.byKey(const ValueKey('save-private-card'));
      await t.ensureVisible(save);
      await t.pumpAndSettle();
      expect(t.getCenter(save).dy, lessThan(1000));
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching:
                  find.byWidgetPredicate((w) => w is Text && w.data == f.body)),
          findsOneWidget);
      await widgets.tapVisible(
          t, find.byKey(const ValueKey('cancel-private-card')));
      expect(t.takeException(), isNull);
      expect(f.writes, isEmpty);
    });
  }
  for (final locale in [englishLocale, const Locale('zh', 'HK')]) {
    testWidgets('edit warning source Save Back accessible at 320px 2x $locale',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = CardFixture()
        ..edit = true
        ..body = List.filled(20, 'A long original source line. ').join();
      await f.controller.refreshMemoryControlState();
      await f.controller.refreshMemories();
      await f.controller.refreshStories();
      await widgets.mount(t, f.controller,
          locale: locale,
          scale: 2,
          home: Scaffold(
              body: SingleChildScrollView(
                  child: StoryCard(
                      story: f.controller.stories.single,
                      onDelete: (_) async {}))));
      await widgets.tapVisible(
          t, find.byKey(const ValueKey('edit-private-card-card')));
      expect(find.byType(StoryComposerDialog), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching:
                  find.byWidgetPredicate((w) => w is Text && w.data == f.body)),
          findsOneWidget);
      for (final key in ['save-private-card', 'cancel-private-card']) {
        final action = find.byKey(ValueKey(key));
        await t.ensureVisible(action);
        await t.pumpAndSettle();
        expect(t.getCenter(action).dy, lessThan(1000));
      }
      await widgets.tapVisible(
          t, find.byKey(const ValueKey('cancel-private-card')));
      expect(t.takeException(), isNull);
      expect(f.writes, isEmpty);
    });
    testWidgets(
        'full family card preview recipient and Confirm accessible at 320px 2x $locale',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = CardFixture();
      final story = StoryRecord(
          id: 's',
          title: 'Full title',
          content: List.filled(20, 'A long original source line. ').join(),
          revision: 3);
      await openCardPreview(t, f, story: story, locale: locale, scale: 2);
      expect(
          find.byWidgetPredicate(
              (w) => w is Text && w.data == '${story.title}\n${story.content}'),
          findsOneWidget);
      expect(
          find.byWidgetPredicate(
              (w) => w is Text && (w.data?.contains('c@example.com') ?? false)),
          findsOneWidget);
      for (final action in [
        find.byType(OutlinedButton).last,
        find.byType(FilledButton).last
      ]) {
        await t.ensureVisible(action);
        await t.pumpAndSettle();
        expect(t.getCenter(action).dy, lessThan(1000));
      }
      expect(t.takeException(), isNull);
      expect(f.writes, isEmpty);
    });
  }
  testWidgets(
      'oversize full card has explicit share block and no truncated family navigation',
      (t) async {
    final f = CardFixture();
    final story = StoryRecord(
        id: 's', title: 'Title', content: List.filled(10001, 'x').join());
    await widgets.mount(t, f.controller,
        home: Scaffold(
            body: SingleChildScrollView(
                child: StoryCard(story: story, onDelete: (_) async {}))));
    expect(find.textContaining('10,000'), findsOneWidget);
    expect(find.byType(FamilyMessagesScreen), findsNothing);
    expect(f.writes, isEmpty);
  });
}
