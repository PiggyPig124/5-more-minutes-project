import 'package:flutter/material.dart';
import 'answer_card_editor.dart' show AnswerCardPreview;
import 'answer_card_sharing_api.dart';
import 'answer_card_sharing_controller.dart';
import 'localization.dart';
import 'models.dart' show FamilyInvitation;

String _sharingStatus(BuildContext context, String? status) => switch (status) {
  'shared' => tr(context, '已在應用程式內分享這張卡。', 'The card was shared in this app.'),
  'revoked' => tr(context, '已撤回。收件人不再有站內存取權。', 'Revoked. The recipient no longer has access in this app.'),
  'result_unconfirmed' => tr(context, '結果未確認。可明確重試同一次分享，或在發送紀錄核對。', 'The result is unconfirmed. Retry the same share explicitly, or check sent history.'),
  'conflict' => tr(context, '內容、版本或授權已變更。請返回並重新選擇、核對；不會自動再次發送。', 'The content, version or authorization changed. Return and select it again for fresh review; nothing is sent automatically.'),
  'authorization_changed' => tr(context, '家庭授權已變更。請返回並重新核對收件人。', 'Family authorization changed. Return and review the recipient again.'),
  _ => tr(context, '目前未能完成此操作。請稍後重試或取消。', 'This action could not be completed. Try again later or cancel.'),
};

/// Every route owns only its captured session and family authorization generation.
abstract class _SharingRouteState<T extends StatefulWidget> extends State<T> {
  AnswerCardSharingController get controller;
  late final int sessionGeneration;
  late final int familyGeneration;
  bool retired = false;
  ModalRoute<dynamic>? ownRoute;
  List<ModalRoute<dynamic>?> get ownRoutes => [ownRoute];
  bool get shouldRetire => false;
  bool get current => !retired && controller.generation == sessionGeneration &&
      controller.familyGeneration == familyGeneration;

  @override
  void initState() {
    super.initState();
    sessionGeneration = controller.generation;
    familyGeneration = controller.familyGeneration;
    controller.addListener(changed);
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ownRoute ??= ModalRoute.of(context);
  }
  void changed() {
    if (!mounted) return;
    if (!current || shouldRetire) retire();
    setState(() {});
  }
  void retire() {
    if (retired) return;
    retired = true;
    final routes = List.of(ownRoutes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final route in routes) {
        if (route != null && route.isActive && !route.isFirst) {
          route.navigator?.removeRoute(route);
        }
      }
    });
  }
  @override
  void dispose() {
    controller.removeListener(changed);
    super.dispose();
  }
}

class AnswerCardRecipientScreen extends StatefulWidget {
  const AnswerCardRecipientScreen({required this.controller, required this.card,
    required this.recipients, super.key});
  final AnswerCardSharingController controller;
  final OwnedAnswerCard card;
  final List<FamilyInvitation> recipients;
  @override
  State<AnswerCardRecipientScreen> createState() => _AnswerCardRecipientScreenState();
}

class _AnswerCardRecipientScreenState extends _SharingRouteState<AnswerCardRecipientScreen> {
  @override
  AnswerCardSharingController get controller => widget.controller;
  void _choose(FamilyInvitation recipient) {
    if (!current || controller.busy) return;
    if (!controller.prepareShare(widget.card, recipient)) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
      AnswerCardSharePreviewScreen(controller: controller)));
  }
  @override
  Widget build(BuildContext context) {
    final recipients = widget.recipients.where((link) => link.actionable && link.allowsFamilyMessages).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '選擇一位收件人', 'Choose one recipient'))),
      body: !current ? const SizedBox.shrink() : SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.card.publicPayload.title, style: Theme.of(context).textTheme.titleLarge),
          Text(tr(context, '只分享這張卡。請按電郵辨認收件人；不會自動選擇任何人。', 'Share only this card. Identify the recipient by email; nobody is selected automatically.')),
          if (controller.error != null) Text(_sharingStatus(context, controller.status)),
          if (recipients.isEmpty) Text(tr(context, '目前沒有可接收家庭訊息的已授權收件人。', 'There are no authorized recipients for family messages.')),
          for (var index = 0; index < recipients.length; index++)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(recipients[index].caregiverName ?? recipients[index].name ?? tr(context, '未提供姓名', 'Name not provided')),
                Text(recipients[index].caregiverEmail ?? recipients[index].email),
                FilledButton(key: ValueKey('card-share-recipient-$index'),
                  onPressed: controller.busy ? null : () => _choose(recipients[index]),
                  child: Text(tr(context, '選擇此收件人並核對', 'Choose this recipient and review'))),
              ],
            ))),
        ]),
      ),
    );
  }
}

class AnswerCardSharePreviewScreen extends StatefulWidget {
  const AnswerCardSharePreviewScreen({required this.controller, super.key});
  final AnswerCardSharingController controller;
  @override
  State<AnswerCardSharePreviewScreen> createState() => _AnswerCardSharePreviewScreenState();
}

class _AnswerCardSharePreviewScreenState extends _SharingRouteState<AnswerCardSharePreviewScreen> {
  late final int? _previewId;
  bool _sending = false;
  @override
  AnswerCardSharingController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _previewId = controller.preview?.previewId;
  }
  @override
  bool get shouldRetire => controller.preview?.previewId != _previewId;
  bool get _ownsPreview => current && _previewId != null && controller.preview?.previewId == _previewId;
  void _cancel() {
    if (_ownsPreview) controller.cancelPreview(expectedPreviewId: _previewId);
    retire();
    if (mounted) setState(() {});
  }
  Future<void> _send() async {
    if (!_ownsPreview || _sending || controller.busy) return;
    _sending = true;
    final shared = await controller.sendReviewedShare();
    _sending = false;
    if (!mounted || controller.generation != sessionGeneration ||
        controller.familyGeneration != familyGeneration || ownRoute?.isCurrent != true) {
      return;
    }
    if (shared) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_sharingStatus(context, 'shared'))));
      retire();
    }
    setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    final preview = _ownsPreview ? controller.preview : null;
    final frozen = ['result_unconfirmed', 'invalid_response', 'unavailable', 'conflict', 'authorization_changed'].contains(controller.status);
    return PopScope(canPop: true, onPopInvokedWithResult: (didPop, result) {
      if (didPop) _cancel();
    }, child: Scaffold(
      appBar: AppBar(title: Text(tr(context, '核對單卡分享', 'Review one-card share')),
        leading: BackButton(onPressed: _cancel)),
      body: preview == null ? Center(child: Text(tr(context, '分享預覽已清除。', 'Share preview cleared.'))) : SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr(context, '這次的收件人', 'Recipient for this share'), style: Theme.of(context).textTheme.titleMedium),
          Text(preview.recipientName ?? tr(context, '未提供姓名', 'Name not provided')),
          Text(preview.recipientEmail),
          Text(tr(context, '收件人只會看到下方選定卡片；不包含原對話或私人來源紀錄。', 'The recipient sees only the selected card below. The original conversation and private provenance are excluded.')),
          const SizedBox(height: 24),
          Text(tr(context, '完整卡片預覽', 'Complete card preview'), style: Theme.of(context).textTheme.titleLarge),
          AnswerCardPreview(payload: preview.publicPayload, mode: preview.mode),
          Text('${tr(context, '卡片版本', 'Card version')} ${preview.cardVersion}'),
          if (controller.error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_sharingStatus(context, controller.status))),
          if (controller.status == 'result_unconfirmed')
            Text(tr(context, '清除預覽不會撤回可能已送達的分享。可在發送紀錄核對並撤回。', 'Clearing the preview does not withdraw a share that may have arrived. Check sent history to withdraw it.')),
          CheckboxListTile(key: const ValueKey('card-share-review'), contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: preview.personalReviewAck,
            onChanged: controller.busy || frozen ? null : (value) => controller.acknowledgePersonalReview(value == true),
            title: Text(tr(context, '我已檢查整張卡中的個人資料，確認只向上述收件人分享此卡。', 'I reviewed personal information in the entire card and confirm sharing only this card with the recipient above.'))),
          FilledButton(key: const ValueKey('card-share-send'),
            onPressed: controller.busy || _sending || !preview.personalReviewAck ||
              ['conflict', 'authorization_changed', 'invalid_preview'].contains(controller.status) ? null : _send,
            child: Text(['result_unconfirmed', 'invalid_response', 'unavailable'].contains(controller.status)
              ? tr(context, '明確重試同一次分享', 'Retry the same share')
              : tr(context, '確認站內分享這張卡', 'Confirm sharing this card in app'))),
          OutlinedButton(key: const ValueKey('card-share-cancel'), onPressed: _cancel,
            child: Text(tr(context, '取消並清除分享預覽', 'Cancel and clear share preview'))),
        ]),
      ),
    ));
  }
  @override
  void dispose() {
    controller.removeListener(changed);
    if (_ownsPreview) controller.cancelPreview(expectedPreviewId: _previewId);
    super.dispose();
  }
}

class AnswerCardSharingScreen extends StatefulWidget {
  const AnswerCardSharingScreen({required this.controller, this.inbox = false, super.key});
  final AnswerCardSharingController controller;
  final bool inbox;
  @override
  State<AnswerCardSharingScreen> createState() => _AnswerCardSharingScreenState();
}

class _AnswerCardSharingScreenState extends _SharingRouteState<AnswerCardSharingScreen> {
  bool _withdrawing = false;
  ModalRoute<dynamic>? _dialogRoute;
  @override
  AnswerCardSharingController get controller => widget.controller;
  @override
  List<ModalRoute<dynamic>?> get ownRoutes => [_dialogRoute, ownRoute];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && current) _reload();
    });
  }
  Future<bool> _reload() => widget.inbox ? controller.loadInbox() : controller.loadSent();
  void _detail(String id) {
    if (!current || controller.busy) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
      _SharedAnswerCardDetailScreen(controller: controller, shareId: id, inbox: widget.inbox)));
  }
  Future<void> _retryWithdrawal() async {
    final pending = controller.pendingRevoke;
    if (pending == null || !current || ownRoute?.isCurrent != true ||
        controller.busy || _withdrawing) {
      return;
    }
    setState(() => _withdrawing = true);
    await controller.revokeShare(pending);
    _withdrawing = false;
    if (mounted && current) setState(() {});
  }
  Future<void> _withdraw(AnswerCardSentShare share) async {
    if (!current || controller.busy || _withdrawing || controller.pendingRevoke != null) return;
    _withdrawing = true;
    final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) {
      _dialogRoute = ModalRoute.of(dialogContext);
      return AnimatedBuilder(animation: controller, builder: (context, _) => AlertDialog(
        insetPadding: const EdgeInsets.all(12), title: Text(tr(context, '撤回這次分享？', 'Withdraw this share?')),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (current) ...[
              Text(share.publicPayload?.title ?? tr(context, '分享紀錄', 'Share record')),
              Text(tr(context, '收件人將失去這次分享的站內存取權；你的私人卡會保留。', 'The recipient loses access to this share in the app. Your private card remains.')),
            ],
            OutlinedButton(key: const ValueKey('card-share-withdraw-cancel'),
              onPressed: () {
                if (!current || _dialogRoute?.isCurrent != true) return;
                Navigator.of(dialogContext).pop(false);
              }, child: Text(tr(context, '取消', 'Cancel'))),
            FilledButton(key: const ValueKey('card-share-withdraw-confirm'),
              onPressed: current ? () {
                if (_dialogRoute?.isCurrent != true) return;
                Navigator.of(dialogContext).pop(true);
              } : null,
              child: Text(tr(context, '確認撤回', 'Confirm withdrawal'))),
          ])),
      ));
    });
    _dialogRoute = null;
    if (confirmed != true || !mounted || !current || ownRoute?.isCurrent != true) {
      _withdrawing = false;
      if (mounted) setState(() {});
      return;
    }
    await controller.revokeShare(share);
    _withdrawing = false;
    if (mounted && current) setState(() {});
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.inbox ? tr(context, '收到的答案卡', 'Received answer cards') : tr(context, '答案卡發送紀錄', 'Sent card history'))),
    body: !current ? const SizedBox.shrink() : SingleChildScrollView(
      padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.inbox ? tr(context, '這裡只顯示仍獲授權的分享快照。', 'Only currently authorized shared snapshots appear here.')
          : tr(context, '分享紀錄與私人卡分開。已撤回或已刪除的正文不會恢復。', 'Sent history is separate from private cards. Revoked or deleted bodies are not restored.')),
        if (controller.busy) const LinearProgressIndicator(),
        if (controller.error != null || ['shared', 'revoked'].contains(controller.status))
          Text(!widget.inbox && controller.pendingRevoke != null
            ? tr(context, '撤回結果尚未確認。請明確重試同一次撤回，或重新載入分享紀錄。', 'The withdrawal result is unconfirmed. Retry the same withdrawal explicitly, or reload sharing records.')
            : _sharingStatus(context, controller.status)),
        if (!widget.inbox && controller.pendingRevoke != null)
          OutlinedButton(key: const ValueKey('card-share-withdraw-retry'),
            onPressed: controller.busy || _withdrawing ? null : _retryWithdrawal,
            child: Text(tr(context, '重試同一次撤回', 'Retry the same withdrawal'))),
        if (widget.inbox) ...[
          if (controller.inbox.isEmpty) Text(tr(context, '目前沒有可讀取的分享卡。', 'No shared cards are available.')),
          for (final item in controller.inbox)
            Card(child: ListTile(title: Text(item.publicPayload.title),
              subtitle: Text('${tr(context, '卡片版本', 'Card version')} ${item.cardVersion}\n${item.createdAt}'),
              onTap: controller.busy ? null : () => _detail(item.id))),
        ] else ...[
          if (controller.sent.isEmpty) Text(tr(context, '目前沒有發送紀錄。', 'No sent records are available.')),
          for (var index = 0; index < controller.sent.length; index++)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(controller.sent[index].publicPayload?.title ?? tr(context, '已撤回的分享', 'Revoked share')),
              Text('${tr(context, '卡片版本', 'Card version')} ${controller.sent[index].cardVersion}'),
              Text(controller.sent[index].createdAt),
              if (controller.sent[index].accessRevokedAt != null || controller.sent[index].publicPayload == null) ...[
                Text(tr(context, '已撤回：正文不再可讀取。', 'Revoked: the body is no longer available.')),
                if (controller.sent[index].accessRevokedAt != null) Text(controller.sent[index].accessRevokedAt!),
              ] else ...[
                OutlinedButton(onPressed: controller.busy ? null : () => _detail(controller.sent[index].id),
                  child: Text(tr(context, '查看這次分享快照', 'View this shared snapshot'))),
                OutlinedButton(key: ValueKey('card-share-withdraw-$index'),
                  onPressed: controller.busy || _withdrawing || controller.pendingRevoke != null ? null : () => _withdraw(controller.sent[index]),
                  child: Text(tr(context, '撤回這次分享', 'Withdraw this share'))),
              ],
            ]))),
        ],
        OutlinedButton(key: const ValueKey('card-sharing-reload'), onPressed: controller.busy ? null : _reload,
          child: Text(tr(context, '重新載入分享紀錄', 'Reload sharing records'))),
      ])),
  );
}

class _SharedAnswerCardDetailScreen extends StatefulWidget {
  const _SharedAnswerCardDetailScreen({required this.controller, required this.shareId, required this.inbox});
  final AnswerCardSharingController controller;
  final String shareId;
  final bool inbox;
  @override
  State<_SharedAnswerCardDetailScreen> createState() => _SharedAnswerCardDetailScreenState();
}

class _SharedAnswerCardDetailScreenState extends _SharingRouteState<_SharedAnswerCardDetailScreen> {
  @override
  AnswerCardSharingController get controller => widget.controller;
  AnswerCardShare? get _inbox => controller.inbox.where((item) => item.id == widget.shareId).firstOrNull;
  AnswerCardSentShare? get _sent => controller.sent.where((item) => item.id == widget.shareId).firstOrNull;
  CardPublicPayload? get _payload => widget.inbox ? _inbox?.publicPayload :
    _sent?.accessRevokedAt == null ? _sent?.publicPayload : null;
  @override
  bool get shouldRetire => _payload == null;
  @override
  Widget build(BuildContext context) {
    final payload = current ? _payload : null;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '已分享的卡片快照', 'Shared card snapshot'))),
      body: payload == null ? const SizedBox.shrink() : SingleChildScrollView(
        padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AnswerCardPreview(payload: payload, mode: widget.inbox ? _inbox!.mode : _sent!.mode),
          Text('${tr(context, '卡片版本', 'Card version')} ${widget.inbox ? _inbox!.cardVersion : _sent!.cardVersion}'),
        ])),
    );
  }
}
