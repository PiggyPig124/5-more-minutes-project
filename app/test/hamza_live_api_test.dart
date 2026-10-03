import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/care_models.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _run = bool.fromEnvironment('RUN_LIVE_API_TESTS');
const _origin =
    String.fromEnvironment('API_ORIGIN', defaultValue: 'http://127.0.0.1:8027');

void main() {
  test('live merged care, catalog, scam and safety contracts', () async {
    final api = RestApiClient(origin: _origin);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    await api.register(
        email: 'merge-$suffix@example.test',
        password: 'password123',
        displayName: 'Integration',
        role: UserRole.elder);
    expect(await api.listNotifications(), isEmpty);
    final saved = await api.saveCheckInSchedule(const CheckInSchedule(
        enabled: true, taskReminders: true, familyReplies: true));
    expect(saved.taskReminders, isTrue);
    expect((await api.getCheckInSchedule())!.familyReplies, isTrue);
    await api.skipCheckInToday();
    expect((await api.getCheckInSchedule())!.skipDate, isNotNull);
    expect((await api.triggerCheckIn()).triggered, isFalse);
    final activities = await api.listCatalogActivities();
    expect(activities, isNotEmpty);
    expect(activities.first.verified, isFalse);
    await api.expressCommunityInterest(activities.first.id);
    expect((await api.listCommunityInterests()).single.id, activities.first.id);
    await api.withdrawCommunityInterest(activities.first.id);
    expect(await api.listCommunityInterests(), isEmpty);
    expect(await api.catalogRecommendations(), isNotEmpty);
    final resources = await api.listScamResources();
    expect(resources, isNotEmpty);
    expect(await api.getVerifyActions(), hasLength(3));
    expect(await api.getScamContacts(), isNotEmpty);
    await api.logScamGuidance(
        scamType: 'general',
        guidanceSummary: 'Reviewed',
        scamResourceId: resources.first.id);
    expect(await api.listScamLogs(), hasLength(1));
    final conversation = await api.createConversation(title: 'Safety test');
    final reply = await api.sendMessage(
        conversationId: conversation.id,
        content: 'I want to die',
        clientMessageId: 'risk-$suffix');
    expect(reply.assistantMessage!.metadata['mode'], 'safety_intervention');
    final events = await api.listSafetyEvents();
    expect(events, hasLength(1));
    expect(events.single.triggerMessageId, reply.userMessage!.id);
    expect(events.single.supportRequestSent, isFalse);
    expect(await api.listEmergencyContacts(), isEmpty);
  }, skip: !_run ? 'Run with --dart-define=RUN_LIVE_API_TESTS=true' : false);
}
