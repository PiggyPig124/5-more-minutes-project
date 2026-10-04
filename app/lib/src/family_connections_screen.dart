import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart'
    show appControllerProvider, LegacyFamilyInvitesScreen, FamilyMessagesScreen;
import 'app_controller.dart';
import 'models.dart';
import 'localization.dart';

/// Captures the reviewed identity. Permissions always start unchecked.
class FamilyActionDialog extends StatefulWidget {
  const FamilyActionDialog(
      {required this.title,
      required this.identity,
      required this.impact,
      required this.confirmLabel,
      required this.isCurrent,
      this.approval = false,
      super.key});
  final String title, identity, impact, confirmLabel;
  final bool approval;
  final bool Function() isCurrent;
  @override
  State<FamilyActionDialog> createState() => _FamilyActionDialogState();
}

class _FamilyActionDialogState extends State<FamilyActionDialog> {
  final _scopes = <String>{};
  @override
  Widget build(BuildContext context) => Consumer(builder: (context, ref, _) {
        ref.watch(appControllerProvider);
        final current = widget.isCurrent();
        return AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          title: Text(widget.title),
          content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.identity),
                  const SizedBox(height: 12),
                  Text(widget.impact),
                  if (widget.approval) ...[
                    for (final scope in ['care_tasks', 'family_messages'])
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _scopes.contains(scope),
                          title: Text(scope == 'care_tasks'
                              ? tr(context, '分享照護任務（每次分享仍需確認）',
                                  'Shared care tasks (each share still needs confirmation)')
                              : tr(context, '家庭訊息', 'Family messages')),
                          onChanged: current
                              ? (value) => setState(() {
                                    if (value == true) {
                                      _scopes.add(scope);
                                    } else {
                                      _scopes.remove(scope);
                                    }
                                  })
                              : null),
                    Text(tr(context, '至少選擇一項權限後，再明確確認批准。',
                        'Choose at least one permission, then explicitly confirm approval.')),
                  ],
                  if (!current)
                    Text(tr(context, '狀態已變更。請關閉並重新整理。',
                        'State changed. Close and refresh before continuing.')),
                  const SizedBox(height: 18),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(tr(context, '取消', 'Cancel'))),
                    FilledButton(
                        key: const ValueKey('family-confirm'),
                        onPressed:
                            current && (!widget.approval || _scopes.isNotEmpty)
                                ? () => Navigator.pop(context, _scopes.toList())
                                : null,
                        child: Text(widget.confirmLabel)),
                  ]),
                ],
              ))),
        );
      });
}

class FamilyConnectionsScreen extends ConsumerStatefulWidget {
  const FamilyConnectionsScreen({super.key});
  @override
  ConsumerState<FamilyConnectionsScreen> createState() =>
      _FamilyConnectionsScreenState();
}

class _FamilyConnectionsScreenState
    extends ConsumerState<FamilyConnectionsScreen> {
  final _email = TextEditingController();
  Future<bool> Function()? _retry;
  Object? _retrySession;
  String? _retryActor;
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
        () => ref.read(appControllerProvider).refreshFamilyConnections());
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  bool _current(AppController c, int generation, Object? session) =>
      identical(c.session, session) &&
      c.session != null &&
      c.familyConnectionGeneration == generation &&
      !c.familyConnectionBusy &&
      !c.loading;
  Future<void> _execute(Future<bool> Function() operation) async {
    final c = ref.read(appControllerProvider);
    _retry = operation;
    _retrySession = c.session;
    _retryActor = c.user?.id;
    final ok = await operation();
    if (mounted && identical(c.session, _retrySession)) {
      setState(() {
        if (ok) _retry = null;
      });
    }
  }

  Future<List<String>?> _review(
      {required String title,
      required String identity,
      required String impact,
      required String confirm,
      bool approval = false}) async {
    final c = ref.read(appControllerProvider);
    final generation = c.familyConnectionGeneration;
    final session = c.session;
    final result = await showDialog<List<String>>(
        context: context,
        builder: (_) => FamilyActionDialog(
            title: title,
            identity: identity,
            impact: impact,
            confirmLabel: confirm,
            approval: approval,
            isCurrent: () => _current(c, generation, session)));
    return mounted && _current(c, generation, session) ? result : null;
  }

  String _requestIdentity(FamilyConnectionRequest r, bool elder) =>
      '${elder ? (r.requesterName ?? '') : ''}\n${elder ? (r.requesterEmail ?? '') : r.elderEmail}\nRequest ID: ${r.id}\nElder ID: ${r.elderId}\nCaregiver ID: ${r.caregiverId}';
  String _linkIdentity(FamilyInvitation l, bool elder) =>
      '${elder ? (l.caregiverName ?? l.name ?? '') : (l.elderName ?? l.name ?? '')}\n${elder ? (l.caregiverEmail ?? l.email) : (l.elderEmail ?? l.email)}\nLink ID: ${l.id}\nElder ID: ${l.elderId ?? ''}\nCaregiver ID: ${l.caregiverId ?? ''}';
  String get _blockImpact => tr(context, '封鎖會移除這個家庭連接，並停止雙方透過該連接傳送及查看已分享內容。',
      'Block removes this family connection and stops sending and viewing shared content through it.');
  Future<void> _request() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    final result = await _review(
        title: tr(context, '申請家庭連接', 'Request family connection'),
        identity: email,
        impact: tr(context, '申請不會授予存取權限。必須由已註冊的長者明確批准。',
            'A request grants no access. The registered senior must explicitly approve it.'),
        confirm: tr(context, '確認申請', 'Confirm request'));
    if (result != null) {
      await _execute(
          () => ref.read(appControllerProvider).requestFamilyConnection(email));
    }
  }

  Future<void> _approve(FamilyConnectionRequest r) async {
    final scopes = await _review(
        title: tr(context, '批准申請', 'Approve request'),
        identity: _requestIdentity(r, true),
        approval: true,
        impact: tr(context, '只授予你在下方選取的權限。私人聊天仍保持私人。',
            'Grant only the permissions you select below. Private chats stay private.'),
        confirm: tr(context, '確認批准', 'Confirm approval'));
    if (scopes != null) {
      await _execute(() =>
          ref.read(appControllerProvider).approveFamilyConnection(r, scopes));
    }
  }

  Future<void> _reject(FamilyConnectionRequest r) async {
    final result = await _review(
        title: tr(context, '拒絕申請', 'Reject request'),
        identity: _requestIdentity(r, true),
        impact: tr(context, '拒絕只結束這次申請，對方仍可提出新的申請。',
            'Reject ends this request. They may send a new request.'),
        confirm: tr(context, '確認拒絕', 'Confirm rejection'));
    if (result != null) {
      await _execute(
          () => ref.read(appControllerProvider).rejectFamilyConnection(r));
    }
  }

  Future<void> _block(
      {FamilyConnectionRequest? request, FamilyInvitation? link}) async {
    final result = await _review(
        title: tr(context, '封鎖家庭連接', 'Block family connection'),
        identity: request != null
            ? _requestIdentity(request, true)
            : _linkIdentity(link!, true),
        impact: _blockImpact,
        confirm: tr(context, '確認封鎖', 'Confirm block'));
    if (result != null) {
      await _execute(() => ref
          .read(appControllerProvider)
          .blockFamilyConnection(request: request, link: link));
    }
  }

  Future<void> _unblock(FamilyBlock b) async {
    final result = await _review(
        title: tr(context, '解除封鎖', 'Unblock'),
        identity:
            '${b.caregiverName ?? ''}\n${b.caregiverEmail ?? ''}\nCaregiver ID: ${b.caregiverId}\nElder ID: ${b.elderId}',
        impact: tr(context, '解除封鎖不會恢復連接或之前的分享。重新連接需要新的邀請及批准。',
            'Unblocking does not restore the connection or previous shares. Reconnecting needs a new invitation and approval.'),
        confirm: tr(context, '確認解除封鎖', 'Confirm unblock'));
    if (result != null) {
      await _execute(
          () => ref.read(appControllerProvider).unblockFamilyConnection(b));
    }
  }

  Future<void> _withdraw(FamilyConnectionRequest r) async {
    final result = await _review(
        title: tr(context, '撤回申請', 'Withdraw request'),
        identity: _requestIdentity(r, false),
        impact: tr(context, '撤回後，這次申請不能再獲批准。',
            'This request can no longer be approved after withdrawal.'),
        confirm: tr(context, '確認撤回', 'Confirm withdrawal'));
    if (result != null) {
      await _execute(
          () => ref.read(appControllerProvider).withdrawFamilyConnection(r));
    }
  }

  Future<void> _remove(FamilyInvitation l) async {
    final result = await _review(
        title: tr(context, '移除家庭連接', 'Remove family connection'),
        identity: _linkIdentity(l, ref.read(appControllerProvider).isElder),
        impact: tr(context, '移除會撤回此連接及之前分享的存取權限。重新連接不會恢復舊分享。',
            'Removing withdraws access through this connection and its previous shares. Reconnecting does not restore old shares.'),
        confirm: tr(context, '確認移除', 'Confirm removal'));
    if (result != null) {
      await _execute(() => ref.read(appControllerProvider).revokeInvitation(l));
    }
  }

  String _statusLabel(String status) => switch (status) {
        'pending' => tr(context, '待批准（未授予權限）', 'Pending (no access granted)'),
        'approved' => tr(context, '已批准', 'Approved'),
        'accepted' => tr(context, '已連接', 'Connected'),
        'rejected' => tr(context, '已拒絕', 'Rejected'),
        'revoked' => tr(context, '已撤回', 'Withdrawn'),
        'expired' => tr(context, '已過期', 'Expired'),
        _ => tr(context, '狀態未知', 'Unknown state'),
      };
  Widget _heading(String zh, String en) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(tr(context, zh, en),
          style: Theme.of(context).textTheme.titleLarge));
  Widget _card(String identity, String status, List<Widget> actions,
          {bool unknown = false}) =>
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(identity),
                    const SizedBox(height: 8),
                    Text(status),
                    if (unknown)
                      Text(tr(context, '資料未完整或狀態未知。請重新整理，暫不可操作。',
                          'Incomplete data or unknown state. Refresh before taking action.')),
                    Wrap(spacing: 8, runSpacing: 8, children: actions)
                  ])));
  Widget _button(String zh, String en, VoidCallback? action, {Key? key}) =>
      OutlinedButton(
          key: key, onPressed: action, child: Text(tr(context, zh, en)));
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(appControllerProvider);
    final elder = c.isElder;
    final busy = c.familyConnectionBusy || c.loading;
    if (!identical(c.session, _retrySession) || c.user?.id != _retryActor) {
      _retry = null;
    }
    return RefreshIndicator(
        onRefresh: () => c.refreshFamilyConnections(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(tr(context, '家庭連接', 'Family connections'),
                style: Theme.of(context).textTheme.headlineSmall),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _button('重新整理', 'Refresh',
                  busy ? null : () => c.refreshFamilyConnections()),
              _button(
                  '邀請與邀請碼',
                  'Invitations and codes',
                  busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => Scaffold(
                                  appBar: AppBar(
                                      title: Text(tr(context, '邀請與邀請碼',
                                          'Invitations and codes'))),
                                  body: const LegacyFamilyInvitesScreen(
                                      showLinks: false))))),
              _button(
                  '家庭訊息',
                  'Family messages',
                  busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => const FamilyMessagesScreen()))),
            ]),
            if (busy) const LinearProgressIndicator(),
            if (c.familyConnectionError != null || c.errorMessage != null) ...[
              Text(c.familyConnectionError ?? c.errorMessage!,
                  key: const ValueKey('family-error')),
              _button(
                  '重試',
                  'Retry',
                  busy
                      ? null
                      : () {
                          if (_retry != null) {
                            _execute(_retry!);
                          } else {
                            c.refreshFamilyConnections();
                          }
                        }),
            ],
            if (!elder) ...[
              _heading('申請家庭連接', 'Request family connection'),
              TextField(
                  key: const ValueKey('family-elder-email'),
                  controller: _email,
                  enabled: !busy,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                      labelText:
                          tr(context, '已註冊長者的電郵', 'Registered senior email'))),
              _button('申請連接', 'Request connection', busy ? null : _request),
            ],
            _heading(elder ? '收到的申請' : '已發出的申請與邀請',
                elder ? 'Received requests' : 'Sent requests and invitations'),
            if (c.familyConnectionRequests.isEmpty)
              Text(tr(context, '目前沒有申請。', 'No requests.')),
            for (final r in c.familyConnectionRequests)
              _card(
                  _requestIdentity(r, elder),
                  _statusLabel(r.status.name),
                  [
                    if (elder) ...[
                      _button(
                          '批准',
                          'Approve',
                          !busy && r.actionable && r.elderId == c.user?.id
                              ? () => _approve(r)
                              : null),
                      _button(
                          '拒絕',
                          'Reject',
                          !busy && r.actionable && r.elderId == c.user?.id
                              ? () => _reject(r)
                              : null),
                      _button(
                          '封鎖',
                          'Block',
                          !busy &&
                                  r.id.isNotEmpty &&
                                  r.elderId == c.user?.id &&
                                  r.caregiverId.isNotEmpty &&
                                  (r.version ?? 0) > 0 &&
                                  r.status != FamilyRequestStatus.unknown
                              ? () => _block(request: r)
                              : null),
                    ] else
                      _button(
                          '撤回',
                          'Withdraw',
                          !busy && r.actionable && r.caregiverId == c.user?.id
                              ? () => _withdraw(r)
                              : null),
                  ],
                  unknown: r.status == FamilyRequestStatus.unknown ||
                      r.version == null ||
                      r.id.isEmpty),
            _heading('家庭連接', 'Links'),
            if (c.links.isEmpty)
              Text(tr(context, '目前沒有連接。', 'No connections.')),
            for (final l in c.links) ...[
              _card(
                  _linkIdentity(l, elder),
                  _statusLabel(l.status.name),
                  [
                    _button(
                        '移除',
                        'Remove',
                        !busy && _linkActionable(l, c)
                            ? () => _remove(l)
                            : null),
                    if (elder)
                      _button(
                          '封鎖',
                          'Block',
                          !busy && _blockLinkActionable(l, c)
                              ? () => _block(link: l)
                              : null),
                  ],
                  unknown: !_knownLinkIdentity(l, c)),
            ],
            if (elder) ...[
              _heading('封鎖記錄', 'Blocks'),
              if (c.familyBlocks.isEmpty)
                Text(tr(context, '目前沒有封鎖記錄。', 'No block records.')),
              for (final b in c.familyBlocks)
                _card(
                    '${b.caregiverName ?? ''}\n${b.caregiverEmail ?? ''}\nCaregiver ID: ${b.caregiverId}\nElder ID: ${b.elderId}',
                    b.active == true
                        ? tr(context, '已封鎖', 'Blocked')
                        : b.active == false
                            ? tr(context, '已解除封鎖；連接未恢復',
                                'Unblocked; connection not restored')
                            : tr(context, '未知', 'Unknown'),
                    [
                      _button(
                          '解除封鎖',
                          'Unblock',
                          !busy &&
                                  b.actionable &&
                                  b.active == true &&
                                  b.elderId == c.user?.id
                              ? () => _unblock(b)
                              : null)
                    ],
                    unknown: !b.actionable),
            ],
            _heading('已發送訊息記錄', 'Sent message history'),
            Text(tr(context, '只顯示你自己的發送記錄。新分享需要重新選擇收件人並預覽確認。',
                'Your own sent records only. New shares require choosing a recipient and reviewing a fresh preview.')),
            for (final m
                in c.sentFamilyMessages.where((m) => m.senderId == c.user?.id))
              _card(
                  m.content,
                  m.isAccessWithdrawn
                      ? tr(context, '存取權限已撤回', 'Access withdrawn')
                      : tr(context, '已發送', 'Sent'),
                  []),
          ],
        ));
  }

  bool _knownLinkIdentity(FamilyInvitation l, AppController c) =>
      l.id.isNotEmpty &&
      (l.authorizationEpoch ?? 0) > 0 &&
      l.elderId?.isNotEmpty == true &&
      l.caregiverId?.isNotEmpty == true &&
      (l.status == InvitationStatus.accepted ||
          l.status == InvitationStatus.revoked) &&
      (c.isElder ? l.elderId == c.user?.id : l.caregiverId == c.user?.id);
  bool _blockLinkActionable(FamilyInvitation l, AppController c) =>
      c.isElder && _knownLinkIdentity(l, c);
  bool _linkActionable(FamilyInvitation l, AppController c) =>
      l.id.isNotEmpty &&
      l.status == InvitationStatus.accepted &&
      (l.authorizationEpoch ?? 0) > 0 &&
      l.elderId?.isNotEmpty == true &&
      l.caregiverId?.isNotEmpty == true &&
      l.scopes.isNotEmpty &&
      l.scopes.every((s) => s == 'care_tasks' || s == 'family_messages') &&
      (c.isElder ? l.elderId == c.user?.id : l.caregiverId == c.user?.id);
}
