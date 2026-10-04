import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'answer_card_api.dart';
import 'api_client.dart' show ApiException;

const _aiScope =
    'AI answer is not independently verified. Sources are references only.';

/// Unselected paragraphs and the original answer exist only in this RAM state.
class AnswerCardDraft {
  AnswerCardDraft._(
      {required this.draftId,
      required this.sessionGeneration,
      required this.title,
      required List<AnswerCardSection> sections,
      required Set<String> selectedSectionIds,
      required Set<String> selectedSourceIds,
      required List<AnswerCardSource> publicSources,
      required List<String> officialTerms,
      required List<String> missingInformation,
      required List<String> nextSteps,
      required this.mode,
      required this.isGuest,
      required this.reviewed,
      required this.operationKey,
      required this.verificationScope,
      required List<AnswerCardSection> originalSections,
      required Map<String, Object?> origin,
      this.originalText,
      this.template,
      this.owned})
      : sections = List.unmodifiable(sections),
        selectedSectionIds = Set.unmodifiable(selectedSectionIds),
        selectedSourceIds = Set.unmodifiable(selectedSourceIds),
        publicSources = List.unmodifiable(publicSources),
        officialTerms = List.unmodifiable(officialTerms),
        missingInformation = List.unmodifiable(missingInformation),
        nextSteps = List.unmodifiable(nextSteps),
        _originalSections = List.unmodifiable(originalSections),
        _origin = Map.unmodifiable(origin);
  final int draftId, sessionGeneration;
  final String title, mode, operationKey, verificationScope;
  final List<AnswerCardSection> sections;
  final Set<String> selectedSectionIds, selectedSourceIds;
  final List<AnswerCardSource> publicSources;
  final List<String> officialTerms, missingInformation, nextSteps;
  final bool isGuest, reviewed;
  bool get isEditing => owned != null;
  final String? originalText;
  final AnswerCardTemplate? template;
  final OwnedAnswerCard? owned;
  final List<AnswerCardSection> _originalSections;
  final Map<String, Object?> _origin;
  AnswerCardDraft _copy(
          {String? title,
          List<AnswerCardSection>? sections,
          Set<String>? selectedSectionIds,
          Set<String>? selectedSourceIds,
          List<String>? officialTerms,
          List<String>? missingInformation,
          List<String>? nextSteps,
          bool? reviewed}) =>
      AnswerCardDraft._(
          draftId: draftId,
          sessionGeneration: sessionGeneration,
          title: title ?? this.title,
          sections: sections ?? this.sections,
          selectedSectionIds: selectedSectionIds ?? this.selectedSectionIds,
          selectedSourceIds: selectedSourceIds ?? this.selectedSourceIds,
          publicSources: publicSources,
          officialTerms: officialTerms ?? this.officialTerms,
          missingInformation: missingInformation ?? this.missingInformation,
          nextSteps: nextSteps ?? this.nextSteps,
          mode: mode,
          isGuest: isGuest,
          reviewed: reviewed ?? false,
          operationKey: operationKey,
          verificationScope: verificationScope,
          originalSections: _originalSections,
          origin: _origin,
          originalText: originalText,
          template: template,
          owned: owned);
}

class AnswerCardController extends ChangeNotifier {
  AnswerCardController({AnswerCardApi? api}) : _api = api;
  final AnswerCardApi? _api;
  List<AnswerCardTemplate> _templates = [];
  List<OwnedAnswerCard> _cards = [];
  AnswerCardDraft? _draft;
  CardPublicPayload? _preview;
  String? _ownerId, _error, _status;
  Object? _sessionIdentity, _guestIdentity;
  int _generation = 0,
      _draftGeneration = 0,
      _cardGeneration = 0,
      _templateRead = 0,
      _cardRead = 0,
      _reads = 0,
      _keys = 0;
  int? _activePrepare;
  bool _mutation = false, _disposed = false;
  bool _deleteConflict = false;
  Map<String, Object?>? _pendingSave;
  ({
    String id,
    int version,
    String key,
    OwnedAnswerCard snapshot
  })? _pendingDelete;
  List<AnswerCardTemplate> get templates => List.unmodifiable(_templates);
  List<OwnedAnswerCard> get cards => List.unmodifiable(_cards);
  AnswerCardDraft? get draft => _draft;
  CardPublicPayload? get preview => _preview;
  bool get busy => _mutation || _reads > 0 || _activePrepare != null;
  bool get isGuest => _ownerId == null;
  String? get error => _error;
  String? get status => _status;
  int get generation => _generation;
  int get draftGeneration => _draftGeneration;
  bool get _pendingMutation => _pendingSave != null || _pendingDelete != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  String _key() =>
      'answer-card-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}-${++_keys}';
  void _failure(String status) {
    _status = status;
    _error =
        'The answer card operation could not be confirmed. Please review and try again.';
    _notify();
  }

  void bindSession(
      {required String? ownerId,
      required Object? sessionIdentity,
      Object? guestIdentity}) {
    if (_disposed ||
        (ownerId == _ownerId &&
            sessionIdentity == _sessionIdentity &&
            guestIdentity == _guestIdentity)) {
      return;
    }
    _ownerId = ownerId;
    _sessionIdentity = sessionIdentity;
    _guestIdentity = guestIdentity;
    _generation++;
    _draftGeneration++;
    _cardGeneration++;
    _templateRead++;
    _cardRead++;
    _templates = [];
    _cards = [];
    _draft = null;
    _preview = null;
    _pendingSave = null;
    _pendingDelete = null;
    _deleteConflict = false;
    _reads = 0;
    _activePrepare = null;
    _mutation = false;
    _error = null;
    _status = null;
    _notify();
  }

  Future<bool> loadTemplates() async {
    if (_disposed || _api == null) {
      if (!_disposed) _failure('unavailable');
      return false;
    }
    final generation = _generation, read = ++_templateRead;
    _reads++;
    if (!_pendingMutation) _error = null;
    _notify();
    try {
      final result = await _api.listAnswerCardTemplates();
      if (!_current(generation) || read != _templateRead) return false;
      _templates = List.of(result);
      if (!_pendingMutation) _status = null;
      return true;
    } catch (_) {
      if (_current(generation) && read == _templateRead && !_pendingMutation) {
        _failure('unavailable');
      }
      return false;
    } finally {
      if (_current(generation)) {
        _reads--;
        _notify();
      }
    }
  }

  Future<bool> loadCards() async {
    if (_disposed || isGuest || _api == null || _mutation) return false;
    final generation = _generation, epoch = _cardGeneration, read = ++_cardRead;
    _reads++;
    if (!_pendingMutation) _error = null;
    _notify();
    try {
      final result = await _api.listAnswerCards();
      if (!_current(generation) ||
          epoch != _cardGeneration ||
          read != _cardRead) {
        return false;
      }
      _cards = List.of(result);
      if (_deleteConflict) {
        _pendingDelete = null;
        _deleteConflict = false;
        _error = null;
      }
      final pending = _pendingDelete;
      if (pending != null) {
        // Keep the captured card reachable for an explicit retry of this exact
        // delete, even when a read returns a newer card or no longer lists it.
        _cards = [
          pending.snapshot,
          ..._cards.where((card) => card.id != pending.id)
        ];
      }
      if (!_pendingMutation) _status = null;
      return true;
    } catch (_) {
      if (_current(generation) &&
          epoch == _cardGeneration &&
          read == _cardRead &&
          !_pendingMutation) {
        _failure('unavailable');
      }
      return false;
    } finally {
      if (_current(generation)) {
        _reads--;
        _notify();
      }
    }
  }

  Future<bool> prepareFromMessage(String id) async {
    if (_disposed ||
        isGuest ||
        _api == null ||
        _mutation ||
        _pendingDelete != null) {
      return false;
    }
    final generation = _generation, epoch = ++_draftGeneration;
    _draft = null;
    _preview = null;
    _pendingSave = null;
    _activePrepare = epoch;
    _error = null;
    _status = null;
    _notify();
    try {
      final result = await _api.prepareAnswerCard(id);
      if (!_current(generation) || epoch != _draftGeneration) return false;
      if (result.sourceMessageId != id) {
        _failure('invalid_response');
        return false;
      }
      _draft = _newDraft(
          title: 'Answer card',
          sections: result.sections,
          sources: result.publicSources,
          mode: 'assistant_answer',
          scope: _aiScope,
          originalText: result.originalText,
          origin: {
            'message_id': result.sourceMessageId,
            'source_hash': result.sourceHash
          });
      return true;
    } catch (_) {
      if (_current(generation) && epoch == _draftGeneration) {
        _failure('unavailable');
      }
      return false;
    } finally {
      if (_current(generation) && _activePrepare == epoch) {
        _activePrepare = null;
        _notify();
      }
    }
  }

  AnswerCardDraft _newDraft(
          {required String title,
          required List<AnswerCardSection> sections,
          required List<AnswerCardSource> sources,
          required String mode,
          required String scope,
          Map<String, Object?> origin = const {},
          String? originalText,
          AnswerCardTemplate? template,
          OwnedAnswerCard? owned,
          List<String> terms = const [],
          List<String> missing = const [],
          List<String> steps = const [],
          bool selectAll = false}) =>
      AnswerCardDraft._(
          draftId: _draftGeneration,
          sessionGeneration: _generation,
          title: title,
          sections: sections,
          selectedSectionIds:
              selectAll ? sections.map((s) => s.id).toSet() : {},
          selectedSourceIds:
              selectAll ? sources.map((s) => s.sourceId).toSet() : {},
          publicSources: sources,
          officialTerms: terms,
          missingInformation: missing,
          nextSteps: steps,
          mode: mode,
          isGuest: isGuest,
          reviewed: false,
          operationKey: _key(),
          verificationScope: scope,
          originalSections: sections,
          origin: origin,
          originalText: originalText,
          template: template,
          owned: owned);
  void prepareGuestAnswer(String content) {
    if (_disposed || !isGuest || _mutation || content.trim().isEmpty) return;
    _draftGeneration++;
    _activePrepare = null;
    _pendingSave = null;
    _preview = null;
    _error = null;
    _status = null;
    final paragraphs = content
        .split(RegExp(r'\r?\n[\t ]*\r?\n'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    _draft = _newDraft(
        title: 'Answer card',
        sections: [
          for (var i = 0; i < paragraphs.length; i++)
            AnswerCardSection(id: 'ram:$i', text: paragraphs[i])
        ],
        sources: const [],
        mode: 'assistant_answer',
        scope: _aiScope,
        originalText: content);
    _notify();
  }

  void startTemplate(AnswerCardTemplate template) {
    if (_disposed || _mutation || _pendingDelete != null) return;
    _draftGeneration++;
    _activePrepare = null;
    _pendingSave = null;
    _preview = null;
    _error = null;
    _status = null;
    final p = template.publicPayload;
    _draft = _newDraft(
        title: p.title,
        sections: template.sections,
        sources: p.publicSources,
        mode: 'public_template',
        scope: p.verificationScope,
        origin: {
          'template_id': template.templateId,
          'template_version': template.templateVersion,
          'template_hash': template.templateHash
        },
        template: template,
        terms: p.officialTerms,
        missing: p.missingInformation,
        steps: p.nextSteps,
        selectAll: true);
    _notify();
  }

  void startEdit(OwnedAnswerCard card) {
    if (_disposed || isGuest || _mutation || _pendingDelete != null) return;
    _draftGeneration++;
    _activePrepare = null;
    _pendingSave = null;
    _preview = null;
    _error = null;
    _status = null;
    final p = card.publicPayload;
    _draft = _newDraft(
        title: p.title,
        sections: [
          for (var i = 0; i < p.selectedSections.length; i++)
            AnswerCardSection(id: 'saved:$i', text: p.selectedSections[i])
        ],
        sources: p.publicSources,
        mode: card.mode,
        scope: p.verificationScope,
        owned: card,
        terms: p.officialTerms,
        missing: p.missingInformation,
        steps: p.nextSteps,
        selectAll: true);
    _notify();
  }

  void _change(AnswerCardDraft Function(AnswerCardDraft) edit) {
    if (_disposed || _draft == null || _mutation || _pendingSave != null) {
      return;
    }
    _draft = edit(_draft!);
    _preview = null;
    _error = null;
    _status = null;
    _notify();
  }

  void setTitle(String value) => _change((d) => d._copy(title: value));
  void selectSection(String id, bool value) => _change((d) {
        if (!d.sections.any((s) => s.id == id)) return d;
        final ids = {...d.selectedSectionIds};
        value ? ids.add(id) : ids.remove(id);
        return d._copy(selectedSectionIds: ids);
      });
  void editSection(String id, String value) =>
      _change((d) => d._copy(sections: [
            for (final s in d.sections)
              s.id == id ? AnswerCardSection(id: id, text: value) : s
          ]));
  void selectSource(String id, bool value) => _change((d) {
        if (!d.publicSources.any((s) => s.sourceId == id)) return d;
        final ids = {...d.selectedSourceIds};
        value ? ids.add(id) : ids.remove(id);
        return d._copy(selectedSourceIds: ids);
      });
  void setOfficialTerms(List<String> value) =>
      _change((d) => d._copy(officialTerms: value));
  void setMissingInformation(List<String> value) =>
      _change((d) => d._copy(missingInformation: value));
  void setNextSteps(List<String> value) =>
      _change((d) => d._copy(nextSteps: value));
  CardPublicPayload _buildPreview(AnswerCardDraft d) {
    final selected =
        d.sections.where((s) => d.selectedSectionIds.contains(s.id)).toList();
    final sources = d.publicSources
        .where((s) => d.selectedSourceIds.contains(s.sourceId))
        .toList();
    final originals = {for (final s in d._originalSections) s.id: s.text};
    var edited = d.isEditing || selected.any((s) => s.text != originals[s.id]);
    bool complete = false;
    if (d.template != null) {
      final base = d.template!.publicPayload;
      edited = edited ||
          d.title != base.title ||
          !listEquals(
              selected.map((s) => s.text).toList(), base.selectedSections) ||
          !listEquals(d.officialTerms, base.officialTerms) ||
          !listEquals(d.missingInformation, base.missingInformation) ||
          !listEquals(d.nextSteps, base.nextSteps);
      complete = !edited &&
          _same(sources.map((s) => s.toJson()).toList(),
              base.publicSources.map((s) => s.toJson()).toList());
    } else if (!d.isEditing) {
      edited = edited ||
          d.officialTerms.isNotEmpty ||
          d.missingInformation.isNotEmpty ||
          d.nextSteps.isNotEmpty;
    }
    final state = sources.isEmpty
        ? 'no_verified_source'
        : edited
            ? 'user_edited_unverified'
            : d.mode == 'assistant_answer'
                ? 'ai_unverified'
                : complete
                    ? 'reviewed_public_guidance'
                    : 'no_verified_source';
    final result = CardPublicPayload(
        title: d.title,
        selectedSections: selected.map((s) => s.text).toList(),
        officialTerms: d.officialTerms,
        missingInformation: d.missingInformation,
        nextSteps: d.nextSteps,
        publicSources: sources,
        verificationState: state,
        verificationScope: d.verificationScope);
    return CardPublicPayload.fromJson(result.toJson());
  }

  bool reviewDraft() {
    if (_disposed || _draft == null || _mutation) return false;
    try {
      _preview = _buildPreview(_draft!);
      _draft = _draft!._copy(reviewed: true);
      _status = 'reviewed';
      _error = null;
      _notify();
      return true;
    } catch (_) {
      _preview = null;
      _draft = _draft!._copy();
      _failure('invalid_draft');
      return false;
    }
  }

  void editBack() {
    if (_disposed || _mutation || _pendingSave != null) return;
    _preview = null;
    _draft = _draft?._copy();
    _status = null;
    _error = null;
    _notify();
  }

  void cancelDraft({int? expectedDraftId, int? expectedDraftGeneration}) {
    if (_disposed ||
        (expectedDraftId != null && expectedDraftId != _draft?.draftId) ||
        (expectedDraftGeneration != null &&
            expectedDraftGeneration != _draftGeneration)) {
      return;
    }
    _draftGeneration++;
    _activePrepare = null;
    _draft = null;
    _preview = null;
    _pendingSave = null;
    _error = null;
    _status = null;
    _notify();
  }

  Map<String, Object?> _request(AnswerCardDraft d, CardPublicPayload p) {
    final common = <String, Object?>{
      'title': p.title,
      'official_terms': p.officialTerms,
      'missing_information': p.missingInformation,
      'next_steps': p.nextSteps,
      'selected_source_ids': p.publicSources.map((s) => s.sourceId).toList(),
      'client_operation_id': d.operationKey
    };
    if (d.owned != null) {
      return {
        ...common,
        'selected_sections': p.selectedSections,
        'expected_version': d.owned!.version
      };
    }
    final original = {for (final s in d._originalSections) s.id: s.text};
    return {
      ...common,
      'origin': d._origin,
      'selected_sections': [
        for (final s
            in d.sections.where((s) => d.selectedSectionIds.contains(s.id)))
          <String, Object?>{
            'id': s.id,
            if (s.text != original[s.id]) 'edited_text': s.text
          }
      ]
    };
  }

  Future<bool> saveReviewedDraft() async {
    final d = _draft, p = _preview;
    if (_disposed ||
        _mutation ||
        _pendingDelete != null ||
        d == null ||
        p == null ||
        !d.reviewed) {
      return false;
    }
    if (isGuest || _api == null) {
      _failure(isGuest ? 'guest_only' : 'unavailable');
      return false;
    }
    final generation = _generation, epoch = _draftGeneration;
    final request = _pendingSave ??= _request(d, p);
    _mutation = true;
    _cardGeneration++;
    _error = null;
    _status = null;
    _notify();
    try {
      final result = d.owned == null
          ? await _api.createAnswerCard(request)
          : await _api.updateAnswerCard(d.owned!.id, request);
      if (!_current(generation) || epoch != _draftGeneration) return false;
      if (!_matches(result, d, p)) {
        _failure('invalid_response');
        return false;
      }
      _cards = [result, ..._cards.where((card) => card.id != result.id)];
      _draft = null;
      _preview = null;
      _pendingSave = null;
      _draftGeneration++;
      _status = 'saved';
      _error = null;
      return true;
    } catch (e) {
      if (_current(generation) && epoch == _draftGeneration) {
        _mutationFailure(e);
      }
      return false;
    } finally {
      if (_current(generation)) {
        _mutation = false;
        _notify();
      }
    }
  }

  bool _matches(
      OwnedAnswerCard result, AnswerCardDraft d, CardPublicPayload p) {
    if (result.mode != d.mode ||
        result.version != (d.owned?.version ?? 0) + 1 ||
        result.id.trim().isEmpty ||
        (d.owned != null && result.id != d.owned!.id) ||
        !_same(result.publicPayload.toJson(), p.toJson())) {
      return false;
    }
    final provenance = result.provenance;
    if (d.owned != null) {
      final expected = {
        ...d.owned!.provenance,
        'selected_original_excerpts': [
          for (final entry
              in d.owned!.provenance['selected_original_excerpts'] as List)
            {...entry as Map, 'edited': true}
        ]
      };
      return _same(provenance, expected);
    }
    if (d.mode == 'assistant_answer') {
      if (provenance['origin_message_id'] != d._origin['message_id'] ||
          provenance['origin_hash'] != d._origin['source_hash'] ||
          provenance['template_id'] != null ||
          provenance['template_version'] != null ||
          provenance['template_hash'] != null) {
        return false;
      }
    } else if (provenance['template_id'] != d._origin['template_id'] ||
        provenance['template_version'] != d._origin['template_version'] ||
        provenance['template_hash'] != d._origin['template_hash'] ||
        provenance['origin_message_id'] != null ||
        provenance['origin_hash'] != null) {
      return false;
    }
    final excerpts = provenance['selected_original_excerpts'];
    final selected =
        d.sections.where((s) => d.selectedSectionIds.contains(s.id)).toList();
    if (excerpts is! List || excerpts.length != selected.length) return false;
    final original = {for (final s in d._originalSections) s.id: s.text};
    for (var i = 0; i < selected.length; i++) {
      final entry = excerpts[i];
      if (entry is! Map ||
          entry['id'] != selected[i].id ||
          entry['edited'] != (selected[i].text != original[selected[i].id]) ||
          entry['hash'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry['hash'] as String)) {
        return false;
      }
    }
    return true;
  }

  void _mutationFailure(Object e) {
    if (e is ApiException && (e.statusCode == 409 || e.statusCode == 410)) {
      _failure('conflict');
    } else if (e is ApiException &&
        e.statusCode != null &&
        e.statusCode! >= 500 &&
        e.statusCode! <= 599) {
      // A server error can follow a committed mutation. Keep the captured
      // request available for an explicit retry with its original operation key.
      _failure('result_unconfirmed');
    } else if (e is ApiException && e.statusCode != null) {
      _failure('unavailable');
    } else if (e is FormatException) {
      _failure('invalid_response');
    } else {
      _failure('result_unconfirmed');
    }
  }

  Future<bool> deleteCard(OwnedAnswerCard card) async {
    if (_disposed ||
        isGuest ||
        _api == null ||
        _mutation ||
        _pendingSave != null) {
      return false;
    }
    final pending = _pendingDelete;
    if (pending != null &&
        (pending.id != card.id || pending.version != card.version)) {
      _failure('result_unconfirmed');
      return false;
    }
    final operation = _pendingDelete ??=
        (id: card.id, version: card.version, key: _key(), snapshot: card);
    final generation = _generation;
    _mutation = true;
    _deleteConflict = false;
    _cardGeneration++;
    _error = null;
    _status = null;
    _notify();
    try {
      final result = await _api.deleteAnswerCard(
          cardId: operation.id,
          expectedVersion: operation.version,
          clientOperationId: operation.key);
      if (!_current(generation)) return false;
      if (result.id != operation.id ||
          result.version != operation.version + 1 ||
          !result.deleted) {
        _failure('invalid_response');
        return false;
      }
      _cards = _cards.where((value) => value.id != operation.id).toList();
      _pendingDelete = null;
      _deleteConflict = false;
      if (_draft?.owned?.id == operation.id) {
        _draft = null;
        _preview = null;
        _draftGeneration++;
      }
      _status = 'deleted';
      _error = null;
      return true;
    } catch (e) {
      if (_current(generation)) {
        _deleteConflict =
            e is ApiException && (e.statusCode == 409 || e.statusCode == 410);
        _mutationFailure(e);
      }
      return false;
    } finally {
      if (_current(generation)) {
        _mutation = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _draftGeneration++;
    _activePrepare = null;
    _draft = null;
    _preview = null;
    _cards = [];
    _templates = [];
    _pendingSave = null;
    _pendingDelete = null;
    super.dispose();
  }
}

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_sorted(a)) == jsonEncode(_sorted(b));
