import 'package:flutter/material.dart';
import 'answer_card_controller.dart';
import 'answer_card_models.dart';
import 'answer_card_editor.dart';
import 'localization.dart';
import 'answer_card_export_api.dart';
import 'answer_card_export_screen.dart';

class AnswerCardsScreen extends StatefulWidget {
  const AnswerCardsScreen({required this.controller, this.exportApi,
    this.openInbox, this.openSent, this.onShare, super.key});
  final AnswerCardController controller;
  final AnswerCardExportApi? exportApi;
  final VoidCallback? openInbox, openSent;
  final void Function(BuildContext, OwnedAnswerCard)? onShare;
  @override
  State<AnswerCardsScreen> createState() => _AnswerCardsScreenState();
}

class _AnswerCardsScreenState extends State<AnswerCardsScreen> {
  late final int _generation;
  bool _retired = false;
  ModalRoute<dynamic>? _route;
  @override
  void initState() {
    super.initState();
    _generation = widget.controller.generation;
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _retired) return;
      widget.controller.loadTemplates();
      if (!widget.controller.isGuest) widget.controller.loadCards();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  void _changed() {
    if (!mounted) return;
    if (widget.controller.generation != _generation) {
      _retired = true;
      final route = _route;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || route == null || !route.isActive) return;
        final navigator = route.navigator;
        if (navigator != null && navigator.canPop()) {
          navigator.removeRoute(route);
        }
      });
    }
    setState(() {});
  }

  void _template(AnswerCardTemplate template) {
    if (_retired || widget.controller.busy) return;
    final previousDraftGeneration = widget.controller.draftGeneration;
    widget.controller.startTemplate(template);
    if (widget.controller.draft != null &&
        widget.controller.draftGeneration != previousDraftGeneration) {
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              AnswerCardEditorScreen(controller: widget.controller)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '答案卡', 'Answer cards'))),
      body: _retired
          ? Center(child: Text(tr(context, '帳戶已變更。', 'Account changed.')))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.openInbox != null) OutlinedButton(
                      key: const ValueKey('card-inbox-entry'), onPressed: widget.openInbox,
                      child: Text(tr(context, '收到的答案卡', 'Received answer cards'))),
                    if (widget.openSent != null) OutlinedButton(
                      key: const ValueKey('card-sent-entry'), onPressed: widget.openSent,
                      child: Text(tr(context, '答案卡分享紀錄', 'Answer card sharing history'))),
                    Text(tr(context, '公共服務範本', 'Public service templates'),
                        style: Theme.of(context).textTheme.titleLarge),
                    Text(tr(context, '範本內容為中文；英文全文未另行核對。',
                        'Template content is Chinese; an English version has not been reviewed.')),
                    if (controller.busy) const LinearProgressIndicator(),
                    if (controller.error != null ||
                        ['saved', 'deleted', 'result_unconfirmed', 'conflict']
                            .contains(controller.status))
                      Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(answerCardStatusText(
                              context, controller.status))),
                    for (final template in controller.templates)
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(template.publicPayload.title),
                                    Text(answerCardVerificationText(
                                        context,
                                        template
                                            .publicPayload.verificationState)),
                                    FilledButton(
                                        onPressed: controller.busy
                                            ? null
                                            : () => _template(template),
                                        child: Text(tr(context, '選擇此範本',
                                            'Choose this template'))),
                                  ]))),
                    OutlinedButton(
                        key: const ValueKey('card-refresh-templates'),
                        onPressed:
                            controller.busy ? null : controller.loadTemplates,
                        child: Text(tr(context, '重新載入範本', 'Reload templates'))),
                    const SizedBox(height: 24),
                    Text(tr(context, '我的私人卡', 'My private cards'),
                        style: Theme.of(context).textTheme.titleLarge),
                    Text(tr(context, '已儲存的卡是獨立副本；刪除原對話不會刪除此卡，可在此單獨刪除。',
                        'Saved cards are independent copies. Deleting the conversation does not delete a card; delete it separately here.')),
                    if (controller.isGuest)
                      Text(answerCardStatusText(context, 'guest_only')),
                    if (!controller.isGuest && controller.cards.isEmpty)
                      Text(tr(context, '尚未有私人卡。從一則已完成的 AI 回答或公共範本開始。',
                          'No private cards yet. Start from a completed AI answer or a public template.')),
                    if (!controller.isGuest) ...[
                      for (final card in controller.cards)
                        Card(
                            child: ListTile(
                          title: Text(card.publicPayload.title),
                          subtitle: Text(
                              '${tr(context, '版本', 'Version')} ${card.version}\n${answerCardVerificationText(context, card.publicPayload.verificationState)}'),
                          onTap: controller.busy
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) => _PrivateAnswerCardScreen(
                                          controller: controller, card: card,
                                          exportApi: widget.exportApi, onShare: widget.onShare))),
                        )),
                      OutlinedButton(
                          key: const ValueKey('card-refresh-private'),
                          onPressed:
                              controller.busy ? null : controller.loadCards,
                          child: Text(
                              tr(context, '重新載入私人卡', 'Reload private cards'))),
                    ],
                  ]),
            ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }
}

class _PrivateAnswerCardScreen extends StatefulWidget {
  const _PrivateAnswerCardScreen(
      {required this.controller, required this.card, this.exportApi, this.onShare});
  final AnswerCardController controller;
  final OwnedAnswerCard card;
  final AnswerCardExportApi? exportApi;
  final void Function(BuildContext, OwnedAnswerCard)? onShare;
  @override
  State<_PrivateAnswerCardScreen> createState() =>
      _PrivateAnswerCardScreenState();
}

class _PrivateAnswerCardScreenState extends State<_PrivateAnswerCardScreen> {
  late final int _generation;
  bool _retired = false;
  bool _deleting = false;
  ModalRoute<dynamic>? _route;
  ModalRoute<dynamic>? _dialogRoute;
  OwnedAnswerCard? get _card => widget.controller.cards
      .where((card) => card.id == widget.card.id)
      .firstOrNull;
  @override
  void initState() {
    super.initState();
    _generation = widget.controller.generation;
    widget.controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  void _removeOwnRoutes() {
    final routes = [_dialogRoute, _route];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final route in routes) {
        if (route != null && route.isActive && route.navigator!.canPop()) {
          route.navigator!.removeRoute(route);
        }
      }
    });
  }

  void _changed() {
    if (!mounted) return;
    if (widget.controller.generation != _generation || _card == null) {
      _retired = true;
      _removeOwnRoutes();
    }
    setState(() {});
  }

  Future<void> _delete() async {
    if (_retired || _deleting || widget.controller.busy) return;
    final captured = _card;
    if (captured == null) return;
    _deleting = true;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          _dialogRoute = ModalRoute.of(dialogContext);
          return AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => AlertDialog(
                    insetPadding: const EdgeInsets.all(12),
                    title: Text(tr(context, '刪除私人卡？', 'Delete private card?')),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          if (!_retired) ...[
                            Text(captured.publicPayload.title),
                            Text(tr(context, '此操作會清除這張私人卡的正文，無法復原。原對話不會因此刪除。',
                                'This clears the private card body and cannot be undone. The original conversation remains.')),
                          ],
                          OutlinedButton(
                              key: const ValueKey('card-delete-cancel'),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              child: Text(tr(context, '取消', 'Cancel'))),
                          FilledButton(
                              key: const ValueKey('card-delete-confirm'),
                              onPressed: _retired
                                  ? null
                                  : () => Navigator.of(dialogContext).pop(true),
                              child: Text(
                                  tr(context, '確認刪除', 'Confirm deletion'))),
                        ])),
                  ));
        });
    _dialogRoute = null;
    if (confirmed != true ||
        !mounted ||
        _retired ||
        widget.controller.generation != _generation) {
      _deleting = false;
      if (mounted) setState(() {});
      return;
    }
    final deleted = await widget.controller.deleteCard(captured);
    _deleting = false;
    if (!mounted || _retired || widget.controller.generation != _generation) {
      return;
    }
    if (deleted) {
      _retired = true;
      _removeOwnRoutes();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final card = _card;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '私人答案卡', 'Private answer card'))),
      body: _retired || card == null
          ? const SizedBox.shrink()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnswerCardPreview(
                        payload: card.publicPayload, mode: card.mode),
                    Text('${tr(context, '版本', 'Version')} ${card.version}'),
                    if (controller.error != null)
                      Text(answerCardStatusText(context, controller.status)),
                    if (controller.status == 'conflict')
                      OutlinedButton(
                          key: const ValueKey('card-detail-reload'),
                          onPressed:
                              controller.busy ? null : controller.loadCards,
                          child: Text(tr(context, '重新載入並核對私人卡',
                              'Reload private cards for fresh review'))),
                    const SizedBox(height: 24),
                    if (widget.exportApi != null) OutlinedButton(
                      key: const ValueKey('card-private-export'),
                      onPressed: controller.busy || _deleting ? null : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => AnswerCardExportScreen(
                          controller: controller, api: widget.exportApi, card: card))),
                      child: Text(tr(context, '匯出這張卡', 'Export this card'))),
                    if (widget.onShare != null) OutlinedButton(
                      key: const ValueKey('card-private-share'),
                      onPressed: controller.busy || _deleting ? null : () => widget.onShare!(context, card),
                      child: Text(tr(context, '向一位家人分享這張卡', 'Share this card with one family member'))),
                    FilledButton(
                        key: const ValueKey('card-private-edit'),
                        onPressed: controller.busy || _deleting
                            ? null
                            : () {
                                final previousDraftGeneration =
                                    controller.draftGeneration;
                                controller.startEdit(card);
                                if (controller.draft != null &&
                                    controller.draftGeneration !=
                                        previousDraftGeneration) {
                                  Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                          builder: (_) =>
                                              AnswerCardEditorScreen(
                                                  controller: controller)));
                                }
                              },
                        child: Text(tr(context, '編輯私人卡', 'Edit private card'))),
                    OutlinedButton(
                        key: const ValueKey('card-private-delete'),
                        onPressed:
                            controller.busy || _deleting ? null : _delete,
                        child:
                            Text(tr(context, '刪除私人卡', 'Delete private card'))),
                  ]),
            ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }
}
