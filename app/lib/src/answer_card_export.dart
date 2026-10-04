import 'dart:convert';
import 'package:flutter/services.dart';
import 'answer_card_models.dart';
import 'answer_card_export_stub.dart'
    if (dart.library.js_interop) 'answer_card_export_web.dart' as platform;

enum ExportFormat { copyText, printHtml }
enum ExportOutcome { copied, dialogOpened, cancelled, blocked, failed }
enum ExportOrigin { ownedCard, guestLocal }

/// Review-bound public content only. Owner identifiers are never rendered.
class ExportPreview {
  const ExportPreview({required this.publicPayload, required this.payloadHash,
    required this.personalReviewAck, required this.mode, this.cardId, this.version,
    this.origin = ExportOrigin.ownedCard});
  final CardPublicPayload publicPayload;
  final String payloadHash;
  final String mode;
  final bool personalReviewAck;
  final String? cardId;
  final int? version;
  final ExportOrigin origin;
}

abstract interface class AnswerCardPrintReservation {
  bool get isClosed;
  void printHtml(String escapedHtml);
  void close();
}
abstract interface class AnswerCardExportPlatform {
  /// Called synchronously from the user gesture, before any validation await.
  AnswerCardPrintReservation? reservePrint();
  Future<void> copyText(String text);
}

class _SdkExportPlatform implements AnswerCardExportPlatform {
  @override
  AnswerCardPrintReservation? reservePrint() => platform.reserveAnswerCardPrintWindow();
  @override
  Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));
}

class AnswerCardExporter {
  AnswerCardExporter({AnswerCardExportPlatform? platform})
      : _platform = platform ?? _SdkExportPlatform();
  final AnswerCardExportPlatform _platform;
  final Set<AnswerCardPrintReservation> _activePrints = {};
  int _generation = 0;

  /// Immediately close reserved/open previews and invalidate pending exports.
  void cancelActiveExports() {
    _generation++;
    final reservations = _activePrints.toList(growable: false);
    _activePrints.clear();
    for (final reservation in reservations) {
      _close(reservation);
    }
  }

  void _pruneClosedReservations() {
    _activePrints.removeWhere((reservation) => reservation.isClosed);
  }

  /// The current-session/edit predicate must close over the reviewed generation.
  /// Owned cards require server revalidation. Guest previews stay local.
  Future<ExportOutcome> exportCard(ExportPreview preview, ExportFormat format, {
    required bool Function() isCurrent,
    Future<ExportPreview> Function()? revalidate,
  }) async {
    final generation = _generation;
    bool current() {
      if (generation != _generation) return false;
      try { return isCurrent(); } catch (_) { return false; }
    }
    AnswerCardPrintReservation? reservation;
    var dialogOpened = false;
    try {
      _pruneClosedReservations();
      if (!preview.personalReviewAck || !current()) return ExportOutcome.cancelled;
      _validatePreview(preview);
      if ((preview.origin == ExportOrigin.ownedCard && revalidate == null) ||
          (preview.origin == ExportOrigin.guestLocal && revalidate != null)) {
        return ExportOutcome.failed;
      }
      // There is deliberately no await before reserving a blank print window.
      if (format == ExportFormat.printHtml) {
        reservation = _platform.reservePrint();
        if (reservation == null) return ExportOutcome.blocked;
        _activePrints.add(reservation);
      }
      if (revalidate != null) {
        final refreshed = await revalidate();
        if (!current()) {
          _close(reservation);
          return ExportOutcome.cancelled;
        }
        _validatePreview(refreshed);
        if (!refreshed.personalReviewAck || !_samePreview(preview, refreshed)) {
          _close(reservation);
          return ExportOutcome.cancelled;
        }
      }
      if (!current() || (reservation?.isClosed ?? false)) {
        _close(reservation);
        return ExportOutcome.cancelled;
      }
      if (format == ExportFormat.copyText) {
        await _platform.copyText(renderCardText(preview.publicPayload, mode: preview.mode));
        return current() ? ExportOutcome.copied : ExportOutcome.cancelled;
      }
      reservation!.printHtml(renderCardHtml(preview.publicPayload, mode: preview.mode));
      dialogOpened = true;
      // Keep an open print preview cancellable until afterprint closes it.
      // Browsers cannot tell us whether a print/PDF operation succeeded.
      return ExportOutcome.dialogOpened;
    } catch (_) {
      _close(reservation);
      return current() ? ExportOutcome.failed : ExportOutcome.cancelled;
    } finally {
      if (reservation != null && !dialogOpened) _activePrints.remove(reservation);
      _pruneClosedReservations();
    }
  }
}
void _validatePreview(ExportPreview preview) {
  CardPublicPayload.fromJson(preview.publicPayload.toJson());
  _originLabel(preview.mode);
  if (preview.origin == ExportOrigin.ownedCard) {
    if (preview.cardId == null || preview.cardId!.trim().isEmpty ||
        preview.cardId!.runes.length > 36 || preview.version == null || preview.version! < 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(preview.payloadHash)) {
      throw const FormatException('Invalid owned export preview');
    }
  } else if (preview.cardId != null || preview.version != null ||
      !RegExp(r'^local:\S{1,200}$').hasMatch(preview.payloadHash)) {
    throw const FormatException('Invalid local export preview');
  }
}
bool _samePreview(ExportPreview a, ExportPreview b) =>
    a.origin == b.origin && a.mode == b.mode && a.cardId == b.cardId && a.version == b.version &&
    a.payloadHash == b.payloadHash &&
    jsonEncode(a.publicPayload.toJson()) == jsonEncode(b.publicPayload.toJson());
void _close(AnswerCardPrintReservation? reservation) {
  try {
    if (reservation != null && !reservation.isClosed) reservation.close();
  } catch (_) { /* Cleanup must not expose content. */ }
}

/// A complete, fixed-order representation of public display fields.
String renderCardText(CardPublicPayload payload, {String? mode}) {
  final p = CardPublicPayload.fromJson(payload.toJson());
  const notProvided = 'Not provided / \u672a\u63d0\u4f9b';
  const originalMissing = 'Not provided in original answer / \u539f\u56de\u7b54\u672a\u63d0\u4f9b';
  final parts = <String>[
    p.title,
    if (mode != null) ...['Origin / \u539f\u59cb\u4f86\u6e90', _originLabel(mode)],
    ...p.selectedSections,
    'Official terms / \u5b98\u65b9\u8853\u8a9e',
    ...(p.officialTerms.isEmpty ? [originalMissing] : p.officialTerms),
    'Missing information / \u5c1a\u5f85\u78ba\u8a8d',
    ...(p.missingInformation.isEmpty ? [notProvided] : p.missingInformation),
    'Next steps / \u4e0b\u4e00\u6b65',
    ...(p.nextSteps.isEmpty ? [originalMissing] : p.nextSteps),
    'Verification / \u6838\u5be6\u72c0\u614b',
    '${p.verificationState}: ${_verificationLabel(p.verificationState)}',
    'Verification scope / \u6838\u5be6\u7bc4\u570d', p.verificationScope,
    'Sources / \u4f86\u6e90',
  ];
  if (p.publicSources.isEmpty) parts.add('No verified source / \u6c92\u6709\u53ef\u6838\u5be6\u4f86\u6e90');
  for (var i = 0; i < p.publicSources.length; i++) {
    final s = p.publicSources[i];
    parts.addAll([
      '${i + 1}. ${s.organisation}: ${s.title}', s.url,
      'Reviewed date / \u6838\u5c0d\u65e5\u671f: ${s.reviewedAt ?? notProvided}',
      'Retrieved date / \u6aa2\u7d22\u65e5\u671f: ${s.retrievedAt ?? notProvided}',
      'Effective date / \u751f\u6548\u65e5\u671f: ${s.effectiveDate ?? notProvided}',
      'Source verification scope / \u4f86\u6e90\u6838\u5be6\u7bc4\u570d: ${s.verificationScope}',
    ]);
  }
  final text = parts.join('\n\n');
  if (text.runes.length > 30000) throw const FormatException('Complete export text exceeds limit');
  return text;
}
String _originLabel(String mode) => switch (mode) {
  'assistant_answer' => 'AI answer / AI \u56de\u7b54',
  'public_template' => 'Public template / \u516c\u958b\u6a21\u677f',
  _ => throw const FormatException('Unknown answer card origin mode'),
};
String _verificationLabel(String state) => switch (state) {
  'reviewed_public_guidance' => 'Reviewed public guidance; individual eligibility is not confirmed.',
  'ai_unverified' => 'AI answer is not independently verified.',
  'user_edited_unverified' => 'User-edited content is not independently verified.',
  'no_verified_source' => 'No verified source; content is not independently verified.',
  _ => throw const FormatException('Unknown verification state'),
};

/// Plain display text in escaped HTML, with no executable or remote assets.
String renderCardHtml(CardPublicPayload payload, {String? mode}) {
  final text = renderCardText(payload, mode: mode);
  return '<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">'
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; '
      'style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'">'
      '<title>${_escape(payload.title)}</title>'
      '<style>body{margin:24px;color:#111;background:#fff;font-family:system-ui,sans-serif;}'
      'pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;font-size:16px;line-height:1.6;}'
      '@media print{body{margin:0;}pre{font-size:12pt;}@page{margin:16mm;}}</style>'
      '</head><body><main><pre>${_escape(text)}</pre></main></body></html>';
}
String _escape(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
