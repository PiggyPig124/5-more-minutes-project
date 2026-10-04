import 'dart:async';
import 'package:anxin_companion/src/answer_card_sharing_api.dart';
import 'package:anxin_companion/src/models.dart';

const sharingWidgetHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const sharingFirstRecipient = FamilyInvitation(
  id: 'synthetic-link-a', email: 'first@example.test', name: 'Same name',
  status: InvitationStatus.accepted, elderId: 'synthetic-sender',
  caregiverId: 'synthetic-recipient-a', caregiverName: 'Same name',
  caregiverEmail: 'first@example.test', authorizationEpoch: 3,
  scopes: ['family_messages'],
);
const sharingSecondRecipient = FamilyInvitation(
  id: 'synthetic-link-b', email: 'second@example.test', name: 'Same name',
  status: InvitationStatus.accepted, elderId: 'synthetic-sender',
  caregiverId: 'synthetic-recipient-b', caregiverName: 'Same name',
  caregiverEmail: 'second@example.test', authorizationEpoch: 4,
  scopes: ['family_messages'],
);
final sharingWidgetCard = OwnedAnswerCard(
  id: 'synthetic-card', version: 2, mode: 'assistant_answer',
  publicPayloadHash: sharingWidgetHash,
  publicPayload: CardPublicPayload(
    title: 'Selected card 😀', selectedSections: ['Selected public guidance.'],
    officialTerms: ['Synthetic official term'], missingInformation: ['Confirm availability'],
    nextSteps: ['Ask the agency'], publicSources: [],
    verificationState: 'no_verified_source', verificationScope: 'AI answer; sources do not verify all conclusions.',
  ),
  provenance: {'origin_message_id': 'private-source-id', 'origin_hash': sharingWidgetHash,
    'template_id': null, 'template_version': null, 'template_hash': null,
    'selected_original_excerpts': [{'id': 'synthetic-section', 'hash': sharingWidgetHash, 'edited': false}]},
  createdAt: '2026-10-03T00:00:00Z', updatedAt: '2026-10-03T00:00:00Z',
);
final sharingLongCard = OwnedAnswerCard(
  id: 'synthetic-public-card', version: 1, mode: 'public_template',
  publicPayloadHash: sharingWidgetHash,
  publicPayload: CardPublicPayload(
    title: '公共指引 😀', selectedSections: ['繁體中文 😀 ${'Public guidance. ' * 40}'],
    officialTerms: ['Synthetic official term'], missingInformation: ['Confirm availability'],
    nextSteps: ['Ask the agency'], publicSources: [AnswerCardSource(
      sourceId: 'synthetic-public-source', organisation: 'Synthetic agency',
      title: 'Synthetic reference', url: 'https://www.swd.gov.hk/${'synthetic-path/' * 30}',
      reviewedAt: '2026-10-03', verificationScope: 'Public guidance only',
    )], verificationState: 'reviewed_public_guidance', verificationScope: 'Public guidance only',
  ), provenance: {'template_id': 'synthetic-template', 'template_version': 1,
    'template_hash': sharingWidgetHash, 'origin_message_id': null, 'origin_hash': null,
    'selected_original_excerpts': [{'id': 'synthetic-section', 'hash': sharingWidgetHash, 'edited': false}]},
  createdAt: '2026-10-03T00:00:00Z', updatedAt: '2026-10-03T00:00:00Z',
);

AnswerCardShare sharingWidgetShare({OwnedAnswerCard? card, String recipientId = 'synthetic-recipient-a',
  String linkId = 'synthetic-link-a', int linkEpoch = 3}) {
  final source = card ?? sharingWidgetCard;
  return AnswerCardShare(id: 'synthetic-share', mode: source.mode, cardVersion: source.version,
    senderId: 'synthetic-sender', recipientId: recipientId, linkId: linkId, linkEpoch: linkEpoch,
    publicPayload: source.publicPayload, publicPayloadHash: source.publicPayloadHash,
    createdAt: '2026-10-04T00:00:00Z');
}
AnswerCardSentShare sharingWidgetSent({bool revoked = false, String id = 'synthetic-share', String? cardId}) => AnswerCardSentShare(
  id: id, cardId: cardId ?? sharingWidgetCard.id, mode: sharingWidgetCard.mode,
  cardVersion: sharingWidgetCard.version, senderId: 'synthetic-sender',
  recipientId: 'synthetic-recipient-a', linkId: 'synthetic-link-a', linkEpoch: 3,
  publicPayload: revoked ? null : sharingWidgetCard.publicPayload,
  publicPayloadHash: sharingWidgetHash, createdAt: '2026-10-04T00:00:00Z',
  accessRevokedAt: revoked ? '2026-10-04T01:00:00Z' : null,
  accessRevocationReason: revoked ? 'card_deleted' : null,
);

class SharingWidgetApi implements AnswerCardSharingApi {
  OwnedAnswerCard expectedCard = sharingWidgetCard;
  final requests = <Map<String, Object?>>[];
  int shares = 0, revokes = 0;
  Object? shareError;
  Object? revokeError;
  final revokedIds = <String>[];
  Completer<AnswerCardShare>? delayedShare;
  Completer<List<AnswerCardShare>>? delayedInbox;
  List<AnswerCardShare> inbox = [sharingWidgetShare()];
  List<AnswerCardSentShare> sent = [sharingWidgetSent()];
  @override
  Future<AnswerCardShare> shareAnswerCard(String cardId, Map<String, Object?> request) async {
    shares++; requests.add(Map.of(request));
    if (shareError != null) throw shareError!;
    if (delayedShare != null) return await delayedShare!.future;
    return sharingWidgetShare(card: expectedCard,
      recipientId: request['recipient_id'] as String,
      linkId: request['expected_link_id'] as String,
      linkEpoch: request['expected_link_epoch'] as int);
  }
  @override
  Future<List<AnswerCardShare>> listAnswerCardInbox() async {
    if (delayedInbox != null) return await delayedInbox!.future;
    return List.of(inbox);
  }
  @override
  Future<List<AnswerCardSentShare>> listSentAnswerCardShares() async => List.of(sent);
  @override
  Future<AnswerCardShareRevokeReceipt> revokeAnswerCardShare(String shareId) async {
    revokes++; revokedIds.add(shareId);
    if (revokeError != null) throw revokeError!;
    sent = [sharingWidgetSent(revoked: true)];
    return AnswerCardShareRevokeReceipt(id: shareId, revoked: true);
  }
}
