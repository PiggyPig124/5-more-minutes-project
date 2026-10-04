enum FamilyRequestStatus {
  pending,
  approved,
  rejected,
  revoked,
  expired,
  unknown;

  static FamilyRequestStatus fromJson(Object? value) {
    switch (value) {
      case 'pending':
        return FamilyRequestStatus.pending;
      case 'approved':
        return FamilyRequestStatus.approved;
      case 'rejected':
        return FamilyRequestStatus.rejected;
      case 'revoked':
        return FamilyRequestStatus.revoked;
      case 'expired':
        return FamilyRequestStatus.expired;
      default:
        return FamilyRequestStatus.unknown;
    }
  }
}

class FamilyConnectionRequest {
  const FamilyConnectionRequest(
      {required this.id,
      required this.elderId,
      required this.caregiverId,
      required this.elderEmail,
      required this.status,
      this.version,
      this.createdAt,
      this.expiresAt,
      this.decidedAt,
      this.requesterName,
      this.requesterEmail});
  final String id, elderId, caregiverId, elderEmail;
  final FamilyRequestStatus status;
  final int? version;
  final DateTime? createdAt, expiresAt, decidedAt;
  final String? requesterName, requesterEmail;
  bool get actionable =>
      id.trim().isNotEmpty &&
      elderId.trim().isNotEmpty &&
      caregiverId.trim().isNotEmpty &&
      version != null &&
      version! >= 1 &&
      status == FamilyRequestStatus.pending &&
      expiresAt != null &&
      expiresAt!.isAfter(DateTime.now());
  factory FamilyConnectionRequest.fromJson(Map<String, dynamic> json) =>
      FamilyConnectionRequest(
          id: _text(json['id']) ?? '',
          elderId: _text(json['elder_id']) ?? '',
          caregiverId: _text(json['caregiver_id']) ?? '',
          elderEmail: _text(json['elder_email']) ?? '',
          status: FamilyRequestStatus.fromJson(json['status']),
          version: _integer(json['version']),
          createdAt: _date(json['created_at']),
          expiresAt: _date(json['expires_at']),
          decidedAt: _date(json['decided_at']),
          requesterName: _text(json['requester_name']),
          requesterEmail: _text(json['requester_email']));
}

class FamilyBlock {
  const FamilyBlock(
      {required this.elderId,
      required this.caregiverId,
      this.active,
      this.version,
      this.blockedAt,
      this.caregiverName,
      this.caregiverEmail,
      this.operationId,
      this.operationType});
  final String elderId, caregiverId;
  final bool? active;
  final int? version;
  final DateTime? blockedAt;
  final String? caregiverName, caregiverEmail, operationId, operationType;
  bool get actionable =>
      elderId.trim().isNotEmpty &&
      caregiverId.trim().isNotEmpty &&
      active != null &&
      version != null &&
      version! >= 1;
  factory FamilyBlock.fromJson(Map<String, dynamic> json) => FamilyBlock(
      elderId: _text(json['elder_id']) ?? '',
      caregiverId: _text(json['caregiver_id']) ?? '',
      active: json['active'] is bool ? json['active'] as bool : null,
      version: _integer(json['version']),
      blockedAt: _date(json['blocked_at']),
      caregiverName: _text(json['caregiver_name']),
      caregiverEmail: _text(json['caregiver_email']),
      operationId: _text(json['operation_id']),
      operationType: _text(json['operation_type']));
}

String? _text(Object? value) => value is String ? value : null;
int? _integer(Object? value) => value is int ? value : null;
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
