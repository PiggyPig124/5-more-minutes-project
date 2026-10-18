import 'dart:convert';
import 'app_controller.dart';
import 'content_simplification_api.dart';
import 'message_content_actions.dart';
import 'models.dart';

Object simplificationScope(AppController c) =>
    (c, c.helpSearchIdentity, c.session, c.guestSession?.id);
String simplificationVersion(ChatMessage message) =>
    jsonEncode([message.id, message.body, message.metadata],
        toEncodable: (value) => value.toString());
ReadOnlySimplifier? bindContentSimplification(AppController c, String locale) {
  final api = c.api;
  if (api is! ContentSimplificationApi) return null;
  final signed = c.session != null;
  final guestId = signed ? null : c.guestSession?.id;
  if (!signed && guestId == null) return null;
  final scope = simplificationScope(c);
  final guestIdentity = c.guestSessionIdentity;
  bool current() =>
      simplificationScope(c) == scope &&
      (signed ||
          c.guestSession?.expiresAt == null ||
          c.guestSession!.expiresAt!.isAfter(DateTime.now()));
  return (original) async {
    if (!current()) {
      throw const ContentSimplificationException('session_changed');
    }
    late final SimplificationDraft draft;
    try {
      draft = await (api as ContentSimplificationApi).simplifyContent(
          original: original,
          locale: locale,
          explicitlyRequested: true,
          guestSessionId: guestId);
    } catch (error) {
      if (!signed) c.handleGuestSessionFailure(guestIdentity, error);
      rethrow;
    }
    if (!current()) {
      throw const ContentSimplificationException('session_changed');
    }
    return draft.simpler;
  };
}
