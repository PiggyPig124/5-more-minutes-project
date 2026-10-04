import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _runLive =
    bool.fromEnvironment('RUN_LIVE_API_TESTS', defaultValue: false);
const _liveOrigin =
    String.fromEnvironment('API_ORIGIN', defaultValue: 'http://127.0.0.1:8013');

void main() {
  test(
      'live foundation client contract: invite, private chat, action and revoke',
      () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final elderEmail = 'elder-$suffix@example.com';
    final caregiverEmail = 'caregiver-$suffix@example.com';
    final elder = RestApiClient(origin: _liveOrigin);
    final caregiver = RestApiClient(origin: _liveOrigin);

    final elderSession = await elder.register(
      email: elderEmail,
      password: 'password123',
      displayName: '測試長者',
      role: UserRole.elder,
    );
    await caregiver.register(
      email: caregiverEmail,
      password: 'password123',
      displayName: '測試照顧者',
      role: UserRole.caregiver,
    );
    expect(elderSession.user.role, UserRole.elder);

    final invitation = await elder.createInvitation(email: caregiverEmail);
    expect(invitation.token, isNotEmpty);
    final link = await caregiver.acceptInvitation(
      invitationId: invitation.id,
      token: invitation.token!,
    );
    expect(link.status, InvitationStatus.accepted);

    final conversation = await elder.createConversation(title: '測試對話');
    final result = await elder.sendMessage(
      conversationId: conversation.id,
      content: '我今日有點孤單，請提醒我星期五覆診',
      clientMessageId: 'client-$suffix',
    );
    expect(result.assistantMessage, isNotNull);
    expect(result.demoMode, isTrue);
    expect(result.action, isNotNull);

    final privateMessages = await elder.listMessages(conversation.id);
    expect(privateMessages, hasLength(greaterThanOrEqualTo(2)));
    expect(() => caregiver.listMessages(conversation.id),
        throwsA(isA<ApiException>()));

    final task = await elder.confirmAction(
        actionId: result.action!.id, clientActionId: 'action-$suffix');
    expect(task, isNotNull);
    expect((await caregiver.listTasks()).any((item) => item.id == task!.id),
        isFalse);
    final preview = await elder.getTaskDetail(task!.id);
    expect(preview.contentHash, isNotEmpty);
    final share = await elder.createTaskShare(
      taskId: preview.id,
      familyLinkId: link.id,
      expectedContentHash: preview.contentHash!,
      idempotencyKey: 'share-$suffix',
    );
    expect(share.taskId, preview.id);
    final sharedTask = (await caregiver.listTasks())
        .singleWhere((item) => item.id == preview.id);
    expect(sharedTask.isReadOnly, isTrue);
    expect(sharedTask.shareId, share.id);
    expect(
      () => caregiver.updateTask(
          taskId: preview.id, status: TaskStatus.completed),
      throwsA(isA<ApiException>()),
    );

    await elder.revokeLink(linkId: link.id);
    expect((await caregiver.listTasks()).any((item) => item.id == task.id),
        isFalse);
  },
      skip:
          !_runLive ? 'Run with --dart-define=RUN_LIVE_API_TESTS=true' : false);

  test('live personal data and scoped family message contract', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final elder = RestApiClient(origin: _liveOrigin);
    final caregiver = RestApiClient(origin: _liveOrigin);
    final elderEmail = 'memory-elder-$suffix@example.com';
    final caregiverEmail = 'memory-caregiver-$suffix@example.com';
    await elder.register(
        email: elderEmail,
        password: 'password123',
        displayName: '資料長者',
        role: UserRole.elder);
    await caregiver.register(
        email: caregiverEmail,
        password: 'password123',
        displayName: '資料照顧者',
        role: UserRole.caregiver);

    final invitation = await elder.createInvitation(
        email: caregiverEmail, scopes: const ['care_tasks', 'family_messages']);
    final link = await caregiver.acceptInvitation(
        invitationId: invitation.id, token: invitation.token!);
    expect(link.allowsFamilyMessages, isTrue);

    final sourceConversation = await elder.createConversation(title: '記憶來源');
    final sourceReply = await elder.sendMessage(
        conversationId: sourceConversation.id,
        content: '我喜歡飲茶',
        clientMessageId: 'source-chat-$suffix');
    expect(sourceReply.userMessage, isNotNull);
    final consentSnapshot = await elder.getMemoryControlState();
    await elder.setMemoryConsentAtRevision(true,
        expectedRevision: consentSnapshot.revision);
    final createSnapshot = await elder.getMemoryControlState();
    final candidate = await elder.createMemoryAtRevision(
        expectedRevision: createSnapshot.revision,
        content: '我喜歡飲茶',
        kind: 'preference',
        sourceMessageId: sourceReply.userMessage!.id);
    expect(candidate.id, isNotEmpty);
    final confirmSnapshot = await elder.getMemoryControlState();
    final confirmed = await elder.confirmMemoryAtRevision(candidate.id,
        expectedRevision: confirmSnapshot.revision);
    expect(confirmed.id, isNotEmpty);
    final storySnapshot = await elder.getMemoryControlState();
    final story = await elder.createStoryAtRevision(
        expectedRevision: storySnapshot.revision,
        title: '我的小習慣',
        content: '我喜歡飲茶',
        memoryIds: [confirmed.id]);
    expect(story.id, isNotEmpty);

    final resources = await caregiver.searchResources(query: '長者服務', limit: 3);
    expect(resources.query, '長者服務');
    final shareSnapshot = await elder.getMemoryControlState();
    final message = await elder.sendFamilyMessageAtRevision(
      familyLinkId: link.id,
      expectedAuthorizationEpoch: link.authorizationEpoch!,
      expectedRevision: shareSnapshot.revision,
      recipientId: link.caregiverId ?? caregiverSessionId(link),
      content: '${story.title}\n${story.content}',
      clientMessageId: 'family-$suffix',
      sourceStoryId: story.id,
    );
    expect(message.sourceStoryId, story.id);
    expect(
        (await caregiver.listFamilyMessages())
            .any((item) => item.id == message.id),
        isTrue);
    expect(resources.retrievalMode, isNotNull);

    final deleteStorySnapshot = await elder.getMemoryControlState();
    await elder.deleteStoryAtRevision(story.id,
        expectedRevision: deleteStorySnapshot.revision);
    final deleteMemorySnapshot = await elder.getMemoryControlState();
    await elder.deleteMemoryAtRevision(confirmed.id,
        expectedRevision: deleteMemorySnapshot.revision,
        idempotencyKey: 'delete-memory-$suffix');
    await elder.revokeLink(linkId: link.id);
  },
      skip:
          !_runLive ? 'Run with --dart-define=RUN_LIVE_API_TESTS=true' : false);
}

String caregiverSessionId(FamilyInvitation link) => link.caregiverId ?? link.id;
