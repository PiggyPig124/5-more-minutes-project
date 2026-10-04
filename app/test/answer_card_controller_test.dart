import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/answer_card_controller.dart';

const hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const scope =
    'AI answer is not independently verified. Sources are references only.';
CardPublicPayload payload(
        {String title = 'Answer card',
        List<String> text = const ['Safe guidance'],
        String state = 'no_verified_source'}) =>
    CardPublicPayload(
        title: title,
        selectedSections: text,
        officialTerms: const [],
        missingInformation: const [],
        nextSteps: const [],
        publicSources: const [],
        verificationState: state,
        verificationScope: scope);
AnswerCardDraftSnapshot snapshot([String id = 'message']) =>
    AnswerCardDraftSnapshot(
        sourceMessageId: id,
        sourceHash: hash,
        originalText: 'Safe guidance\n\nPrivate income',
        sections: [
          AnswerCardSection(id: 's1', text: 'Safe guidance'),
          AnswerCardSection(id: 's2', text: 'Private income')
        ],
        publicSources: const []);
OwnedAnswerCard owned(
        {String id = 'card',
        int version = 1,
        CardPublicPayload? body,
        Map<String, Object?>? provenance}) =>
    OwnedAnswerCard(
        id: id,
        mode: 'assistant_answer',
        version: version,
        publicPayload: body ?? payload(),
        publicPayloadHash: hash,
        provenance: provenance ??
            {
              'origin_message_id': 'message',
              'origin_hash': hash,
              'template_id': null,
              'template_version': null,
              'template_hash': null,
              'selected_original_excerpts': [
                {'id': 's1', 'hash': hash, 'edited': false}
              ]
            },
        createdAt: '2026-10-03T00:00:00Z',
        updatedAt: '2026-10-03T00:00:00Z');

class CardsApi implements AnswerCardApi {
  int writes = 0, reads = 0, prepares = 0;
  final requests = <Map<String, Object?>>[];
  Completer<List<OwnedAnswerCard>>? delayedList;
  Completer<OwnedAnswerCard>? delayedWrite;
  Completer<AnswerCardDraftSnapshot>? delayedPrepare;
  Object? writeError;
  OwnedAnswerCard? response;
  AnswerCardDeleteReceipt? deleteResponse;
  List<OwnedAnswerCard>? listResponse;
  @override
  Future<List<AnswerCardTemplate>> listAnswerCardTemplates() async => [];
  @override
  Future<AnswerCardDraftSnapshot> prepareAnswerCard(String id) async {
    prepares++;
    if (delayedPrepare != null) return await delayedPrepare!.future;
    return snapshot(id);
  }

  @override
  Future<List<OwnedAnswerCard>> listAnswerCards() async {
    reads++;
    if (delayedList != null) return await delayedList!.future;
    return listResponse ?? [owned()];
  }

  Future<OwnedAnswerCard> write(Map<String, Object?> request,
      {int version = 1}) async {
    writes++;
    requests.add(request);
    if (writeError != null) throw writeError!;
    if (delayedWrite != null) return delayedWrite!.future;
    return response ??
        owned(
            version: version,
            body: payload(
                title: request['title'] as String,
                text: (request['selected_sections'] as List)
                    .map((s) => s is String
                        ? s
                        : ((s as Map)['edited_text'] ?? 'Safe guidance')
                            as String)
                    .toList()),
            provenance: {
              ...owned().provenance,
              'selected_original_excerpts': [
                {
                  'id': 's1',
                  'hash': hash,
                  'edited': version > 1 ||
                      ((request['selected_sections'] as List).first as Map)
                          .containsKey('edited_text')
                }
              ]
            });
  }

  @override
  Future<OwnedAnswerCard> createAnswerCard(Map<String, Object?> request) =>
      write(request);
  @override
  Future<OwnedAnswerCard> updateAnswerCard(
          String id, Map<String, Object?> request) =>
      write(request, version: (request['expected_version'] as int) + 1);
  @override
  Future<AnswerCardDeleteReceipt> deleteAnswerCard(
      {required String cardId,
      required int expectedVersion,
      required String clientOperationId}) async {
    writes++;
    requests.add({
      'client_operation_id': clientOperationId,
      'expected_version': expectedVersion
    });
    if (writeError != null) throw writeError!;
    return deleteResponse ??
        AnswerCardDeleteReceipt(
            id: cardId, version: expectedVersion + 1, deleted: true);
  }
}

void main() {
  late CardsApi api;
  late AnswerCardController c;
  setUp(() {
    api = CardsApi();
    c = AnswerCardController(api: api);
    c.bindSession(ownerId: 'owner', sessionIdentity: 'session');
  });
  tearDown(() => c.dispose());
  Future<void> ready() async {
    await c.prepareFromMessage('message');
    c.selectSection('s1', true);
    expect(c.reviewDraft(), isTrue);
  }

  test('AI defaults leave every section and display enrichment unselected',
      () async {
    await c.prepareFromMessage('message');
    expect(c.draft!.selectedSectionIds, isEmpty);
    expect(c.draft!.title, 'Answer card');
    expect(c.draft!.officialTerms, isEmpty);
    expect(c.draft!.nextSteps, isEmpty);
  });
  test('cancel and back make zero writes and discard original text', () async {
    await ready();
    c.editBack();
    expect(c.preview, isNull);
    c.cancelDraft();
    expect(c.draft, isNull);
    expect(api.writes, 0);
  });
  test('review and save retain only selected edited text', () async {
    await c.prepareFromMessage('message');
    c.selectSection('s1', true);
    c.editSection('s1', 'Redacted guidance');
    expect(c.reviewDraft(), isTrue);
    expect(c.preview!.selectedSections, ['Redacted guidance']);
    expect(await c.saveReviewedDraft(), isTrue);
    expect(api.requests.single['selected_sections'], [
      {'id': 's1', 'edited_text': 'Redacted guidance'}
    ]);
    expect(api.requests.single.toString(), isNot(contains('Private income')));
  });
  test('saving without full preview never writes', () async {
    await c.prepareFromMessage('message');
    c.selectSection('s1', true);
    expect(await c.saveReviewedDraft(), isFalse);
    expect(api.writes, 0);
  });
  test('changing a display field invalidates review', () async {
    await ready();
    c.setTitle('Changed');
    expect(c.preview, isNull);
    expect(await c.saveReviewedDraft(), isFalse);
    expect(api.writes, 0);
  });
  test(
      'stable session notifications retain draft but account switch clears RAM',
      () async {
    await ready();
    final old = c.draft;
    c.bindSession(ownerId: 'owner', sessionIdentity: 'session');
    expect(c.draft, same(old));
    c.bindSession(ownerId: 'other', sessionIdentity: 'new');
    expect(c.draft, isNull);
    expect(c.preview, isNull);
    expect(c.cards, isEmpty);
    expect(c.error, isNull);
    expect(c.busy, isFalse);
  });
  test('guest draft never accesses private APIs and login does not import it',
      () async {
    c.bindSession(ownerId: null, sessionIdentity: null, guestIdentity: 'guest');
    c.prepareGuestAnswer('One\n\nTwo');
    expect(c.draft!.selectedSectionIds, isEmpty);
    c.selectSection(c.draft!.sections.first.id, true);
    expect(c.reviewDraft(), isTrue);
    expect(c.preview!.verificationState, 'no_verified_source');
    expect(await c.loadCards(), isFalse);
    expect(await c.saveReviewedDraft(), isFalse);
    expect(api.prepares, 0);
    expect(api.reads, 0);
    expect(api.writes, 0);
    c.bindSession(ownerId: 'owner', sessionIdentity: 'login');
    expect(c.draft, isNull);
  });
  test('late prepare never replaces newer draft or a new account', () async {
    api.delayedPrepare = Completer();
    final pending = c.prepareFromMessage('message');
    c.prepareGuestAnswer('Guest rejected for owner');
    c.cancelDraft();
    api.delayedPrepare!.complete(snapshot());
    expect(await pending, isFalse);
    expect(c.draft, isNull);
  });
  test('timeout retains identical request and operation key for explicit retry',
      () async {
    await ready();
    api.writeError = TimeoutException('synthetic');
    expect(await c.saveReviewedDraft(), isFalse);
    expect(c.status, 'result_unconfirmed');
    api.writeError = null;
    expect(await c.saveReviewedDraft(), isTrue);
    expect(api.requests[0], api.requests[1]);
  });
  test('conflict never refreshes source or version and never auto retries',
      () async {
    await ready();
    api.writeError = const ApiException('conflict', statusCode: 409);
    expect(await c.saveReviewedDraft(), isFalse);
    expect(api.writes, 1);
    expect(api.prepares, 1);
    expect(api.reads, 0);
  });
  test('double click issues one mutation', () async {
    await ready();
    api.delayedWrite = Completer();
    final first = c.saveReviewedDraft();
    expect(await c.saveReviewedDraft(), isFalse);
    api.delayedWrite!.complete(owned());
    expect(await first, isTrue);
    expect(api.writes, 1);
  });
  test('late mutation cannot clear busy or insert card into new session',
      () async {
    await ready();
    api.delayedWrite = Completer();
    final pending = c.saveReviewedDraft();
    c.bindSession(ownerId: 'other', sessionIdentity: 'new');
    api.delayedWrite!.complete(owned());
    expect(await pending, isFalse);
    expect(c.cards, isEmpty);
    expect(c.error, isNull);
    expect(c.busy, isFalse);
  });
  test('old list cannot resurrect deleted card', () async {
    api.delayedList = Completer();
    final pending = c.loadCards();
    expect(await c.deleteCard(owned()), isTrue);
    api.delayedList!.complete([owned()]);
    expect(await pending, isFalse);
    expect(c.cards, isEmpty);
  });
  test('wrong card or wrong increment response cannot report edit success',
      () async {
    c.startEdit(owned());
    c.setTitle('Changed');
    c.reviewDraft();
    api.response =
        owned(id: 'foreign', version: 2, body: payload(title: 'Changed'));
    expect(await c.saveReviewedDraft(), isFalse);
    expect(c.cards, isEmpty);
  });
  test('wrong delete terminal version is rejected', () async {
    api.deleteResponse =
        AnswerCardDeleteReceipt(id: 'card', version: 1, deleted: true);
    expect(await c.deleteCard(owned()), isFalse);
    expect(c.status, isNot('deleted'));
  });
  test('oversized selected text rejects whole review without truncation',
      () async {
    await c.prepareFromMessage('message');
    c.selectSection('s1', true);
    c.editSection('s1', 'x' * 4001);
    expect(c.reviewDraft(), isFalse);
    expect(c.preview, isNull);
    expect(api.writes, 0);
  });
  test('template source dates and frozen origin survive selection and editing',
      () async {
    final source = AnswerCardSource(
        sourceId: 'official',
        organisation: 'Official',
        title: 'Guidance',
        url: 'https://www.swd.gov.hk/',
        verificationScope: 'Navigation only',
        reviewedAt: '2026-10-03',
        retrievedAt: null,
        effectiveDate: null,
        contentHash: hash);
    final base = CardPublicPayload(
        title: 'Public guidance',
        selectedSections: ['Public text'],
        officialTerms: ['Term'],
        missingInformation: ['Confirm eligibility'],
        nextSteps: ['Contact office'],
        publicSources: [source],
        verificationState: 'reviewed_public_guidance',
        verificationScope: 'Navigation only');
    c.startTemplate(AnswerCardTemplate(
        templateId: 'template',
        templateVersion: 3,
        templateHash: hash,
        language: 'zh-Hant',
        sections: [AnswerCardSection(id: 'public', text: 'Public text')],
        publicPayload: base));
    expect(c.draft!.selectedSectionIds, {'public'});
    expect(c.reviewDraft(), isTrue);
    expect(c.preview!.verificationState, 'reviewed_public_guidance');
    c.editSection('public', 'Edited text');
    expect(c.preview, isNull);
    expect(c.reviewDraft(), isTrue);
    expect(c.preview!.verificationState, 'user_edited_unverified');
    expect(c.preview!.publicSources.single.reviewedAt, '2026-10-03');
    c.selectSource('official', false);
    c.reviewDraft();
    expect(c.preview!.verificationState, 'no_verified_source');
  });
  test('wrong source provenance cannot report create success', () async {
    await ready();
    api.response = owned(provenance: {
      'origin_message_id': 'other',
      'origin_hash': hash,
      'template_id': null,
      'template_version': null,
      'template_hash': null,
      'selected_original_excerpts': [
        {'id': 's1', 'hash': hash, 'edited': false}
      ]
    });
    expect(await c.saveReviewedDraft(), isFalse);
    expect(c.cards, isEmpty);
  });
  test('old list cannot overwrite completed card edit', () async {
    api.delayedList = Completer();
    final pending = c.loadCards();
    c.startEdit(owned());
    c.setTitle('Updated');
    c.reviewDraft();
    api.response =
        owned(version: 2, body: payload(title: 'Updated'), provenance: {
      ...owned().provenance,
      'selected_original_excerpts': [
        {'id': 's1', 'hash': hash, 'edited': true}
      ]
    });
    expect(await c.saveReviewedDraft(), isTrue);
    api.delayedList!.complete([owned()]);
    expect(await pending, isFalse);
    expect(c.cards.single.version, 2);
  });
  test('delete timeout retains captured version and key on explicit retry',
      () async {
    api.writeError = TimeoutException('synthetic');
    expect(await c.deleteCard(owned()), isFalse);
    expect(c.status, 'result_unconfirmed');
    api.writeError = null;
    expect(await c.deleteCard(owned()), isTrue);
    expect(api.requests[0], api.requests[1]);
  });
  test(
      'cancelled pending prepare releases busy and never restores its raw answer',
      () async {
    api.delayedPrepare = Completer();
    final pending = c.prepareFromMessage('message');
    final epoch = c.draftGeneration;
    expect(c.busy, isTrue);
    c.cancelDraft(expectedDraftGeneration: epoch);
    expect(c.busy, isFalse);
    api.delayedPrepare!.complete(snapshot());
    expect(await pending, isFalse);
    expect(c.draft, isNull);
  });
  test('an old editor cancel token cannot erase a newly opened draft',
      () async {
    await c.prepareFromMessage('message');
    final old = c.draftGeneration;
    c.startEdit(owned());
    final current = c.draft;
    c.cancelDraft(expectedDraftGeneration: old);
    expect(c.draft, same(current));
  });
  test(
      'known delete conflict releases only after an explicit successful reload',
      () async {
    api.writeError = const ApiException('conflict', statusCode: 409);
    expect(await c.deleteCard(owned()), isFalse);
    c.startEdit(owned());
    expect(c.draft, isNull);
    api.writeError = null;
    api.listResponse = [owned(version: 2)];
    expect(await c.loadCards(), isTrue);
    c.startEdit(c.cards.single);
    expect(c.draft, isNotNull);
    c.cancelDraft();
    expect(await c.deleteCard(c.cards.single), isTrue);
    expect(api.requests.last['expected_version'], 2);
    expect(api.requests.first['client_operation_id'],
        isNot(api.requests.last['client_operation_id']));
  });
  test(
      'a reload cannot replace the captured version after an unknown delete outcome',
      () async {
    api.writeError = TimeoutException('synthetic');
    expect(await c.deleteCard(owned()), isFalse);
    api.writeError = null;
    api.listResponse = [owned(version: 2)];
    expect(await c.loadCards(), isTrue);
    expect(c.status, 'result_unconfirmed');
    expect(c.error, isNotNull);
    expect(await c.deleteCard(owned(version: 2)), isFalse);
    expect(api.writes, 1);
    c.startEdit(c.cards.single);
    expect(c.draft, isNull);
  });
  test(
      'reload preserves the exact unknown-delete card for a reachable same-key retry',
      () async {
    api.writeError = TimeoutException('synthetic');
    expect(await c.deleteCard(owned()), isFalse);
    api.writeError = null;
    api.listResponse = [
      owned(version: 2, body: payload(title: 'Newer body')),
      owned(id: 'other')
    ];
    expect(await c.loadCards(), isTrue);
    final captured = c.cards.singleWhere((card) => card.id == 'card');
    expect(captured.version, 1);
    expect(captured.publicPayload.title, 'Answer card');
    expect(c.cards.any((card) => card.id == 'other'), isTrue);
    expect(await c.deleteCard(captured), isTrue);
    expect(api.requests[0], api.requests[1]);
  });
  test('HTTP 500 create keeps the reviewed body and original key for retry',
      () async {
    await ready();
    final reviewed = c.preview!;
    api.writeError = const ApiException('Synthetic failure after commit', statusCode: 500);
    expect(await c.saveReviewedDraft(), isFalse);
    expect(c.status, 'result_unconfirmed');
    expect(c.busy, isFalse);
    expect(api.writes, 1);
    expect(api.reads, 0);
    expect(api.prepares, 1);
    final capturedRequest = jsonEncode(api.requests.single);
    c.setTitle('Unreviewed change');
    c.editSection('s1', 'Unreviewed replacement');
    c.selectSection('s1', false);
    c.setOfficialTerms(['Unreviewed term']);
    c.setMissingInformation(['Unreviewed information']);
    c.setNextSteps(['Unreviewed step']);
    c.editBack();
    expect(c.preview, same(reviewed));
    expect(c.draft!.title, reviewed.title);
    expect(c.draft!.selectedSectionIds, {'s1'});
    expect(c.draft!.officialTerms, isEmpty);
    expect(c.draft!.missingInformation, isEmpty);
    expect(c.draft!.nextSteps, isEmpty);
    api.writeError = null;
    expect(await c.saveReviewedDraft(), isTrue);
    expect(api.writes, 2);
    expect(api.requests[1], api.requests[0]);
    expect(jsonEncode(api.requests[1]), capturedRequest);
    expect(c.cards, hasLength(1));
    expect(c.cards.single.publicPayload.selectedSections, ['Safe guidance']);
  });
  test('HTTP 500 edit retries the reviewed body at its captured version', () async {
    c.startEdit(owned(version: 4));
    c.setTitle('Reviewed edit');
    expect(c.reviewDraft(), isTrue);
    final reviewed = c.preview!;
    api.writeError = const ApiException('Synthetic failure after commit', statusCode: 500);
    expect(await c.saveReviewedDraft(), isFalse);
    expect(c.status, 'result_unconfirmed');
    expect(api.writes, 1);
    expect(api.reads, 0);
    expect(api.prepares, 0);
    final capturedRequest = jsonEncode(api.requests.single);
    c.setTitle('Unreviewed edit');
    c.editSection('saved:0', 'Unreviewed replacement');
    c.selectSection('saved:0', false);
    c.setNextSteps(['Unreviewed step']);
    c.editBack();
    expect(c.preview, same(reviewed));
    expect(c.draft!.owned!.version, 4);
    expect(c.draft!.title, 'Reviewed edit');
    api.writeError = null;
    expect(await c.saveReviewedDraft(), isTrue);
    expect(api.requests[1], api.requests[0]);
    expect(jsonEncode(api.requests[1]), capturedRequest);
    expect(api.requests.first['expected_version'], 4);
    expect(c.cards.single.version, 5);
    expect(c.cards.single.publicPayload.title, 'Reviewed edit');
  });
  test('HTTP 500 delete keeps the original snapshot version and key for retry',
      () async {
    api.writeError = const ApiException('Synthetic failure after commit', statusCode: 500);
    expect(await c.deleteCard(owned(version: 4)), isFalse);
    expect(c.status, 'result_unconfirmed');
    expect(api.writes, 1);
    expect(api.reads, 0);
    api.writeError = null;
    api.listResponse = [owned(version: 5, body: payload(title: 'Newer body'))];
    expect(await c.loadCards(), isTrue);
    expect(c.status, 'result_unconfirmed');
    expect(c.cards.single.version, 4);
    c.startEdit(c.cards.single);
    expect(c.draft, isNull);
    expect(await c.deleteCard(owned(version: 5)), isFalse);
    expect(api.writes, 1);
    expect(await c.deleteCard(c.cards.single), isTrue);
    expect(api.requests[1], api.requests[0]);
    expect(api.requests.last['expected_version'], 4);
    expect(c.cards, isEmpty);
  });
  for (final status in [502, 503, 504, 599]) {
    test('HTTP $status is an unknown mutation result with explicit same-key retry', () async {
      await ready();
      api.writeError = ApiException('Synthetic server failure', statusCode: status);
      expect(await c.saveReviewedDraft(), isFalse);
      expect(c.status, 'result_unconfirmed');
      expect(api.writes, 1);
      expect(api.reads, 0);
      api.writeError = null;
      expect(await c.saveReviewedDraft(), isTrue);
      expect(api.requests[1], api.requests[0]);
    });
  }
}
