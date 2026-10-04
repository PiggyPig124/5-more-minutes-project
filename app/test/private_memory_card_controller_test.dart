import 'dart:async';
import 'dart:convert';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'helpers.dart';

MemoryRecord memory(
        {int? revision = 3,
        String status = 'confirmed',
        bool suppressed = false}) =>
    MemoryRecord(
        id: 'm',
        content: 'Original first paragraph\n\nOriginal second paragraph',
        kind: 'note',
        status: status,
        suppressed: suppressed,
        revision: revision);
StoryRecord story({int? revision = 3, List<String> ids = const ['m']}) =>
    StoryRecord(
        id: 's',
        title: 'Original title',
        content: 'Original body',
        memoryIds: ids,
        revision: revision);
AppController controller(Future<http.Response> Function(http.Request) handle) =>
    AppController(
        api: RestApiClient(client: MockClient(handle)),
        sessionStore: SessionStore(MemoryLocalStore()))
      ..session = const AuthSession(
          accessToken: 't',
          user: AppUser(
              id: 'elder',
              displayName: 'Senior',
              email: 'e@example.com',
              role: UserRole.elder))
      ..memoryControlState =
          const MemoryControlState(enabled: true, revision: 3, counts: {})
      ..memories = [memory()]
      ..stories = [story()];
http.Response saved({String id = 's', int revision = 4}) => http.Response(
    jsonEncode({
      'id': id,
      'title': 'Edited title',
      'content': 'Edited body',
      'memory_ids': ['m'],
      'revision': revision
    }),
    200);
void main() {
  test('malformed successful body or duplicate sources preserve failed draft',
      () async {
    for (final body in [
      {
        'title': '',
        'content': '',
        'memory_ids': ['m']
      },
      {
        'title': 'wrong',
        'content': 'Edited body',
        'memory_ids': ['m']
      },
      {
        'title': 'Edited title',
        'content': 'Edited body',
        'memory_ids': ['m', 'm']
      },
    ]) {
      final c = controller((r) async =>
          http.Response(jsonEncode({'id': 's', 'revision': 4, ...body}), 200));
      final draft = c.prepareMemoryCardDraft(c.memories.single)!;
      expect(
          await c.saveMemoryCardDraft(draft,
              title: 'Edited title', content: 'Edited body'),
          false);
      expect(c.isMemoryCardDraftCurrent(draft), true);
      expect(draft.revision, 3);
      expect(c.stories.single.content, 'Original body');
      c.dispose();
    }
  });
  test(
      'confirmed save refreshes sources for immediate edit and next source card',
      () async {
    var reads = 0;
    final c = controller((r) async {
      if (r.method == 'GET') {
        reads++;
        return http.Response(
            jsonEncode([
              {
                'id': 'm',
                'content':
                    'Original first paragraph\n\nOriginal second paragraph',
                'status': 'confirmed',
                'revision': 4
              }
            ]),
            200);
      }
      return saved();
    });
    addTearDown(c.dispose);
    final draft = c.prepareMemoryCardDraft(c.memories.single)!;
    expect(
        await c.saveMemoryCardDraft(draft,
            title: 'Edited title', content: 'Edited body'),
        true);
    expect(reads, 1);
    expect(c.prepareStoryEditDraft(c.stories.single), isNotNull);
    expect(c.prepareMemoryCardDraft(c.memories.single), isNotNull);
  });
  test('post-save source refresh failure keeps confirmed card success',
      () async {
    final c = controller((r) async {
      if (r.method == 'GET') throw TimeoutException('refresh failed');
      return saved();
    });
    addTearDown(c.dispose);
    final draft = c.prepareStoryEditDraft(c.stories.single)!;
    expect(
        await c.saveMemoryCardDraft(draft,
            title: 'Edited title', content: 'Edited body'),
        true);
    expect(c.stories.single.content, 'Edited body');
    expect(c.loading, false);
  });
  test(
      'legacy manual composer preserves its create capability and selected sources',
      () async {
    final api = FakeApi();
    final c =
        AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
          ..session = const AuthSession(
              accessToken: 't',
              user: AppUser(
                  id: 'elder',
                  displayName: 'Senior',
                  email: 'e@example.com',
                  role: UserRole.elder))
          ..memories = [memory(revision: null)];
    addTearDown(c.dispose);
    final draft = c.prepareStoryCreateDraft(memoryIds: ['m']);
    expect(draft, isNotNull);
    expect(
        await c.saveMemoryCardDraft(draft!,
            title: 'Manual title', content: 'Manual body'),
        true);
    expect(api.fakeStories.single.memoryIds, ['m']);
  });
  test(
      'manual composition snapshot rejects same-revision account switch without HTTP',
      () async {
    var writes = 0;
    final c = controller((r) async {
      writes++;
      return saved();
    });
    addTearDown(c.dispose);
    final dynamic d = c;
    final snapshot = d.prepareStoryCreateDraft();
    expect(snapshot.revision, 3);
    expect(d.isMemoryCardDraftCurrent(snapshot), true);
    c.session = const AuthSession(
        accessToken: 'new',
        user: AppUser(
            id: 'other',
            displayName: 'Other',
            email: 'o@example.com',
            role: UserRole.elder));
    expect(d.isMemoryCardDraftCurrent(snapshot), false);
    expect(
        await d.saveMemoryCardDraft(snapshot,
            title: 'Old RAM text', content: 'Old RAM body'),
        false);
    expect(writes, 0);
  });
  test('manual composition snapshot invalidates on unrelated mutation',
      () async {
    final c = controller((r) async => http.Response(
        jsonEncode({
          'id': 'm',
          'content': 'Updated',
          'status': 'confirmed',
          'revision': 4
        }),
        200));
    addTearDown(c.dispose);
    final dynamic d = c;
    final snapshot = d.prepareStoryCreateDraft();
    expect(await c.editMemory(c.memories.single, 'Updated'), true);
    expect(d.isMemoryCardDraftCurrent(snapshot), false);
  });
  test('own save remains current while busy and rejects duplicate submission',
      () async {
    final response = Completer<http.Response>();
    var calls = 0;
    final c = controller((r) {
      calls++;
      return response.future;
    });
    addTearDown(c.dispose);
    final draft = c.prepareStoryEditDraft(c.stories.single)!;
    final saving = c.saveMemoryCardDraft(draft,
        title: 'Edited title', content: 'Edited body');
    expect(c.isMemoryCardDraftCurrent(draft), true);
    expect(c.loading, true);
    expect(
        await c.saveMemoryCardDraft(draft,
            title: 'duplicate', content: 'duplicate'),
        false);
    await c.refreshStories();
    await c.refreshMemories();
    await c.refreshFamilyMessages();
    expect(c.loading, true);
    expect(calls, 1);
    response.complete(http.Response('{"detail":"failure"}', 500));
    expect(await saving, false);
    expect(c.isMemoryCardDraftCurrent(draft), true);
  });
  test(
      'unrelated mutation invalidates draft and old result cannot clear newer busy',
      () async {
    final oldResponse = Completer<http.Response>();
    final newResponse = Completer<http.Response>();
    var writes = 0;
    final c = controller((r) {
      if (r.url.path == '/memories/m') {
        return Future.value(http.Response(
            jsonEncode({
              'id': 'm',
              'content':
                  'Original first paragraph\n\nOriginal second paragraph',
              'status': 'confirmed',
              'revision': 3
            }),
            200));
      }
      writes++;
      return writes == 1 ? oldResponse.future : newResponse.future;
    });
    addTearDown(c.dispose);
    final draft = c.prepareStoryEditDraft(c.stories.single)!;
    final old = c.saveMemoryCardDraft(draft, title: 'old', content: 'old');
    expect(await c.editMemory(c.memories.single, 'unrelated'), true);
    expect(c.isMemoryCardDraftCurrent(draft), false);
    final fresh = c.prepareMemoryCardDraft(c.memories.single)!;
    final newer = c.saveMemoryCardDraft(fresh,
        title: 'Edited title', content: 'Edited body');
    oldResponse.complete(http.Response('{"detail":"old error"}', 500));
    expect(await old, false);
    expect(c.loading, true);
    expect(c.errorMessage, isNull);
    expect(
        await c.saveMemoryCardDraft(fresh,
            title: 'duplicate', content: 'duplicate'),
        false);
    newResponse.complete(saved());
    expect(await newer, true);
  });
  test('read started before save cannot restore old story or family text',
      () async {
    final oldStories = Completer<http.Response>();
    final oldFamily = Completer<http.Response>();
    final c = controller((r) {
      if (r.method != 'GET') return Future.value(saved());
      if (r.url.path == '/memories') {
        return Future.value(http.Response(
            jsonEncode([
              {
                'id': 'm',
                'content':
                    'Original first paragraph\n\nOriginal second paragraph',
                'status': 'confirmed',
                'revision': 4
              }
            ]),
            200));
      }
      if (r.url.path == '/stories') return oldStories.future;
      return oldFamily.future;
    });
    addTearDown(c.dispose);
    final draft = c.prepareStoryEditDraft(c.stories.single)!;
    final storyRead = c.refreshStories();
    final familyRead = c.refreshFamilyMessages();
    expect(
        await c.saveMemoryCardDraft(draft,
            title: 'Edited title', content: 'Edited body'),
        true);
    oldStories.complete(http.Response(
        jsonEncode([
          {
            'id': 's',
            'title': 'Old leaked title',
            'content': 'Old leaked body',
            'revision': 3,
            'memory_ids': ['m']
          }
        ]),
        200));
    oldFamily.complete(http.Response(
        jsonEncode([
          {
            'id': 'f',
            'sender_id': 'elder',
            'recipient_id': 'care',
            'content': 'Old leaked body'
          }
        ]),
        200));
    await Future.wait([storyRead, familyRead]);
    expect(c.stories.single.content, 'Edited body');
    expect(c.familyMessages, isEmpty);
    expect(c.loading, false);
  });
  test('search-only source draft survives failed own save', () async {
    final c =
        controller((r) async => http.Response('{"detail":"failure"}', 500));
    addTearDown(c.dispose);
    c.memories = [];
    c.memorySearchResults = [memory()];
    final draft = c.prepareMemoryCardDraft(c.memorySearchResults.single)!;
    expect(await c.saveMemoryCardDraft(draft, title: 't', content: 'c'), false);
    expect(c.isMemoryCardDraftCurrent(draft), true);
  });
  test('invalid saved ID revision or changed sources cannot report success',
      () async {
    for (final body in [
      {
        'id': 'wrong',
        'revision': 4,
        'memory_ids': ['m']
      },
      {
        'id': 's',
        'revision': 3,
        'memory_ids': ['m']
      },
      {
        'id': 's',
        'revision': 4,
        'memory_ids': ['other']
      },
    ]) {
      final c = controller((r) async => http.Response(
          jsonEncode({...body, 'title': 't', 'content': 'c'}), 200));
      final draft = c.prepareStoryEditDraft(c.stories.single)!;
      expect(
          await c.saveMemoryCardDraft(draft, title: 't', content: 'c'), false);
      expect(c.stories.single.content, 'Original body');
      expect(c.isMemoryCardDraftCurrent(draft), true);
      c.dispose();
    }
  });
  test('prepare and discard are RAM only with immutable original sources',
      () async {
    var requests = 0;
    final c = controller((r) async {
      requests++;
      return saved();
    });
    addTearDown(c.dispose);
    final dynamic d = c;
    final draft = d.prepareMemoryCardDraft(c.memories.single);
    expect(draft, isNotNull);
    expect(draft.title, 'Original first paragraph');
    expect(draft.content, c.memories.single.content);
    expect(draft.memoryIds, ['m']);
    expect(() => draft.memoryIds.add('other'), throwsUnsupportedError);
    expect(requests, 0);
    expect(c.stories.single.title, 'Original title');
  });
  test('candidate paused missing and mixed revision drafts are rejected', () {
    final c = controller((r) async => saved());
    addTearDown(c.dispose);
    final dynamic d = c;
    for (final m in [
      memory(status: 'candidate'),
      memory(status: 'deleted'),
      memory(suppressed: true),
      memory(revision: null),
      memory(revision: 2)
    ]) {
      c.memories = [m];
      expect(d.prepareMemoryCardDraft(m), isNull);
    }
    c.memories = [memory()];
    expect(d.prepareStoryEditDraft(story(revision: null)), isNull);
    expect(d.prepareStoryEditDraft(story(ids: ['m', 'missing'])), isNull);
  });
  test('explicit save is one request at original captured revision', () async {
    final requests = <http.Request>[];
    final c = controller((r) async {
      if (r.method != 'GET') requests.add(r);
      return saved();
    });
    addTearDown(c.dispose);
    final dynamic d = c;
    final draft = d.prepareMemoryCardDraft(c.memories.single);
    expect(
        await d.saveMemoryCardDraft(draft,
            title: 'Edited title', content: 'Edited body'),
        true);
    expect(requests.single.method, 'POST');
    expect(requests.single.headers['X-Memory-Revision'], '3');
    expect(jsonDecode(requests.single.body)['memory_ids'], ['m']);
    expect(d.isMemoryCardDraftCurrent(draft), false);
  });
  test('edit preserves ID sources and clears withdrawn family cache', () async {
    final requests = <http.Request>[];
    final c = controller((r) async {
      if (r.method != 'GET') requests.add(r);
      return saved();
    });
    addTearDown(c.dispose);
    c.familyMessages = [
      const FamilyMessage(
          id: 'f',
          senderId: 'elder',
          recipientId: 'care',
          content: 'Original body')
    ];
    final dynamic d = c;
    final draft = d.prepareStoryEditDraft(c.stories.single);
    expect(draft.storyId, 's');
    expect(
        await d.saveMemoryCardDraft(draft,
            title: 'Edited title', content: 'Edited body'),
        true);
    expect(requests.single.method, 'PATCH');
    expect(jsonDecode(requests.single.body).keys,
        unorderedEquals(['title', 'content']));
    expect(c.stories.single.id, 's');
    expect(c.stories.single.memoryIds, ['m']);
    expect(c.familyMessages, isEmpty);
  });
  for (final failure in ['timeout', '500', '409', '403']) {
    test('$failure preserves RAM draft and captured revision without refresh',
        () async {
      final revisions = <String?>[];
      final c = controller((r) async {
        revisions.add(r.headers['X-Memory-Revision']);
        if (failure == 'timeout') throw TimeoutException('timeout');
        return http.Response('{"detail":"save failed"}', int.parse(failure));
      });
      addTearDown(c.dispose);
      final dynamic d = c;
      final draft = d.prepareStoryEditDraft(c.stories.single);
      expect(
          await d.saveMemoryCardDraft(draft,
              title: 'Unsaved title', content: 'Unsaved body'),
          false);
      expect(d.isMemoryCardDraftCurrent(draft), true);
      expect(c.loading, false);
      expect(
          await d.saveMemoryCardDraft(draft,
              title: 'Unsaved title', content: 'Unsaved body'),
          false);
      expect(revisions, ['3', '3']);
      expect(draft.revision, 3);
      expect(c.stories.single.content, 'Original body');
    });
  }
  test('removed source and different account cannot submit old draft',
      () async {
    var writes = 0;
    final c = controller((r) async {
      writes++;
      return saved();
    });
    addTearDown(c.dispose);
    final dynamic d = c;
    final draft = d.prepareMemoryCardDraft(c.memories.single);
    c.memories = [];
    expect(d.isMemoryCardDraftCurrent(draft), false);
    expect(await d.saveMemoryCardDraft(draft, title: 't', content: 'c'), false);
    c.memories = [memory()];
    c.session = const AuthSession(
        accessToken: 'new',
        user: AppUser(
            id: 'other',
            displayName: 'Other',
            email: 'o@example.com',
            role: UserRole.elder));
    expect(await d.saveMemoryCardDraft(draft, title: 't', content: 'c'), false);
    expect(writes, 0);
  });
  test('late completion cannot overwrite new account caches error or busy',
      () async {
    final pending = Completer<http.Response>();
    final c = controller((r) => pending.future);
    addTearDown(c.dispose);
    final dynamic d = c;
    final draft = d.prepareStoryEditDraft(c.stories.single);
    final save = d.saveMemoryCardDraft(draft, title: 't', content: 'c');
    await Future<void>.delayed(Duration.zero);
    await c.logout();
    c.session = const AuthSession(
        accessToken: 'new',
        user: AppUser(
            id: 'other',
            displayName: 'Other',
            email: 'o@example.com',
            role: UserRole.elder));
    c.loading = true;
    c.errorMessage = 'new error';
    pending.complete(saved());
    expect(await save, false);
    expect(c.stories, isEmpty);
    expect(c.errorMessage, 'new error');
    expect(c.loading, true);
  });
}
