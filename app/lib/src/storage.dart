import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

abstract class LocalStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class SecureLocalStore implements LocalStore {
  SecureLocalStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A deterministic store for widget tests and an explicit seam for a future
/// encrypted offline queue implementation.
class MemoryLocalStore implements LocalStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class SessionStore {
  SessionStore(this._store);

  static const tokenKey = 'anxin.access_token';
  static const userKey = 'anxin.user';
  static const demoKey = 'anxin.demo_mode';
  static const draftPrefix = 'anxin.draft.';
  static const draftIdPrefix = 'anxin.draft_id.';

  final LocalStore _store;

  Future<void> saveSession(AuthSession session) async {
    await Future.wait([
      _store.write(tokenKey, session.accessToken),
      _store.write(userKey, jsonEncode(session.user.toJson())),
      _store.write(demoKey, session.demoMode.toString()),
    ]);
  }

  Future<AuthSession?> readSession() async {
    final token = await _store.read(tokenKey);
    final userJson = await _store.read(userKey);
    if (token == null || token.isEmpty || userJson == null || userJson.isEmpty) {
      return null;
    }
    try {
      final user = AppUser.fromJson(
        (jsonDecode(userJson) as Map).map(
          (key, value) => MapEntry(key.toString(), value),
        ),
      );
      final demoMode = (await _store.read(demoKey)) == 'true';
      return AuthSession(accessToken: token, user: user, demoMode: demoMode);
    } on Object {
      await clearSession();
      return null;
    }
  }

  Future<void> clearSession() async {
    await Future.wait([
      _store.delete(tokenKey),
      _store.delete(userKey),
      _store.delete(demoKey),
    ]);
  }

  String draftKey(String conversationId, {String? userId}) =>
      '$draftPrefix${userId ?? 'anonymous'}.$conversationId';

  String draftClientIdKey(String conversationId, {String? userId}) =>
      '$draftIdPrefix${userId ?? 'anonymous'}.$conversationId';

  Future<String?> readDraft(String conversationId, {String? userId}) =>
      _store.read(draftKey(conversationId, userId: userId));

  Future<void> saveDraft(String conversationId, String draft, {String? userId}) async {
    final key = draftKey(conversationId, userId: userId);
    if (draft.trim().isEmpty) {
      await _store.delete(key);
    } else {
      await _store.write(key, draft);
    }
  }

  Future<String?> readDraftClientId(String conversationId, {String? userId}) =>
      _store.read(draftClientIdKey(conversationId, userId: userId));

  Future<void> saveDraftClientId(String conversationId, String clientId, {String? userId}) =>
      _store.write(draftClientIdKey(conversationId, userId: userId), clientId);

  Future<void> clearDraft(String conversationId, {String? userId}) =>
      _store.delete(draftKey(conversationId, userId: userId));

  Future<void> clearDraftClientId(String conversationId, {String? userId}) =>
      _store.delete(draftClientIdKey(conversationId, userId: userId));
}
