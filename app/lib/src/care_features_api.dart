import 'care_models.dart';

/// Optional server features, kept separate so existing AnxinApi fakes work.
abstract class CareFeaturesApi {
  Future<CheckInSchedule?> getCheckInSchedule();
  Future<CheckInSchedule> saveCheckInSchedule(CheckInSchedule schedule);
  Future<void> skipCheckInToday();
  Future<CheckInTriggerResult> triggerCheckIn();
  Future<List<CareNotification>> listNotifications();
  Future<CareNotification> updateNotification({
    required String notificationId,
    required CareNotificationAction status,
  });
  Future<List<EmergencyContact>> listEmergencyContacts();
  Future<EmergencyContact> addEmergencyContact({
    required String familyLinkId,
    required String label,
  });
  Future<void> deleteEmergencyContact(String contactId);
  Future<List<SafetyEvent>> listSafetyEvents();
  Future<void> sendSupportRequest({
    required String emergencyContactId,
    required String message,
    required String idempotencyKey,
    String? safetyEventId,
  });
}
