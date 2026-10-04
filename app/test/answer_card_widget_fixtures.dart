import 'dart:async';
import 'package:anxin_companion/src/answer_card_api.dart';

const widgetHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final widgetSnapshot = AnswerCardDraftSnapshot(
  sourceMessageId: 'synthetic-message',
  sourceHash: widgetHash,
  originalText: 'Synthetic safe guidance.\n\nSynthetic private diagnosis.',
  sections: [
    AnswerCardSection(id: 's0', text: 'Synthetic safe guidance.'),
    AnswerCardSection(id: 's1', text: 'Synthetic private diagnosis.')
  ],
  publicSources: const [],
);

OwnedAnswerCard widgetOwned({int version = 1, Map<String, Object?>? request}) {
  final sections =
      (request?['selected_sections'] as List?) ?? ['Synthetic safe guidance.'];
  return OwnedAnswerCard(
      id: 'synthetic-card',
      mode: 'assistant_answer',
      version: version,
      publicPayload: CardPublicPayload(
          title: request?['title'] as String? ?? 'Synthetic private card',
          selectedSections: sections
              .map((s) => s is String
                  ? s
                  : ((s as Map)['edited_text'] as String? ??
                      'Synthetic safe guidance.'))
              .toList(),
          officialTerms:
              List<String>.from(request?['official_terms'] as List? ?? []),
          missingInformation:
              List<String>.from(request?['missing_information'] as List? ?? []),
          nextSteps: List<String>.from(request?['next_steps'] as List? ?? []),
          publicSources: const [],
          verificationState: 'no_verified_source',
          verificationScope:
              'AI answer is not independently verified. Sources are references only.'),
      publicPayloadHash: widgetHash,
      provenance: {
        'origin_message_id': 'synthetic-message',
        'origin_hash': widgetHash,
        'template_id': null,
        'template_version': null,
        'template_hash': null,
        'selected_original_excerpts': [
          {
            'id': 's0',
            'hash': widgetHash,
            'edited': version > 1 ||
                (sections.first is Map &&
                    (sections.first as Map).containsKey('edited_text'))
          }
        ]
      },
      createdAt: '2026-10-03T00:00:00Z',
      updatedAt: '2026-10-03T00:00:00Z');
}

class WidgetCardsApi implements AnswerCardApi {
  final requests = <Map<String, Object?>>[];
  int writes = 0;
  List<OwnedAnswerCard> stored = [];
  Completer<OwnedAnswerCard>? delayedSave;
  Completer<AnswerCardDraftSnapshot>? delayedPrepare;
  @override
  Future<List<AnswerCardTemplate>> listAnswerCardTemplates() async =>
      [widgetTemplate];
  @override
  Future<AnswerCardDraftSnapshot> prepareAnswerCard(String id) async {
    if (delayedPrepare != null) return await delayedPrepare!.future;
    return widgetSnapshot;
  }

  @override
  Future<List<OwnedAnswerCard>> listAnswerCards() async => List.of(stored);
  @override
  Future<OwnedAnswerCard> createAnswerCard(Map<String, Object?> request) async {
    writes++;
    requests.add(request);
    final card = delayedSave == null
        ? widgetOwned(request: request)
        : await delayedSave!.future;
    stored = [card];
    return card;
  }

  @override
  Future<OwnedAnswerCard> updateAnswerCard(
      String id, Map<String, Object?> request) async {
    writes++;
    requests.add(request);
    final card = widgetOwned(
        version: (request['expected_version'] as int) + 1, request: request);
    stored = [card];
    return card;
  }

  @override
  Future<AnswerCardDeleteReceipt> deleteAnswerCard(
      {required String cardId,
      required int expectedVersion,
      required String clientOperationId}) async {
    writes++;
    requests.add({
      'expected_version': expectedVersion,
      'client_operation_id': clientOperationId
    });
    stored = [];
    return AnswerCardDeleteReceipt(
        id: cardId, version: expectedVersion + 1, deleted: true);
  }
}

final widgetTemplate = AnswerCardTemplate(
  templateId: 'synthetic-template',
  templateVersion: 1,
  templateHash: 'a' * 64,
  language: 'zh',
  sections: [AnswerCardSection(id: 'public-0', text: '公共指引 😀')],
  publicPayload: CardPublicPayload(
    title: '公共範本',
    selectedSections: ['公共指引 😀'],
    officialTerms: ['Official synthetic term'],
    missingInformation: ['Confirm availability'],
    nextSteps: ['Ask the agency'],
    publicSources: [
      AnswerCardSource(
        sourceId: 'synthetic-source',
        organisation: 'Synthetic agency',
        title: 'Synthetic guidance',
        url: 'https://www.swd.gov.hk/${'synthetic-path/' * 30}',
        reviewedAt: '2026-10-03',
        verificationScope: 'Public guidance only',
      )
    ],
    verificationState: 'reviewed_public_guidance',
    verificationScope: 'Public guidance only',
  ),
);
