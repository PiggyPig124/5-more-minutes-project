import 'package:flutter/material.dart';

import 'localization.dart';
import 'speech_input.dart';

/// Opt-in speech adds editable draft text. Sending remains the composer's job.
class VoiceDraftButton extends StatefulWidget {
  const VoiceDraftButton(
      {super.key,
      required this.voiceController,
      required this.draftController,
      required this.onDraftChanged,
      this.canAcceptTranscript,
      this.enabled = true});

  final VoiceInputController voiceController;
  final TextEditingController draftController;
  final ValueChanged<String> onDraftChanged;
  final bool Function()? canAcceptTranscript;
  final bool enabled;

  @override
  State<VoiceDraftButton> createState() => _VoiceDraftButtonState();
}

class _VoiceDraftButtonState extends State<VoiceDraftButton> {
  bool _accepted = false;
  bool _busy = false;
  int _generation = 0;
  String? _lastNotice;
  bool get _acceptsTranscript =>
      widget.enabled && (widget.canAcceptTranscript?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.voiceController.addListener(_voiceChanged);
  }

  @override
  void didUpdateWidget(covariant VoiceDraftButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.voiceController != widget.voiceController ||
        oldWidget.draftController != widget.draftController ||
        (oldWidget.enabled && !widget.enabled)) {
      _generation++;
      oldWidget.voiceController.removeListener(_voiceChanged);
      oldWidget.voiceController.detach();
      widget.voiceController.addListener(_voiceChanged);
      _busy = false;
      _lastNotice = null;
      if (oldWidget.voiceController != widget.voiceController) {
        _accepted = false;
      }
    }
  }

  void _voiceChanged() {
    if (!mounted || !widget.enabled) return;
    setState(() {});
    final notice = widget.voiceController.notice;
    if (notice == null || notice == _lastNotice) return;
    _lastNotice = notice;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !widget.enabled) return;
      _showNotice(notice);
    });
  }

  void _showNotice(String notice) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(
          '$notice ${tr(context, '你仍然可以打字，並在傳送前修改文字。', 'You can still type and edit before sending.')}'),
    ));
  }

  Future<void> _toggle() async {
    if (_busy || !_acceptsTranscript) return;
    final generation = _generation;
    final voice = widget.voiceController;
    final canAcceptTranscript = widget.canAcceptTranscript;
    bool stillCurrent() =>
        widget.enabled && (canAcceptTranscript?.call() ?? true);
    setState(() => _busy = true);
    try {
      if (!_accepted) {
        final accepted = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                  title: Text(tr(context, '廣東話語音輸入', 'Cantonese voice input')),
                  content: SingleChildScrollView(
                      child: Text(tr(
                          context,
                          '語音辨識由你的裝置或瀏覽器提供。咪高峰音訊會由該語音服務按照其供應商的資料政策處理；安心只接收辨識文字。請在傳送前檢查並修改文字。你也可以隨時打字。',
                          "Speech recognition is provided by your device or browser. Microphone audio is processed by that speech service under its provider's data policy; Anxin receives only the recognized text. Review and edit the transcript before sending. You can always type."))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: Text(tr(context, '取消', 'Cancel'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: Text(tr(context, '繼續', 'Continue'))),
                  ],
                ));
        if (accepted != true ||
            !mounted ||
            generation != _generation ||
            !stillCurrent()) {
          return;
        }
        _accepted = true;
      }
      var prefix = widget.draftController.text.trim();
      var previous = widget.draftController.text;
      await voice.toggle(onTranscript: (transcript) {
        if (!mounted || generation != _generation || !stillCurrent()) return;
        // Preserve a manual edit made while the recognizer is still listening.
        final current = widget.draftController.text;
        if (current != previous) prefix = current.trim();
        final updated = prefix.isEmpty ? transcript : '$prefix $transcript';
        previous = updated;
        widget.draftController.value = TextEditingValue(
            text: updated,
            selection: TextSelection.collapsed(offset: updated.length));
        widget.onDraftChanged(updated);
      });
      // The shared controller owns cancellation. An old widget continuation
      // must never cancel a newer composer's session on that controller.
    } on Object {
      if (mounted && generation == _generation && widget.enabled) {
        _showNotice(tr(context, '未能啟動語音輸入。請檢查咪高峰權限並重試。',
            'Voice input could not start. Check microphone permission and try again.'));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final listening = widget.voiceController.isListening;
    return IconButton(
      key: const Key('voice-draft-button'),
      tooltip: listening
          ? tr(context, '停止語音輸入', 'Stop voice input')
          : tr(context, '廣東話語音輸入（可修改）', 'Cantonese voice input (editable)'),
      onPressed: _busy ? null : _toggle,
      icon:
          Icon(listening ? Icons.stop_circle_outlined : Icons.mic_none_rounded),
    );
  }

  @override
  void dispose() {
    _generation++;
    widget.voiceController.removeListener(_voiceChanged);
    widget.voiceController.detach();
    super.dispose();
  }
}
