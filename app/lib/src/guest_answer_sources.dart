import 'answer_card_models.dart';
export 'answer_card_models.dart' show AnswerCardSource;

/// The server supplies a closed, versioned snapshot on the accepted guest turn.
/// Source hashes bind reviewed record versions, never the entire AI answer.
/// No text/URL extraction and no persistence or owner-card API is involved.
List<AnswerCardSource> parseGuestAnswerSources(Map<String, dynamic> response) {
  if (response['answer_card_sources_version'] != 1) return const [];
  final raw = response['answer_card_sources'];
  if (raw is! List || raw.length > 10) return const [];
  try {
    final sources = raw.map(AnswerCardSource.fromJson).toList();
    if (sources.any((source) => source.contentHash == null) ||
        sources.map((source) => source.sourceId).toSet().length != sources.length) {
      return const [];
    }
    return List.unmodifiable(sources);
  } on FormatException {
    // Preserve the chat, with no claim that malformed/unversioned refs verify it.
    return const [];
  }
}
