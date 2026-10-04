import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _runLive =
    bool.fromEnvironment('RUN_LIVE_API_TESTS', defaultValue: false);
const _liveOrigin =
    String.fromEnvironment('API_ORIGIN', defaultValue: 'http://127.0.0.1:8013');

void main() {
  test('live memory deletion replay preserves later saves and consent choice',
      () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final api = RestApiClient(origin: _liveOrigin);
    await api.register(
      email: 'memory-controls-$suffix@example.com',
      password: 'password123',
      displayName: 'Synthetic Memory Controls Owner',
      role: UserRole.elder,
    );

    final initial = await api.getMemoryControlState();
    final enabled = await api.setMemoryConsentAtRevision(true,
        expectedRevision: initial.revision);
    expect(enabled.enabled, isTrue);
    final first = await api.saveConfirmedMemoryAtRevision(
        content: 'Synthetic first saved preference $suffix',
        kind: 'preference',
        expectedRevision: enabled.revision);
    expect(first.revision, isNotNull);
    final beforeDelete = await api.getMemoryControlState();
    expect(beforeDelete.revision, first.revision);
    final originalRevision = beforeDelete.revision;
    final originalKey = 'all-memory-delete-$suffix';
    final receipt = await api.deleteMemories(
        mode: 'all',
        expectedRevision: originalRevision,
        idempotencyKey: originalKey);
    expect(receipt.requestId, isNotEmpty);
    expect(receipt.revision, originalRevision + 1);
    expect(receipt.counts['memories'], 1);
    expect(await api.listMemories(), isEmpty);
    final afterDelete = await api.getMemoryControlState();
    expect(afterDelete.enabled, isTrue,
        reason: 'Deleting history must preserve the consent choice');
    expect(afterDelete.revision, receipt.revision);

    final later = await api.saveConfirmedMemoryAtRevision(
        content: 'Synthetic later saved preference $suffix',
        kind: 'preference',
        expectedRevision: afterDelete.revision);
    final beforeReplay = await api.getMemoryControlState();
    expect(beforeReplay.revision, later.revision);
    final replay = await api.deleteMemories(
        mode: 'all',
        expectedRevision: originalRevision,
        idempotencyKey: originalKey);
    expect(replay.requestId, receipt.requestId);
    expect(replay.revision, receipt.revision);
    expect(replay.counts, receipt.counts);
    final afterReplay = await api.getMemoryControlState();
    expect(afterReplay.revision, beforeReplay.revision,
        reason: 'Replaying the old receipt must not repeat the deletion');
    expect((await api.listMemories()).map((m) => m.id), [later.id]);
    await expectLater(
        api.saveConfirmedMemoryAtRevision(
            content: 'Synthetic obsolete draft $suffix',
            kind: 'preference',
            expectedRevision: originalRevision),
        throwsA(isA<ApiException>()
            .having((error) => error.statusCode, 'stale snapshot', 409)));
    expect((await api.getMemoryControlState()).revision, afterReplay.revision);

    final offSnapshot = await api.getMemoryControlState();
    final disabled = await api.setMemoryConsentAtRevision(false,
        expectedRevision: offSnapshot.revision);
    expect(disabled.enabled, isFalse);
    expect((await api.listMemories()).map((m) => m.id), [later.id],
        reason: 'Turning memory off must retain saved history');
    final cleanupSnapshot = await api.getMemoryControlState();
    final cleanup = await api.deleteMemories(
        mode: 'all',
        expectedRevision: cleanupSnapshot.revision,
        idempotencyKey: 'cleanup-memory-delete-$suffix');
    expect(cleanup.counts['memories'], 1);
    final finalState = await api.getMemoryControlState();
    expect(finalState.enabled, isFalse);
    expect(finalState.revision, cleanup.revision);
    expect(finalState.counts['total'], 0);
    expect(await api.listMemories(), isEmpty);
  },
      skip:
          !_runLive ? 'Run with --dart-define=RUN_LIVE_API_TESTS=true' : false);
}
