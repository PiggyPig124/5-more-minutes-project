import 'package:flutter/material.dart';
import 'localization.dart';
import 'content_simplification_api.dart';

/// Calls only the dedicated read-only service, never chat/tool/memory routes.
typedef ReadOnlySimplifier = Future<String> Function(String original);

class MessageContentActions extends StatefulWidget {
  const MessageContentActions(
      {required this.original,
      required this.sessionIdentity,
      this.simplify,
      this.contentVersion,
      this.requestTimeout = const Duration(seconds: 60),
      super.key});
  final String original;
  final Object sessionIdentity;
  final ReadOnlySimplifier? simplify;
  final Object? contentVersion;
  final Duration requestTimeout;
  @override
  State<MessageContentActions> createState() => _MessageContentActionsState();
}

class _MessageContentActionsState extends State<MessageContentActions> {
  bool _repeat = false, _loading = false, _failed = false, _confirming = false;
  bool _modelUnavailable = false;
  String? _simplified;
  int _request = 0;
  @override
  void didUpdateWidget(covariant MessageContentActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionIdentity != widget.sessionIdentity ||
        oldWidget.original != widget.original ||
        oldWidget.contentVersion != widget.contentVersion) {
      _reset();
    }
  }

  void _reset() {
    _request++;
    _repeat = false;
    _loading = false;
    _failed = false;
    _simplified = null;
    _confirming = false;
    _modelUnavailable = false;
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _simplify() async {
    final capability = widget.simplify;
    if (capability == null || _loading) return;
    final request = ++_request;
    final identity = widget.sessionIdentity;
    final original = widget.original;
    final version = widget.contentVersion;
    bool current() =>
        mounted &&
        request == _request &&
        identity == widget.sessionIdentity &&
        version == widget.contentVersion &&
        original == widget.original;
    setState(() {
      _loading = true;
      _failed = false;
      _simplified = null;
      _confirming = false;
      _modelUnavailable = false;
    });
    try {
      final text = await capability(original).timeout(widget.requestTimeout);
      if (!current()) return;
      if (text.trim().isEmpty) {
        throw const FormatException('empty simplification');
      }
      setState(() => _simplified = text);
    } catch (error) {
      if (current()) {
        setState(() {
          _failed = true;
          _modelUnavailable = error is ContentSimplificationException &&
              error.reason == 'model_unavailable';
        });
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.original.trim().isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 4, children: [
        OutlinedButton(
            key: const ValueKey('message-repeat'),
            onPressed: () => setState(() => _repeat = !_repeat),
            child: Text(_repeat
                ? tr(context, '收起重顯原文', 'Hide repeated answer')
                : tr(context, '再看原文', 'Repeat'))),
        OutlinedButton(
            key: const ValueKey('message-simplify'),
            onPressed: widget.simplify == null || _loading || _confirming
                ? null
                : () => setState(() {
                      _confirming = true;
                      _failed = false;
                      _simplified = null;
                    }),
            child: Text(tr(context, '用更簡單的說法', 'Explain more simply'))),
        if (_loading)
          TextButton(
              key: const ValueKey('message-simplify-cancel'),
              onPressed: () => setState(_reset),
              child: Text(tr(context, '取消', 'Cancel'))),
      ]),
      if (_confirming) ...[
        Text(tr(context, '只會把下方這段答案交給已設定的模型，產生未經獨立核實的易懂草稿。原文保留；不寫入記憶或聊天記錄。',
            'Only this selected answer will be sent to the configured model for an unverified simpler draft. The original stays; nothing is saved to memory or chat history.')),
        SelectableText(widget.original,
            key: const ValueKey('simplify-selected-original')),
        Wrap(spacing: 8, runSpacing: 4, children: [
          FilledButton(
              key: const ValueKey('simplify-consent-confirm'),
              onPressed: _simplify,
              child:
                  Text(tr(context, '同意處理這段答案', 'Use model for this answer'))),
          TextButton(
              key: const ValueKey('simplify-consent-cancel'),
              onPressed: () => setState(_reset),
              child: Text(tr(context, '取消', 'Cancel'))),
        ]),
      ],
      if (widget.simplify == null)
        Text(tr(context, '這裡暫未提供簡化說法；你可以重看原文。',
            'Simpler wording is not available here yet.')),
      if (_loading) ...[
        const LinearProgressIndicator(),
        Text(tr(context, '正在等候簡化版本；原文不會改動。',
            'Waiting for simpler wording; the original answer stays unchanged.'))
      ],
      if (_failed && _modelUnavailable)
        Text(tr(context, '目前沒有可用的已設定模型。原文保留，沒有儲存任何變更。',
            'The configured model is unavailable. The original remains; no changes were saved.')),
      if (_failed && !_modelUnavailable)
        Text(tr(context, '未能取得簡化版本。原文仍在，你可以重試或略過。',
            'Simpler wording could not be obtained. The original remains; you can retry or leave it.')),
      if (_simplified != null) ...[
        Text(
            tr(context, '簡化草稿（未獨立核實）',
                'Simpler draft (not independently checked)'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        SelectableText(_simplified!),
      ],
      if (_repeat || _simplified != null) ...[
        const SizedBox(height: 6),
        Text(
            tr(context, '原文（來源及安全提示仍適用）',
                'Original answer (sources and safety notes still apply)'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        SelectableText(widget.original,
            key: const ValueKey('message-original-copy')),
      ],
    ]);
  }
}
