import 'dart:convert';

/// Public display data is separate from owner-only provenance.
class AnswerCardSection {
  const AnswerCardSection({required this.id, required this.text});
  final String id, text;
  factory AnswerCardSection.fromJson(Object? raw) {
    final m = _object(raw, const ['id', 'text']);
    return AnswerCardSection(
        id: _text(m['id'], 200), text: _text(m['text'], 4000));
  }
}

class AnswerCardSource {
  const AnswerCardSource(
      {required this.sourceId,
      required this.organisation,
      required this.title,
      required this.url,
      required this.verificationScope,
      this.reviewedAt,
      this.retrievedAt,
      this.effectiveDate,
      this.contentHash});
  final String sourceId, organisation, title, url, verificationScope;
  final String? reviewedAt, retrievedAt, effectiveDate, contentHash;
  factory AnswerCardSource.fromJson(Object? raw) {
    final m = _object(raw, const [
      'source_id',
      'organisation',
      'title',
      'url',
      'verification_scope'
    ], optional: const [
      'reviewed_at',
      'retrieved_at',
      'effective_date',
      'content_hash'
    ]);
    final url = _text(m['url'], 2048);
    final u = Uri.tryParse(url);
    if (u == null ||
        u.scheme != 'https' ||
        u.userInfo.isNotEmpty ||
        u.hasPort ||
        u.hasFragment ||
        !RegExp(r'^https://(www\.cheu\.gov\.hk|www\.elderly\.gov\.hk|www\.ha\.org\.hk|www\.hkab\.org\.hk|www\.mtr\.com\.hk|www\.swd\.gov\.hk|www\.td\.gov\.hk|portal\.csdi\.gov\.hk)(/|\?|$)',
                caseSensitive: false)
            .hasMatch(url) ||
        !const [
          'www.cheu.gov.hk',
          'www.elderly.gov.hk',
          'www.ha.org.hk',
          'www.hkab.org.hk',
          'www.mtr.com.hk',
          'www.swd.gov.hk',
          'www.td.gov.hk',
          'portal.csdi.gov.hk'
        ].contains(u.host) ||
        RegExp(r'\s|[\x00-\x1f]').hasMatch(url) ||
        (u.hasQuery &&
            !(u.host == 'portal.csdi.gov.hk' &&
                u.query == 'datasetId=swd_rcd_1696994103126_1549') &&
            url !=
                'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100826')) {
      throw const FormatException('Invalid public source URL');
    }
    return AnswerCardSource(
        sourceId: _text(m['source_id'], 120),
        organisation: _text(m['organisation'], 300),
        title: _text(m['title'], 300),
        url: url,
        verificationScope: _text(m['verification_scope'], 4000),
        reviewedAt: _date(m['reviewed_at']),
        retrievedAt: _date(m['retrieved_at']),
        effectiveDate: _date(m['effective_date']),
        contentHash:
            m['content_hash'] == null ? null : _hash(m['content_hash']));
  }
  Map<String, Object?> toJson() => {
        'source_id': sourceId,
        'organisation': organisation,
        'title': title,
        'url': url,
        'reviewed_at': reviewedAt,
        'retrieved_at': retrievedAt,
        'effective_date': effectiveDate,
        'verification_scope': verificationScope,
        'content_hash': contentHash
      };
}

class CardPublicPayload {
  CardPublicPayload(
      {required this.title,
      required List<String> selectedSections,
      required List<String> officialTerms,
      required List<String> missingInformation,
      required List<String> nextSteps,
      required List<AnswerCardSource> publicSources,
      required this.verificationState,
      required this.verificationScope})
      : selectedSections = List.unmodifiable(selectedSections),
        officialTerms = List.unmodifiable(officialTerms),
        missingInformation = List.unmodifiable(missingInformation),
        nextSteps = List.unmodifiable(nextSteps),
        publicSources = List.unmodifiable(publicSources);
  final String title, verificationState, verificationScope;
  final List<String> selectedSections,
      officialTerms,
      missingInformation,
      nextSteps;
  final List<AnswerCardSource> publicSources;
  factory CardPublicPayload.fromJson(Object? raw) {
    final m = _object(raw, const [
      'title',
      'selected_sections',
      'official_terms',
      'missing_information',
      'next_steps',
      'public_sources',
      'verification_state',
      'verification_scope'
    ]);
    final state = _text(m['verification_state'], 100);
    if (!const [
      'reviewed_public_guidance',
      'ai_unverified',
      'user_edited_unverified',
      'no_verified_source'
    ].contains(state)) {
      throw const FormatException('Unknown verification state');
    }
    final sections = _strings(m['selected_sections'], 12, 4000, min: 1);
    if (sections.fold<int>(0, (n, s) => n + s.runes.length) > 16000) {
      throw const FormatException('Card body exceeds limit');
    }
    final p = CardPublicPayload(
        title: _text(m['title'], 240),
        selectedSections: sections,
        officialTerms: _strings(m['official_terms'], 10, 1000),
        missingInformation: _strings(m['missing_information'], 12, 4000),
        nextSteps: _strings(m['next_steps'], 10, 1000),
        publicSources: _list(m['public_sources'], 10)
            .map(AnswerCardSource.fromJson)
            .toList(),
        verificationState: state,
        verificationScope: _text(m['verification_scope'], 4000));
    if (utf8.encode(jsonEncode(p.toJson())).length > 65536 ||
        _renderedLength(p) > 30000) {
      throw const FormatException('Complete card exceeds limit');
    }
    return p;
  }
  Map<String, Object?> toJson() => {
        'title': title,
        'selected_sections': selectedSections,
        'official_terms': officialTerms,
        'missing_information': missingInformation,
        'next_steps': nextSteps,
        'public_sources':
            publicSources.map((s) => s.toJson()).toList(growable: false),
        'verification_state': verificationState,
        'verification_scope': verificationScope
      };
}

class AnswerCardTemplate {
  AnswerCardTemplate(
      {required this.templateId,
      required this.templateVersion,
      required this.templateHash,
      required this.language,
      required List<AnswerCardSection> sections,
      required this.publicPayload})
      : sections = List.unmodifiable(sections);
  final String templateId, templateHash, language;
  final int templateVersion;
  final List<AnswerCardSection> sections;
  final CardPublicPayload publicPayload;
  factory AnswerCardTemplate.fromJson(Object? raw) {
    final m = _object(raw, const [
      'template_id',
      'template_version',
      'template_hash',
      'language',
      'sections',
      'public_payload'
    ]);
    if (m['language'] != 'zh') {
      throw const FormatException('Unknown template language');
    }
    final sections = _list(m['sections'], 12, min: 1)
        .map(AnswerCardSection.fromJson)
        .toList();
    _unique(sections.map((s) => s.id));
    final payload = CardPublicPayload.fromJson(m['public_payload']);
    if (jsonEncode(sections.map((s) => s.text).toList()) !=
        jsonEncode(payload.selectedSections)) {
      throw const FormatException('Template body mismatch');
    }
    return AnswerCardTemplate(
        templateId: _text(m['template_id'], 120),
        templateVersion: _positive(m['template_version']),
        templateHash: _hash(m['template_hash']),
        language: 'zh',
        sections: sections,
        publicPayload: payload);
  }
}

/// The original text is an owner-only, unsaved RAM snapshot.
class AnswerCardDraftSnapshot {
  AnswerCardDraftSnapshot(
      {required this.sourceMessageId,
      required this.sourceHash,
      required this.originalText,
      required List<AnswerCardSection> sections,
      required List<AnswerCardSource> publicSources})
      : sections = List.unmodifiable(sections),
        publicSources = List.unmodifiable(publicSources);
  final String sourceMessageId, sourceHash, originalText;
  final List<AnswerCardSection> sections;
  final List<AnswerCardSource> publicSources;
  factory AnswerCardDraftSnapshot.fromJson(Object? raw) {
    final m = _object(raw, const [
      'source_message_id',
      'source_hash',
      'original_text',
      'sections',
      'public_sources',
      'selected_sections',
      'selected_source_ids'
    ]);
    if (_list(m['selected_sections'], 0).isNotEmpty ||
        _list(m['selected_source_ids'], 0).isNotEmpty) {
      throw const FormatException('Draft must start unselected');
    }
    // Original answers can have more sections than a card permits selecting.
    final sections = _list(m['sections'], null, min: 1).map((raw) {
      final s = _object(raw, const ['id', 'text']);
      return AnswerCardSection(
          id: _text(s['id'], 200), text: _text(s['text'], null));
    }).toList();
    _unique(sections.map((s) => s.id));
    return AnswerCardDraftSnapshot(
        sourceMessageId: _text(m['source_message_id'], 36),
        sourceHash: _hash(m['source_hash']),
        originalText: _text(m['original_text'], null),
        sections: sections,
        publicSources: _list(m['public_sources'], 10)
            .map(AnswerCardSource.fromJson)
            .toList());
  }
}

class OwnedAnswerCard {
  OwnedAnswerCard(
      {required this.id,
      required this.mode,
      required this.version,
      required this.publicPayload,
      required this.publicPayloadHash,
      required Map<String, Object?> provenance,
      required this.createdAt,
      required this.updatedAt})
      : provenance = Map<String, Object?>.unmodifiable(
            provenance.map((k, v) => MapEntry(k, _freeze(v))));
  final String id, mode, publicPayloadHash, createdAt, updatedAt;
  final int version;
  final CardPublicPayload publicPayload;
  final Map<String, Object?> provenance;
  factory OwnedAnswerCard.fromJson(Object? raw) {
    final m = _object(raw, const [
      'id',
      'mode',
      'version',
      'public_payload',
      'public_payload_hash',
      'provenance',
      'created_at',
      'updated_at'
    ]);
    final mode = m['mode'];
    if (mode != 'assistant_answer' && mode != 'public_template') {
      throw const FormatException('Unknown card mode');
    }
    final provenance = _object(m['provenance'], const [
      'origin_message_id',
      'origin_hash',
      'template_id',
      'template_version',
      'template_hash',
      'selected_original_excerpts'
    ]);
    if (mode == 'assistant_answer') {
      _text(provenance['origin_message_id'], 36);
      _hash(provenance['origin_hash']);
      if (provenance['template_id'] != null ||
          provenance['template_version'] != null ||
          provenance['template_hash'] != null) {
        throw const FormatException('Mixed origin provenance');
      }
    } else {
      _text(provenance['template_id'], 120);
      _positive(provenance['template_version']);
      _hash(provenance['template_hash']);
      if (provenance['origin_message_id'] != null ||
          provenance['origin_hash'] != null) {
        throw const FormatException('Mixed origin provenance');
      }
    }
    final excerpts =
        _list(provenance['selected_original_excerpts'], 12, min: 1);
    for (final raw in excerpts) {
      final e = _object(raw, const ['id', 'hash', 'edited']);
      _text(e['id'], 200);
      _hash(e['hash']);
      if (e['edited'] is! bool) {
        throw const FormatException('Invalid excerpt edit flag');
      }
    }
    _unique(excerpts.map((e) => (e as Map)['id'] as String));
    final payload = CardPublicPayload.fromJson(m['public_payload']);
    if (mode == 'assistant_answer' &&
        payload.verificationState == 'reviewed_public_guidance') {
      throw const FormatException('AI answer cannot be reviewed guidance');
    }
    return OwnedAnswerCard(
        id: _text(m['id'], 36),
        mode: mode as String,
        version: _positive(m['version']),
        publicPayload: payload,
        publicPayloadHash: _hash(m['public_payload_hash']),
        provenance: provenance,
        createdAt: _timestamp(m['created_at']),
        updatedAt: _timestamp(m['updated_at']));
  }
}

class AnswerCardDeleteReceipt {
  const AnswerCardDeleteReceipt(
      {required this.id, required this.version, required this.deleted});
  final String id;
  final int version;
  final bool deleted;
  factory AnswerCardDeleteReceipt.fromJson(Object? raw) {
    final m = _object(raw, const ['id', 'version', 'deleted']);
    if (m['deleted'] != true) {
      throw const FormatException('Invalid deletion receipt');
    }
    return AnswerCardDeleteReceipt(
        id: _text(m['id'], 36),
        version: _positive(m['version']),
        deleted: true);
  }
}

Map<String, Object?> _object(Object? raw, List<String> required,
    {List<String> optional = const []}) {
  if (raw is! Map ||
      raw.keys.any((k) =>
          k is! String || (!required.contains(k) && !optional.contains(k))) ||
      required.any((k) => !raw.containsKey(k))) {
    throw const FormatException('Invalid answer card object');
  }
  return Map<String, Object?>.from(raw);
}

String _text(Object? raw, int? max) {
  if (raw is! String ||
      raw.trim().isEmpty ||
      (max != null && raw.runes.length > max)) {
    throw const FormatException('Invalid answer card text');
  }
  return raw;
}

String _hash(Object? raw) {
  if (raw is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw)) {
    throw const FormatException('Invalid server hash');
  }
  return raw;
}

int _positive(Object? raw) {
  if (raw is! int || raw < 1) {
    throw const FormatException('Invalid card version');
  }
  return raw;
}

List<Object?> _list(Object? raw, int? max, {int min = 0}) {
  if (raw is! List || raw.length < min || (max != null && raw.length > max)) {
    throw const FormatException('Invalid answer card list');
  }
  return List<Object?>.from(raw);
}

List<String> _strings(Object? raw, int max, int textMax, {int min = 0}) =>
    _list(raw, max, min: min)
        .map((v) => _text(v, textMax))
        .toList(growable: false);
void _unique(Iterable<String> values) {
  final list = values.toList();
  if (list.toSet().length != list.length) {
    throw const FormatException('Duplicate card identifiers');
  }
}

String? _date(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
    throw const FormatException('Invalid source date');
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != raw) {
    throw const FormatException('Invalid source date');
  }
  return raw;
}

String _timestamp(Object? raw) {
  final s = _text(raw, 100);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$')
          .hasMatch(s) ||
      DateTime.tryParse(s) == null) {
    throw const FormatException('Invalid card timestamp');
  }
  _date(s.substring(0, 10));
  return s;
}

Object? _freeze(Object? raw) {
  if (raw is Map) {
    return Map<String, Object?>.unmodifiable(
        raw.map((k, v) => MapEntry(k as String, _freeze(v))));
  }
  if (raw is List) return List<Object?>.unmodifiable(raw.map(_freeze));
  return raw;
}

int _renderedLength(CardPublicPayload p) {
  final parts = <String>[
    p.title,
    ...p.selectedSections,
    '官方術語',
    ...p.officialTerms,
    '尚待確認',
    ...p.missingInformation,
    '下一步',
    ...p.nextSteps,
    '核實狀態：${p.verificationState}',
    '核實範圍：${p.verificationScope}'
  ];
  for (final s in p.publicSources) {
    parts.addAll([
      '${s.organisation}：${s.title}',
      s.url,
      '核對日期：${s.reviewedAt ?? '未提供'}',
      '檢索日期：${s.retrievedAt ?? '未提供'}',
      '生效日期：${s.effectiveDate ?? '未提供'}',
      '來源核實範圍：${s.verificationScope}'
    ]);
  }
  if (p.officialTerms.isEmpty) parts.add('官方術語：原回答未提供');
  if (p.nextSteps.isEmpty) parts.add('下一步：原回答未提供');
  return parts.join('\n\n').runes.length;
}
