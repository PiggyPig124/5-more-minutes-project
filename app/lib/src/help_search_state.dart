import 'package:flutter/foundation.dart';

import 'models.dart';

enum HelpSearchPhase { idle, loading, success, error }

/// Ordinary Help only. API requests are read-only; cancellation discards results.
class HelpSearchState {
  HelpSearchPhase phase = HelpSearchPhase.idle;
  String submittedQuery = '';
  List<ResourceItem> items = const [];
  String? retrievalMode;
  int _generation = 0;
  Object? _scope;

  bool get isLoading => phase == HelpSearchPhase.loading;

  Object openScope() {
    reset();
    return _scope = Object();
  }

  void closeScope(Object scope) {
    if (!identical(scope, _scope)) return;
    reset();
    _scope = null;
  }

  void reset() {
    ++_generation;
    phase = HelpSearchPhase.idle;
    submittedQuery = '';
    items = const [];
    retrievalMode = null;
  }

  Future<void> search(
    String query, {
    required Future<ResourceSearchResult> Function(String) load,
    required bool Function() sessionCurrent,
    required VoidCallback changed,
    Object? scope,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty ||
        !sessionCurrent() ||
        (scope != null && !identical(scope, _scope))) {
      return;
    }
    if (isLoading && submittedQuery == trimmed) return;
    final generation = ++_generation;
    bool current() =>
        generation == _generation &&
        sessionCurrent() &&
        (scope == null || identical(scope, _scope));
    phase = HelpSearchPhase.loading;
    submittedQuery = trimmed;
    items = const [];
    retrievalMode = null;
    changed();
    try {
      final result = await load(trimmed);
      if (!current()) return;
      items = List.unmodifiable(result.items);
      retrievalMode = result.retrievalMode;
      phase = HelpSearchPhase.success;
    } on Object {
      if (!current()) return;
      phase = HelpSearchPhase.error;
    }
    if (current()) changed();
  }
}
