/// Independent capability: never send a conversation turn or patch a memory.
abstract interface class ContentSimplificationApi {
  Future<SimplificationDraft> simplifyContent(
      {required String original,
      required String locale,
      required bool explicitlyRequested,
      String? guestSessionId});
}

class ContentSimplificationException implements Exception {
  const ContentSimplificationException(this.reason);
  final String reason;
}

class SimplificationDraft {
  const SimplificationDraft({required this.original, required this.simpler});
  final String original;
  final String simpler;
  factory SimplificationDraft.parse(Object? value, String expectedOriginal) {
    if (value is! Map ||
        value.length != 5 ||
        !value.keys.toSet().containsAll(const [
          'status',
          'original',
          'simpler',
          'reason',
          'independently_verified'
        ]) ||
        value['original'] != expectedOriginal ||
        value['independently_verified'] != false) {
      throw const ContentSimplificationException('invalid_response');
    }
    if (value['status'] == 'unavailable' &&
        value['simpler'] == null &&
        value['reason'] is String) {
      throw ContentSimplificationException(
          value['reason'] == 'model_unavailable'
              ? 'model_unavailable'
              : 'unavailable');
    }
    final text = value['simpler'];
    if (value['status'] != 'draft' ||
        value['reason'] != null ||
        text is! String ||
        text.trim().isEmpty ||
        text.length >= 10000 ||
        expectedOriginal.trim().startsWith(text.trim()) ||
        text.trim().startsWith('{') ||
        text.trim().startsWith('[')) {
      throw const ContentSimplificationException('invalid_response');
    }
    return SimplificationDraft(original: expectedOriginal, simpler: text);
  }
}
