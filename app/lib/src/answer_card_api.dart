import 'answer_card_models.dart';
export 'answer_card_models.dart';

/// Optional capability; the core AnxinApi and its existing fakes stay compatible.
abstract interface class AnswerCardApi {
  Future<List<AnswerCardTemplate>> listAnswerCardTemplates();
  Future<AnswerCardDraftSnapshot> prepareAnswerCard(String sourceMessageId);
  Future<List<OwnedAnswerCard>> listAnswerCards();
  Future<OwnedAnswerCard> createAnswerCard(Map<String, Object?> request);
  Future<OwnedAnswerCard> updateAnswerCard(
      String cardId, Map<String, Object?> request);
  Future<AnswerCardDeleteReceipt> deleteAnswerCard(
      {required String cardId,
      required int expectedVersion,
      required String clientOperationId});
}

/// Validate captured request fields without supplying defaults or refreshing data.
void validateAnswerCardCreateRequest(Map<String, Object?> request) {
  _closed(request, const [
    'origin',
    'selected_sections',
    'title',
    'client_operation_id'
  ], const [
    'selected_source_ids',
    'official_terms',
    'missing_information',
    'next_steps'
  ]);
  final origin = request['origin'];
  if (origin is! Map<String, Object?>) {
    throw const FormatException('Invalid card origin');
  }
  if (origin.containsKey('message_id')) {
    _closed(origin, const ['message_id', 'source_hash'], const []);
    _text(origin['message_id'], 36);
    _hash(origin['source_hash']);
  } else {
    _closed(origin, const ['template_id', 'template_version', 'template_hash'],
        const []);
    _text(origin['template_id'], 120);
    _version(origin['template_version']);
    _hash(origin['template_hash']);
  }
  final sections = _list(request['selected_sections'], 12, min: 1);
  final ids = <String>[];
  for (final raw in sections) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('Invalid selected section');
    }
    _closed(raw, const ['id'], const ['edited_text']);
    ids.add(_text(raw['id'], 200));
    if (raw['edited_text'] != null) _text(raw['edited_text'], 4000);
  }
  _unique(ids);
  _display(request, create: true);
}

void validateAnswerCardUpdateRequest(Map<String, Object?> request) {
  _closed(request, const [
    'title',
    'selected_sections',
    'official_terms',
    'missing_information',
    'next_steps',
    'selected_source_ids',
    'expected_version',
    'client_operation_id'
  ], const []);
  _version(request['expected_version']);
  final sections = _strings(request['selected_sections'], 12, 4000, min: 1);
  if (sections.fold<int>(0, (n, s) => n + s.runes.length) > 16000) {
    throw const FormatException('Card body exceeds limit');
  }
  _display(request, create: false);
}

void validateAnswerCardIdentity(String cardId) => _text(cardId, 36);
void validateAnswerCardDeleteRequest(
    int expectedVersion, String clientOperationId) {
  _version(expectedVersion);
  _text(clientOperationId, 200);
}

void _display(Map<String, Object?> request, {required bool create}) {
  _text(request['title'], 240);
  _text(request['client_operation_id'], 200);
  if (!create || request.containsKey('selected_source_ids')) {
    _unique(_strings(request['selected_source_ids'], 10, 200));
  }
  for (final field in ['official_terms', 'missing_information', 'next_steps']) {
    if (!create || request.containsKey(field)) {
      _strings(request[field], field == 'missing_information' ? 12 : 10,
          field == 'missing_information' ? 4000 : 1000);
    }
  }
}

void _closed(
    Map<String, Object?> m, List<String> required, List<String> optional) {
  if (required.any((k) => !m.containsKey(k)) ||
      m.keys.any((k) => !required.contains(k) && !optional.contains(k))) {
    throw const FormatException('Invalid answer card request fields');
  }
}

String _text(Object? v, int max) {
  if (v is! String || v.trim().isEmpty || v.runes.length > max) {
    throw const FormatException('Invalid card request text');
  }
  return v;
}

void _hash(Object? v) {
  if (v is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(v)) {
    throw const FormatException('Invalid captured hash');
  }
}

void _version(Object? v) {
  if (v is! int || v < 1) {
    throw const FormatException('Invalid captured version');
  }
}

List<Object?> _list(Object? v, int max, {int min = 0}) {
  if (v is! List || v.length < min || v.length > max) {
    throw const FormatException('Invalid card request list');
  }
  return List<Object?>.from(v);
}

List<String> _strings(Object? v, int max, int textMax, {int min = 0}) =>
    _list(v, max, min: min).map((s) => _text(s, textMax)).toList();
void _unique(List<String> ids) {
  if (ids.toSet().length != ids.length) {
    throw const FormatException('Duplicate card identifiers');
  }
}
