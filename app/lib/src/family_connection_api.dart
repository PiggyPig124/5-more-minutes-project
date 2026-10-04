import 'models.dart';
export 'family_connection_models.dart';

/// Optional capability: existing AnxinApi implementations remain compatible.
abstract interface class FamilyConnectionApi {
  Future<List<FamilyConnectionRequest>> listConnectionRequests();
  Future<FamilyConnectionRequest> createConnectionRequest(
      {required String elderEmail, required String clientRequestId});
  Future<FamilyInvitation> approveConnectionRequest(
      {required String requestId,
      required int expectedVersion,
      required List<String> scopes});
  Future<FamilyConnectionRequest> rejectConnectionRequest(
      {required String requestId, required int expectedVersion});
  Future<FamilyConnectionRequest> withdrawConnectionRequest(
      {required String requestId, required int expectedVersion});
  Future<List<FamilyBlock>> listFamilyBlocks();
  Future<FamilyBlock> blockFamilyPair(
      {required String caregiverId,
      String? requestId,
      String? linkId,
      required String clientOperationId});
  Future<FamilyBlock> unblockFamilyPair(
      {required String caregiverId,
      required int expectedVersion,
      required String clientOperationId});
  Future<List<FamilyMessage>> listSentFamilyMessages();
}

/// Sends exactly the authorization captured when the sender viewed a preview.
abstract interface class FamilyMessagePreviewApi {
  Future<FamilyMessage> sendFamilyMessageForPreview({
    required String recipientId,
    required String content,
    required String clientMessageId,
    required String familyLinkId,
    required int expectedAuthorizationEpoch,
    String? sourceStoryId,
    int? expectedRevision,
  });
}

/// Optional binding for the family authorization captured by the help preview.
abstract interface class FamilySupportPreviewApi {
  Future<void> sendSupportRequestForPreview({
    required String emergencyContactId,
    required String message,
    required String idempotencyKey,
    required String familyLinkId,
    required int expectedAuthorizationEpoch,
    String? safetyEventId,
  });
}
