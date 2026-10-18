import 'dart:async';
import 'package:anxin_companion/src/interaction_preferences.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';

class ControlledStore implements LocalStore {
  final values = <String, String>{
    'anxin.access_token': 'unchanged',
    'memory': 'unchanged'
  };
  final reads = <String>[];
  final writes = <String>[];
  Completer<String?>? readGate;
  Completer<void>? writeGate;
  bool failRead = false, failWrite = false;
  int activeWrites = 0, maxWrites = 0;
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    if (failRead) throw StateError('read failed');
    if (readGate != null) return await readGate!.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    activeWrites++;
    if (activeWrites > maxWrites) maxWrites = activeWrites;
    try {
      await writeGate?.future;
      if (failWrite) throw StateError('write failed');
      values[key] = value;
    } finally {
      activeWrites--;
    }
  }

  @override
  Future<void> delete(String key) async => fail('must never delete');
}

void main() {
  test(
      'default both, all choices autosave and restart reload only independent key',
      () async {
    final store = ControlledStore();
    final controller = InteractionPreferenceController(store);
    expect(controller.preference, InteractionPreference.both);
    await controller.reload();
    for (final mode in InteractionPreference.values) {
      await controller.setPreference(mode);
      final reopened = InteractionPreferenceController(store);
      await reopened.reload();
      expect(reopened.preference, mode);
      reopened.dispose();
    }
    expect(store.reads.toSet(), {InteractionPreferenceController.storageKey});
    expect(store.writes.toSet(), {InteractionPreferenceController.storageKey});
    expect(store.values['anxin.access_token'], 'unchanged');
    expect(store.values['memory'], 'unchanged');
    controller.dispose();
  });
  test('late load cannot overwrite a choice or later reload', () async {
    final store = ControlledStore()..readGate = Completer<String?>();
    final controller = InteractionPreferenceController(store);
    final load = controller.reload();
    await Future<void>.delayed(Duration.zero);
    await controller.setPreference(InteractionPreference.typing);
    store.readGate!.complete('speaking');
    await load;
    expect(controller.preference, InteractionPreference.typing);
    expect(controller.loading, isFalse);
    controller.dispose();
  });
  test('serialized delayed writes finish at latest choice', () async {
    final store = ControlledStore()..writeGate = Completer<void>();
    final controller = InteractionPreferenceController(store);
    final first = controller.setPreference(InteractionPreference.speaking);
    final second = controller.setPreference(InteractionPreference.typing);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, hasLength(1));
    store.writeGate!.complete();
    await Future.wait([first, second]);
    expect(store.maxWrites, 1);
    expect(store.values[InteractionPreferenceController.storageKey], 'typing');
    controller.dispose();
  });
  test('load and save failure surface with explicit successful retry',
      () async {
    final store = ControlledStore()..failRead = true;
    final controller = InteractionPreferenceController(store);
    await controller.reload();
    expect(controller.loadFailed, isTrue);
    store.failRead = false;
    store.values[InteractionPreferenceController.storageKey] = 'speaking';
    await controller.retry();
    expect(controller.preference, InteractionPreference.speaking);
    expect(controller.loadFailed, isFalse);
    store.failWrite = true;
    await controller.setPreference(InteractionPreference.typing);
    expect(controller.saveFailed, isTrue);
    expect(controller.preference, InteractionPreference.typing);
    store.failWrite = false;
    await controller.retry();
    expect(controller.saveFailed, isFalse);
    expect(store.values[InteractionPreferenceController.storageKey], 'typing');
    controller.dispose();
  });
  test('disposed controller ignores load and skips queued writes', () async {
    final store = ControlledStore()
      ..readGate = Completer<String?>()
      ..writeGate = Completer<void>();
    final controller = InteractionPreferenceController(store);
    var notifications = 0;
    controller.addListener(() => notifications++);
    final load = controller.reload();
    final first = controller.setPreference(InteractionPreference.speaking);
    await Future<void>.delayed(Duration.zero);
    final second = controller.setPreference(InteractionPreference.typing);
    controller.dispose();
    final count = notifications;
    store.readGate!.complete('both');
    store.writeGate!.complete();
    await Future.wait([load, first, second]);
    expect(notifications, count);
    expect(store.writes, hasLength(1));
    await controller.setPreference(InteractionPreference.both);
    expect(store.writes, hasLength(1));
  });
  test('reload during delayed write settles saving and reads the newest value',
      () async {
    final store = ControlledStore()..writeGate = Completer<void>();
    final controller = InteractionPreferenceController(store);
    final write = controller.setPreference(InteractionPreference.typing);
    final oldReload = controller.reload();
    final reload = controller.reload();
    store.writeGate!.complete();
    await Future.wait([write, oldReload, reload]);
    expect(controller.saving, isFalse);
    expect(controller.loading, isFalse);
    expect(controller.preference, InteractionPreference.typing);
    controller.dispose();
  });
  test('failed write followed by reload retains the unsaved choice for retry',
      () async {
    final store = ControlledStore()
      ..writeGate = Completer<void>()
      ..failWrite = true;
    final controller = InteractionPreferenceController(store);
    final write = controller.setPreference(InteractionPreference.typing);
    final reload = controller.reload();
    store.writeGate!.complete();
    await Future.wait([write, reload]);
    expect(controller.saving, isFalse);
    expect(controller.saveFailed, isTrue);
    expect(controller.preference, InteractionPreference.typing);
    store.failWrite = false;
    await controller.retry();
    expect(store.values[InteractionPreferenceController.storageKey], 'typing');
    controller.dispose();
  });
}
