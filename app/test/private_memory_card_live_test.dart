import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _runLive =
    bool.fromEnvironment('RUN_LIVE_API_TESTS', defaultValue: false);
const _origin =
    String.fromEnvironment('API_ORIGIN', defaultValue: 'http://127.0.0.1:8013');

void main() {
  test(
      'live private card edit withdraws old share and requires fresh preview and key',
      () async {
    final origin = Uri.parse(_origin);
    expect(origin.scheme, 'http');
    expect(origin.host, anyOf('127.0.0.1', 'localhost', '::1'),
        reason:
            'Only the root-owned synthetic localhost backend is authorized');
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final owner = RestApiClient(origin: _origin);
    final recipient = RestApiClient(origin: _origin);
    final recipientEmail = 'private-card-recipient-$suffix@example.com';
    final recipientSession = await recipient.register(
        email: recipientEmail,
        password: 'password123',
        displayName: 'Synthetic card recipient',
        role: UserRole.caregiver);
    await owner.register(
        email: 'private-card-owner-$suffix@example.com',
        password: 'password123',
        displayName: 'Synthetic card owner',
        role: UserRole.elder);
    final invitation = await owner
        .createInvitation(email: recipientEmail, scopes: ['family_messages']);
    final link = await recipient.acceptInvitation(
        invitationId: invitation.id, token: invitation.token!);
    final initial = await owner.getMemoryControlState();
    final enabled = await owner.setMemoryConsentAtRevision(true,
        expectedRevision: initial.revision);
    final memory = await owner.saveConfirmedMemoryAtRevision(
        content: 'Synthetic original source $suffix',
        kind: 'experience',
        expectedRevision: enabled.revision);
    final card = await owner.createStoryAtRevision(
        title: 'Private card',
        content: memory.content,
        memoryIds: [memory.id],
        expectedRevision: memory.revision!);
    expect(card.memoryIds, [memory.id]);
    expect(await recipient.listFamilyMessages(), isEmpty,
        reason: 'Saving a card is private');
    final oldPreview = '${card.title}\n${card.content}';
    final oldKey = 'private-card-old-$suffix';
    final oldShare = await owner.sendFamilyMessageAtRevision(
        familyLinkId: link.id,
        expectedAuthorizationEpoch: link.authorizationEpoch!,
        recipientId: recipientSession.user.id,
        content: oldPreview,
        clientMessageId: oldKey,
        sourceStoryId: card.id,
        expectedRevision: card.revision!);
    final unrelated = await owner.sendFamilyMessage(
        familyLinkId: link.id,
        expectedAuthorizationEpoch: link.authorizationEpoch!,
        recipientId: recipientSession.user.id,
        content: 'Independent synthetic family message',
        clientMessageId: 'private-card-unrelated-$suffix');
    final captured = await owner.getMemoryControlState();
    final edited = await owner.updateStoryAtRevision(card.id,
        title: 'Edited private card',
        content: 'Explicitly edited card text $suffix',
        expectedRevision: captured.revision);
    expect(edited.id, card.id);
    expect(edited.memoryIds, card.memoryIds);
    expect(edited.createdAt, card.createdAt);
    expect(edited.revision, greaterThan(captured.revision));
    expect((await owner.listMemories()).single.content, memory.content,
        reason: 'Editing the card preserves original memory text');
    final afterEdit = await recipient.listFamilyMessages();
    expect(afterEdit.singleWhere((m) => m.id == oldShare.id).content,
        isNot(contains(card.content)));
    expect(afterEdit.singleWhere((m) => m.id == unrelated.id).content,
        unrelated.content);
    final conflict =
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409));
    await expectLater(
        owner.updateStoryAtRevision(card.id,
            title: 'Obsolete',
            content: 'Obsolete',
            expectedRevision: captured.revision),
        conflict);
    await expectLater(
        owner.sendFamilyMessageAtRevision(
            familyLinkId: link.id,
            expectedAuthorizationEpoch: link.authorizationEpoch!,
            recipientId: recipientSession.user.id,
            content: oldPreview,
            clientMessageId: 'private-card-stale-$suffix',
            sourceStoryId: card.id,
            expectedRevision: captured.revision),
        conflict);
    await expectLater(
        owner.sendFamilyMessageAtRevision(
            familyLinkId: link.id,
            expectedAuthorizationEpoch: link.authorizationEpoch!,
            recipientId: recipientSession.user.id,
            content: oldPreview,
            clientMessageId: oldKey,
            sourceStoryId: card.id,
            expectedRevision: edited.revision!),
        conflict);
    final newPreview = '${edited.title}\n${edited.content}';
    await expectLater(
        owner.sendFamilyMessageAtRevision(
            familyLinkId: link.id,
            expectedAuthorizationEpoch: link.authorizationEpoch!,
            recipientId: recipientSession.user.id,
            content: newPreview,
            clientMessageId: oldKey,
            sourceStoryId: card.id,
            expectedRevision: edited.revision!),
        conflict);
    final fresh = await owner.sendFamilyMessageAtRevision(
        familyLinkId: link.id,
        expectedAuthorizationEpoch: link.authorizationEpoch!,
        recipientId: recipientSession.user.id,
        content: newPreview,
        clientMessageId: 'private-card-new-$suffix',
        sourceStoryId: edited.id,
        expectedRevision: edited.revision!);
    expect(fresh.id, isNot(oldShare.id));
    expect(fresh.content, newPreview);
    final beforeOff = await owner.getMemoryControlState();
    final off = await owner.setMemoryConsentAtRevision(false,
        expectedRevision: beforeOff.revision);
    expect(off.enabled, isFalse);
    final afterOff = await recipient.listFamilyMessages();
    expect(afterOff.singleWhere((m) => m.id == fresh.id).content, newPreview,
        reason: 'Memory off preserves explicit card sharing');
    expect(afterOff.singleWhere((m) => m.id == unrelated.id).content,
        unrelated.content);
    expect(afterOff.singleWhere((m) => m.id == oldShare.id).content,
        isNot(contains(card.content)));
    final offShare = await owner.sendFamilyMessageAtRevision(
        familyLinkId: link.id,
        expectedAuthorizationEpoch: link.authorizationEpoch!,
        recipientId: recipientSession.user.id,
        content: newPreview,
        clientMessageId: 'private-card-off-$suffix',
        sourceStoryId: edited.id,
        expectedRevision: off.revision);
    expect(offShare.content, newPreview,
        reason:
            'Independent explicit card sharing remains available when memory is off');
  },
      skip: !_runLive
          ? 'Run only against root-owned synthetic localhost with --dart-define=RUN_LIVE_API_TESTS=true --dart-define=API_ORIGIN=http://127.0.0.1:PORT'
          : false);
}
