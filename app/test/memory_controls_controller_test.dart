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

AppController signedController(AnxinApi api) =>
    AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
      ..session = const AuthSession(
          accessToken: 't',
          user: AppUser(
              id: 'elder',
              displayName: 'Senior',
              email: 'e@example.com',
              role: UserRole.elder))
      ..memoryConsentEnabled = true;
Map<String, dynamic> state(int revision) => {
      'enabled': true,
      'revision': revision,
      'counts': {'memories': 2, 'current': 2, 'total': 2, 'stories': 1}
    };
Map<String, dynamic> record(String id, int revision) => {
      'id': id,
      'content': 'private $id',
      'status': 'confirmed',
      'revision': revision
    };
void main() {
  test('editing invalidates a memory list already in flight', () async {
    final api = DelayedMemoryApi();
    final c = signedController(api);
    addTearDown(c.dispose);
    final pending = c.refreshMemories(silent: true);
    await api.started.future;
    expect(
        await c.editMemory(MemoryRecord.fromJson(record('m', 3)), 'corrected'),
        true);
    api.release.complete([MemoryRecord.fromJson(record('old', 3))]);
    await pending;
    expect(c.memories.map((m) => m.id), isNot(contains('old')));
  });
  test('prepare and cancel deletion leave caches intact and send no mutation',
      () async {
    var writes = 0;
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.method != 'GET') writes++;
      if (r.url.path == '/memories/control-state') {
        return http.Response(jsonEncode(state(3)), 200);
      }
      if (r.url.path == '/memories') {
        return http.Response(jsonEncode([record('m', 3)]), 200);
      }
      throw StateError('${r.method} ${r.url}');
    })));
    addTearDown(c.dispose);
    c.memories = [MemoryRecord.fromJson(record('m', 3))];
    final dynamic d = c;
    final preview =
        await d.prepareMemoryDeletion(mode: 'selected', memoryIds: ['m']);
    expect(preview, isNotNull);
    d.cancelMemoryDeletion(preview);
    expect(c.memories.single.id, 'm');
    expect(writes, 0);
    expect(await d.confirmMemoryDeletion(preview), false);
    expect(writes, 0);
  });
  test(
      'deletion timeout keeps original body and key and hides caches until receipt',
      () async {
    final bodies = <String>[];
    var fail = true;
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.url.path == '/memories/control-state') {
        return http.Response(jsonEncode(state(3)), 200);
      }
      if (r.url.path == '/memories') {
        return http.Response(jsonEncode([record('m', 3)]), 200);
      }
      if (r.url.path == '/memories/deletions') {
        bodies.add(r.body);
        if (fail) throw TimeoutException('timeout');
        return http.Response(
            jsonEncode({
              'request_id': 'receipt',
              'revision': 4,
              'counts': {'memories': 2}
            }),
            200);
      }
      throw StateError('${r.method} ${r.url}');
    })));
    addTearDown(c.dispose);
    c.memories = [MemoryRecord.fromJson(record('m', 3))];
    final dynamic d = c;
    final p = await d.prepareMemoryDeletion(mode: 'all');
    expect(await d.confirmMemoryDeletion(p), false);
    expect(d.pendingMemoryDeletion, isNotNull);
    expect(c.memories, isEmpty);
    await c.refreshMemories(silent: true);
    expect(c.memories, isEmpty);
    fail = false;
    expect(await d.retryMemoryDeletion(), true);
    expect(bodies.length, 2);
    expect(bodies[0], bodies[1]);
    expect(d.memoryDeletionReceipt.requestId, 'receipt');
  });
  test('strict edit uses the captured record revision without refreshing',
      () async {
    final requests = <http.Request>[];
    final c = signedController(RestApiClient(client: MockClient((r) async {
      requests.add(r);
      return http.Response(jsonEncode(record('updated', 4)), 200);
    })));
    addTearDown(c.dispose);
    expect(
        await c.editMemory(MemoryRecord.fromJson(record('m', 3)), 'corrected'),
        true);
    expect(requests.single.method, 'PATCH');
    expect(requests.single.headers['X-Memory-Revision'], '3');
  });
  test('control state can be refreshed without restoring quarantined rows',
      () async {
    var reads = 0;
    final c = signedController(RestApiClient(client: MockClient((r) async {
      reads++;
      return http.Response(jsonEncode(state(8)), 200);
    })));
    addTearDown(c.dispose);
    final dynamic d = c;
    await d.refreshMemoryControlState();
    expect(d.memoryRevision, 8);
    expect(reads, 1);
  });
  test('late consent result cannot overwrite a newer deletion receipt',
      () async {
    final started = Completer<void>();
    final consent = Completer<http.Response>();
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.url.path == '/memories/consent') {
        started.complete();
        return consent.future;
      }
      if (r.url.path == '/memories/control-state') {
        return http.Response(jsonEncode(state(3)), 200);
      }
      if (r.url.path == '/memories/deletions') {
        return http.Response(
            jsonEncode({
              'request_id': 'done',
              'revision': 4,
              'counts': {'memories': 2}
            }),
            200);
      }
      throw StateError('${r.url}');
    })));
    addTearDown(c.dispose);
    c.memoryControlState = MemoryControlState.fromJson(state(3));
    final pending = c.setMemoryConsent(false);
    await started.future;
    final dynamic d = c;
    final preview = await d.prepareMemoryDeletion(mode: 'all');
    expect(await d.confirmMemoryDeletion(preview), true);
    consent.complete(
        http.Response(jsonEncode({...state(4), 'enabled': false}), 200));
    expect(await pending, false);
    expect(c.memoryConsentEnabled, true);
    expect(d.memoryDeletionReceipt.requestId, 'done');
  });
  test('a stale selected row requires renewed review without deletion',
      () async {
    var writes = 0;
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.method != 'GET') writes++;
      if (r.url.path == '/memories/control-state') {
        return http.Response(jsonEncode(state(4)), 200);
      }
      return http.Response(jsonEncode([record('replacement', 4)]), 200);
    })));
    addTearDown(c.dispose);
    c.memories = [MemoryRecord.fromJson(record('old', 3))];
    final dynamic d = c;
    expect(await d.prepareMemoryDeletion(mode: 'selected', memoryIds: ['old']),
        isNull);
    expect(writes, 0);
    expect(c.memories.single.id, 'old');
  });
  for (final route in [
    '/memories',
    '/memories/search',
    '/stories',
    '/family-messages',
    '/community/catalog/activities',
    '/community/catalog/recommendations'
  ]) {
    test('deletion prevents late $route from restoring cached data', () async {
      final started = Completer<void>();
      final release = Completer<http.Response>();
      final c = signedController(RestApiClient(client: MockClient((r) async {
        if (r.url.path == route) {
          started.complete();
          return release.future;
        }
        if (r.url.path == '/memories/control-state') {
          return http.Response(jsonEncode(state(3)), 200);
        }
        if (r.url.path == '/memories/deletions') {
          return http.Response(
              jsonEncode({
                'request_id': 'done',
                'revision': 4,
                'counts': {'memories': 2}
              }),
              200);
        }
        throw StateError(r.url.path);
      })));
      addTearDown(c.dispose);
      c.links = [
        const FamilyInvitation(
            id: 'link',
            email: 'care@example.com',
            status: InvitationStatus.accepted,
            scopes: ['family_messages'],
            elderId: 'elder',
            caregiverId: 'care')
      ];
      Future<dynamic> read;
      switch (route) {
        case '/memories':
          read = c.refreshMemories(silent: true);
        case '/memories/search':
          read = c.searchMemories('private');
        case '/stories':
          read = c.refreshStories(silent: true);
        case '/family-messages':
          read = c.refreshFamilyMessages(silent: true);
        case '/community/catalog/activities':
          read = c.refreshCatalogActivities(silent: true);
        default:
          read = c.refreshCatalogRecommendations(silent: true);
      }
      await started.future;
      final dynamic d = c;
      final preview = await d.prepareMemoryDeletion(mode: 'all');
      expect(await d.confirmMemoryDeletion(preview), true);
      final rows = [record('late', 3)];
      release.complete(http.Response(
          jsonEncode(route == '/memories/search'
              ? {'items': rows}
              : route == '/community/catalog/recommendations'
                  ? {'recommendations': rows}
                  : rows),
          200));
      await read;
      expect(c.memories, isEmpty);
      expect(c.memorySearchResults, isEmpty);
      expect(c.stories, isEmpty);
      expect(c.familyMessages, isEmpty);
      expect(c.catalogActivities, isEmpty);
      expect(c.catalogRecommendations, isEmpty);
    });
  }
  test('deletion receipt from a logged out account is ignored', () async {
    final started = Completer<void>();
    final release = Completer<http.Response>();
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.url.path == '/memories/control-state') {
        return http.Response(jsonEncode(state(3)), 200);
      }
      if (r.url.path == '/memories/deletions') {
        started.complete();
        return release.future;
      }
      if (r.url.path == '/auth/logout') return http.Response('', 204);
      throw StateError('${r.url}');
    })));
    addTearDown(c.dispose);
    final dynamic d = c;
    final preview = await d.prepareMemoryDeletion(mode: 'all');
    final pending = d.confirmMemoryDeletion(preview);
    await started.future;
    await c.logout();
    release.complete(http.Response(
        jsonEncode({
          'request_id': 'old',
          'revision': 4,
          'counts': {'memories': 2}
        }),
        200));
    expect(await pending, false);
    expect(d.memoryDeletionReceipt, isNull);
    expect(d.pendingMemoryDeletion, isNull);
  });
  test('receipt refreshes remaining counts using a guarded control state read',
      () async {
    var stateReads = 0;
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.url.path == '/memories/control-state') {
        stateReads++;
        return http.Response(
            jsonEncode(stateReads == 1
                ? state(3)
                : {
                    'enabled': true,
                    'revision': 4,
                    'counts': {'total': 1, 'current': 1}
                  }),
            200);
      }
      if (r.url.path == '/memories') {
        return http.Response(jsonEncode([record('m', 3)]), 200);
      }
      if (r.url.path == '/memories/deletions') {
        return http.Response(
            jsonEncode({
              'request_id': 'done',
              'revision': 4,
              'counts': {'memories': 1}
            }),
            200);
      }
      throw StateError('${r.url}');
    })));
    addTearDown(c.dispose);
    c.memories = [MemoryRecord.fromJson(record('m', 3))];
    final dynamic d = c;
    final preview =
        await d.prepareMemoryDeletion(mode: 'selected', memoryIds: ['m']);
    expect(await d.confirmMemoryDeletion(preview), true);
    expect(c.memoryControlState?.counts['total'], 1);
    expect(stateReads, 2);
  });
  test('deletion clears chat source caches and rejects late message load',
      () async {
    final started = Completer<void>();
    final release = Completer<http.Response>();
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.url.path == '/conversations/chat/messages') {
        started.complete();
        return release.future;
      }
      if (r.url.path == '/conversations/chat/actions') {
        return http.Response('[]', 200);
      }
      if (r.url.path == '/memories/control-state') {
        return http.Response(jsonEncode(state(3)), 200);
      }
      if (r.url.path == '/memories/deletions') {
        return http.Response(
            jsonEncode({
              'request_id': 'done',
              'revision': 4,
              'counts': {'memories': 2}
            }),
            200);
      }
      throw StateError('${r.url}');
    })));
    addTearDown(c.dispose);
    c.conversations = [const Conversation(id: 'chat', title: 'private source')];
    c.messagesByConversation['chat'] = [
      const ChatMessage(
          id: 'cached',
          conversationId: 'chat',
          body: 'private source',
          isFromUser: true,
          createdAt: null)
    ];
    final read = c.loadMessages('chat');
    await started.future;
    final dynamic d = c;
    final preview = await d.prepareMemoryDeletion(mode: 'all');
    expect(await d.confirmMemoryDeletion(preview), true);
    expect(c.messagesFor('chat'), isEmpty);
    expect(c.conversations, isEmpty);
    release.complete(http.Response(
        jsonEncode([
          {
            'id': 'late',
            'conversation_id': 'chat',
            'content': 'private source',
            'role': 'user'
          }
        ]),
        200));
    await read;
    expect(c.messagesFor('chat'), isEmpty);
  });
  test(
      'conflicting deletion reloads current rows and requires new confirmation',
      () async {
    var writes = 0;
    var reads = 0;
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.url.path == '/memories/control-state') {
        reads++;
        return http.Response(jsonEncode(state(reads == 1 ? 3 : 4)), 200);
      }
      if (r.url.path == '/memories') {
        return http.Response(jsonEncode([record('fresh', 4)]), 200);
      }
      if (r.url.path == '/memories/deletions') {
        writes++;
        return http.Response(jsonEncode({'detail': 'stale revision'}), 409);
      }
      throw StateError('${r.url}');
    })));
    addTearDown(c.dispose);
    final dynamic d = c;
    final preview = await d.prepareMemoryDeletion(mode: 'all');
    expect(await d.confirmMemoryDeletion(preview), false);
    expect(d.pendingMemoryDeletion, isNull);
    expect(d.memoryDeletionReceipt, isNull);
    expect(c.errorMessage, contains('confirming again'));
    expect(c.memories.single.id, 'fresh');
    expect(await d.retryMemoryDeletion(), false);
    expect(writes, 1);
  });
  test(
      'unadvanced deletion receipt cannot report success or release quarantine',
      () async {
    final api = UnadvancedReceiptApi();
    final c = signedController(api);
    addTearDown(c.dispose);
    final dynamic d = c;
    c.memories = [MemoryRecord.fromJson(record('m', 3))];
    final preview = await d.prepareMemoryDeletion(mode: 'all');
    expect(await d.confirmMemoryDeletion(preview), false);
    expect(d.memoryDeletionReceipt, isNull);
    expect(d.pendingMemoryDeletion, isNotNull);
    expect(c.memories, isEmpty);
  });
  test('strict confirmation submits the captured candidate revision', () async {
    final requests = <http.Request>[];
    final c = signedController(RestApiClient(client: MockClient((r) async {
      requests.add(r);
      return http.Response(jsonEncode(record('saved', 4)), 200);
    })));
    addTearDown(c.dispose);
    expect(
        await c.confirmMemory(MemoryRecord.fromJson(
            {...record('candidate', 3), 'status': 'candidate'})),
        true);
    expect(requests.single.headers['X-Memory-Revision'], '3');
  });
  test('chat error from an old account does not overwrite the next account',
      () async {
    final api = DelayedErrorChatApi();
    final c = signedController(api);
    addTearDown(c.dispose);
    final send = c.sendMessage(conversationId: 'chat', content: 'hello');
    await api.started.future;
    await c.logout();
    await c.login(email: 'next@example.com', password: 'pw');
    api.release.completeError(const ApiException('old account private error'));
    expect(await send, false);
    expect(c.errorMessage, isNull);
  });
  test(
      'obsolete consent completion cannot finish a newer story loading indicator',
      () async {
    final consentStarted = Completer<void>();
    final storyStarted = Completer<void>();
    final consent = Completer<http.Response>();
    final story = Completer<http.Response>();
    final c = signedController(RestApiClient(client: MockClient((r) async {
      if (r.url.path == '/memories/consent') {
        consentStarted.complete();
        return consent.future;
      }
      if (r.url.path == '/stories') {
        storyStarted.complete();
        return story.future;
      }
      throw StateError('${r.url}');
    })));
    addTearDown(c.dispose);
    c.memoryControlState = MemoryControlState.fromJson(state(3));
    final older = c.setMemoryConsent(false);
    await consentStarted.future;
    final newer = c.createStory(
        title: 'independent', content: 'new story', expectedRevision: 3);
    await storyStarted.future;
    consent.complete(
        http.Response(jsonEncode({...state(4), 'enabled': false}), 200));
    expect(await older, false);
    expect(c.loading, true);
    story.complete(http.Response(
        jsonEncode({
          'id': 'story',
          'title': 'independent',
          'content': 'new story',
          'memory_ids': [],
          'revision': 4
        }),
        200));
    expect(await newer, true);
    expect(c.loading, false);
  });
  for (final kind in ['memory', 'story']) {
    test('strict $kind composer rejects its captured missing revision',
        () async {
      var writes = 0;
      final c = signedController(RestApiClient(client: MockClient((r) async {
        writes++;
        return http.Response(
            jsonEncode(kind == 'memory'
                ? record('saved', 9)
                : {
                    'id': 'story',
                    'title': 'new',
                    'content': 'new',
                    'revision': 9
                  }),
            200);
      })));
      addTearDown(c.dispose);
      c.memoryControlState = MemoryControlState.fromJson(state(8));
      final result = kind == 'memory'
          ? await c.createMemory(content: 'draft', expectedRevision: null)
          : await c.createStory(
              title: 'draft', content: 'draft', expectedRevision: null);
      expect(result, false);
      expect(writes, 0);
    });
  }
  test(
      'pending actions from before deletion cannot restore private source text',
      () async {
    final api = DelayedActionsApi();
    api.fakeConversations
        .add(const Conversation(id: 'chat', title: 'private source'));
    final c = signedController(api);
    addTearDown(c.dispose);
    final refresh = c.refreshHome(silent: true);
    await api.started.future;
    final preview = await c.prepareMemoryDeletion(mode: 'all');
    expect(await c.confirmMemoryDeletion(preview!), true);
    api.release.complete([
      ActionProposal.fromJson({
        'id': 'private',
        'kind': 'care_task',
        'title': 'private source',
        'description': 'private source'
      })
    ]);
    await refresh;
    expect(c.pendingActions, isEmpty);
  });
  test(
      'old family send completion cannot release the new account same-key busy guard',
      () async {
    final api = DelayedFamilyBusyApi();
    api.fakeLinks.add(const FamilyInvitation(
        id: 'link',
        email: 'care@example.com',
        status: InvitationStatus.accepted,
        scopes: ['family_messages'],
        elderId: 'elder-1',
        caregiverId: 'care'));
    final c = signedController(api);
    addTearDown(c.dispose);
    c.links = List.of(api.fakeLinks);
    final old = c.sendFamilyMessage(link: c.links.single, content: 'same');
    await api.firstStarted.future;
    await c.logout();
    expect(await c.login(email: 'new@example.com', password: 'pw'), true);
    final newer = c.sendFamilyMessage(link: c.links.single, content: 'same');
    await api.secondStarted.future;
    api.first.completeError(const ApiException('old failure'));
    expect(await old, false);
    final duplicate =
        await c.sendFamilyMessage(link: c.links.single, content: 'same');
    api.second.complete(const FamilyMessage(
        id: 'new', senderId: 'elder-1', recipientId: 'care', content: 'same'));
    await newer;
    expect(duplicate, false);
    expect(api.calls, 2);
  });
  test('unsupported deletion is disabled', () async {
    final c = signedController(FakeApi());
    addTearDown(c.dispose);
    final dynamic d = c;
    expect(d.supportsMemoryControls, false);
    expect(await d.prepareMemoryDeletion(mode: 'all'), isNull);
  });
}

class DelayedMemoryApi extends FakeApi {
  final started = Completer<void>();
  final release = Completer<List<MemoryRecord>>();
  @override
  Future<List<MemoryRecord>> listMemories() {
    started.complete();
    return release.future;
  }

  @override
  Future<MemoryRecord> updateMemory(String id,
          {String? content, bool? suppressed}) async =>
      MemoryRecord.fromJson(
          {'id': id, 'content': content, 'status': 'confirmed'});
}

class UnadvancedReceiptApi extends FakeApi implements MemoryControlApi {
  @override
  Future<MemoryControlState> getMemoryControlState() async =>
      MemoryControlState.fromJson(state(3));
  @override
  Future<MemoryDeletionReceipt> deleteMemories(
          {required String mode,
          List<String> memoryIds = const [],
          required int expectedRevision,
          required String idempotencyKey}) async =>
      const MemoryDeletionReceipt(
          requestId: 'invalid', revision: 3, counts: {});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DelayedErrorChatApi extends FakeApi {
  final started = Completer<void>();
  final release = Completer<SendMessageResult>();
  @override
  Future<SendMessageResult> sendMessage(
      {required String conversationId,
      required String content,
      required String clientMessageId}) {
    started.complete();
    return release.future;
  }
}

class DelayedActionsApi extends UnadvancedReceiptApi {
  final started = Completer<void>();
  final release = Completer<List<ActionProposal>>();
  @override
  Future<List<ActionProposal>> listActions(String id) {
    started.complete();
    return release.future;
  }

  @override
  Future<MemoryDeletionReceipt> deleteMemories(
          {required String mode,
          List<String> memoryIds = const [],
          required int expectedRevision,
          required String idempotencyKey}) async =>
      const MemoryDeletionReceipt(
          requestId: 'deleted', revision: 4, counts: {});
}

class DelayedFamilyBusyApi extends FakeApi {
  final firstStarted = Completer<void>();
  final secondStarted = Completer<void>();
  final first = Completer<FamilyMessage>();
  final second = Completer<FamilyMessage>();
  int calls = 0;
  @override
  Future<FamilyMessage> sendFamilyMessage(
      {required String recipientId,
      required String content,
      required String clientMessageId,
      String? sourceStoryId}) {
    calls++;
    if (calls == 1) {
      firstStarted.complete();
      return first.future;
    }
    if (calls == 2) {
      secondStarted.complete();
      return second.future;
    }
    return Future.value(FamilyMessage(
        id: 'duplicate',
        senderId: 'elder-1',
        recipientId: recipientId,
        content: content));
  }
}
