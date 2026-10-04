import 'answer_card_models.dart';

abstract interface class AnswerCardExportApi {
  Future<AnswerCardExportSnapshot> getAnswerCardExportPreview(String cardId, {
    required int expectedVersion, required String previewedPayloadHash,
    required bool personalReviewAck,
  });
}

class AnswerCardExportSnapshot {
  const AnswerCardExportSnapshot({required this.cardVersion,
    required this.publicPayload, required this.publicPayloadHash});
  final int cardVersion;
  final CardPublicPayload publicPayload;
  final String publicPayloadHash;
  factory AnswerCardExportSnapshot.fromJson(Object? raw) {
    if (raw is! Map || raw.length != 3 ||
        !raw.keys.toSet().containsAll(['card_version','public_payload','public_payload_hash']) ||
        raw['card_version'] is! int || (raw['card_version'] as int) < 1 ||
        raw['public_payload_hash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['public_payload_hash'] as String)) {
      throw const FormatException('Invalid export preview');
    }
    return AnswerCardExportSnapshot(cardVersion:raw['card_version'] as int,
      publicPayload:CardPublicPayload.fromJson(raw['public_payload']),
      publicPayloadHash:raw['public_payload_hash'] as String);
  }
}
