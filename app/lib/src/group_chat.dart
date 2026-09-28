import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'group_models.dart';
import 'localization.dart';

/// Human-only conversations. No AI chat or personal-memory API is called here.
class GroupLobbyScreen extends StatefulWidget {
  const GroupLobbyScreen({required this.api, required this.accountId, super.key});

  final HumanGroupApi api;
  final String accountId;

  @override
  State<GroupLobbyScreen> createState() => _GroupLobbyScreenState();
}

class _GroupLobbyScreenState extends State<GroupLobbyScreen> {
  List<HumanGroup> _groups = const [];
  List<HumanGroupInvitation> _invitations = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final groups = await widget.api.listHumanGroups();
      final invitations = await widget.api.listHumanGroupInvitations();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _invitations = invitations;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<String?> _prompt(String title, String label) async {
    final input = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: input, autofocus: true,
            decoration: InputDecoration(labelText: label), maxLength: 100),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: Text(tr(context, '取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, input.text.trim()),
              child: Text(tr(context, '確定', 'Continue'))),
        ],
      ),
    );
    input.dispose();
    return result;
  }

  Future<void> _create() async {
    final title = await _prompt(tr(context, '建立群組', 'Create group'),
        tr(context, '群組名稱', 'Group name'));
    if (title == null || title.isEmpty) return;
    try {
      final group = await widget.api.createHumanGroup(title);
      await _load();
      if (mounted) _open(group);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _decide(HumanGroupInvitation invitation, bool accept) async {
    try {
      if (accept) {
        await widget.api.acceptHumanGroupInvitation(invitation.id);
      } else {
        await widget.api.declineHumanGroupInvitation(invitation.id);
      }
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _open(HumanGroup group) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GroupDetailScreen(
          api: widget.api, group: group, accountId: widget.accountId),
    ));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(20), children: [
        Row(children: [
          Expanded(child: Text(tr(context, '人與人群聊', 'Human group chats'),
              style: Theme.of(context).textTheme.headlineSmall)),
          FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add),
              label: Text(tr(context, '建群', 'Create'))),
        ]),
        const SizedBox(height: 8),
        Text(tr(context,
            '只邀請已註冊的人加入。AI 不會閱讀或回覆群訊息；私密對話和記憶不會自動分享。',
            'Invite registered people only. AI does not read or reply to group messages. Private chats and memories are never shared automatically.')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_loading) const Padding(padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator())),
        if (_invitations.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(tr(context, '待處理邀請', 'Invitations'),
              style: Theme.of(context).textTheme.titleMedium),
          ..._invitations.map((invitation) => Card(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(invitation.groupTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(tr(context, '邀請者：${invitation.inviterName}',
                  'Invited by ${invitation.inviterName}')),
              Wrap(spacing: 8, children: [
                TextButton(onPressed: () => _decide(invitation, false),
                    child: Text(tr(context, '拒絕', 'Decline'))),
                FilledButton(onPressed: () => _decide(invitation, true),
                    child: Text(tr(context, '加入', 'Join'))),
              ]),
            ]),
          ))),
        ],
        const SizedBox(height: 22),
        Text(tr(context, '我的群組', 'My groups'),
            style: Theme.of(context).textTheme.titleMedium),
        if (!_loading && _groups.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 16),
              child: Text(tr(context, '還沒有群組。可以建立群組，然後邀請社區成員。',
                  'No groups yet. Create one and invite community members.'))),
        ..._groups.map((group) => Card(child: ListTile(
          leading: const Icon(Icons.groups_outlined),
          title: Text(group.title),
          subtitle: Text(tr(context, '${group.memberCount} 位成員',
              '${group.memberCount} members')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(group),
        ))),
      ]),
    );
  }
}

class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({required this.api, required this.group,
      required this.accountId, super.key});

  final HumanGroupApi api;
  final HumanGroup group;
  final String accountId;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  final _draft = TextEditingController();
  List<HumanGroupMessage> _messages = const [];
  List<HumanGroupMember> _members = const [];
  Timer? _poll;
  bool _sending = false;
  String? _error;
  String? _retryId;

  bool get _isOwner => widget.group.ownerId == widget.accountId;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _draft.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final messages = await widget.api.listHumanGroupMessages(widget.group.id);
      final members = await widget.api.listHumanGroupMembers(widget.group.id);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _members = members;
        if (!silent) _error = null;
      });
    } catch (error) {
      if (mounted && !silent) setState(() => _error = error.toString());
    }
  }

  Future<void> _send() async {
    final content = _draft.text.trim();
    if (_sending || content.isEmpty) return;
    _retryId ??= DateTime.now().microsecondsSinceEpoch.toString();
    setState(() => _sending = true);
    try {
      await widget.api.sendHumanGroupMessage(widget.group.id, content, _retryId!);
      _draft.clear();
      _retryId = null;
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<String?> _prompt(String title, String label) async {
    final input = TextEditingController();
    final result = await showDialog<String>(context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: TextField(controller: input, autofocus: true,
              decoration: InputDecoration(labelText: label), maxLength: 320),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context),
                child: Text(tr(context, '取消', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, input.text.trim()),
                child: Text(tr(context, '確定', 'Continue'))),
          ],
        ));
    input.dispose();
    return result;
  }

  Future<void> _invite() async {
    final email = await _prompt(tr(context, '邀請成員', 'Invite member'),
        tr(context, '已註冊成員的電郵', 'Registered member email'));
    if (email == null || email.isEmpty) return;
    try {
      await widget.api.inviteHumanGroupMember(widget.group.id, email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '邀請已建立，對方可在群聊頁接受。',
              'Invitation created. The person can accept it in Groups.'))));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _report() async {
    final reason = await _prompt(tr(context, '舉報群組', 'Report group'),
        tr(context, '請說明原因', 'Reason'));
    if (reason == null || reason.length < 3) return;
    try {
      await widget.api.reportHumanGroup(widget.group.id, reason);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '舉報已記錄；如感到不安全，可立即退出群組。',
              'Report recorded. You can leave the group immediately if you feel unsafe.'))));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _leaveOrClose() async {
    final confirmed = await showDialog<bool>(context: context,
        builder: (context) => AlertDialog(
          title: Text(_isOwner ? tr(context, '關閉群組？', 'Close group?')
              : tr(context, '退出群組？', 'Leave group?')),
          content: Text(tr(context, '完成後你將無法再讀取這個群組的訊息。',
              'You will no longer be able to read this group\'s messages.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: Text(tr(context, '取消', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, '確定', 'Continue'))),
          ],
        ));
    if (confirmed != true) return;
    try {
      if (_isOwner) {
        await widget.api.closeHumanGroup(widget.group.id);
      } else {
        await widget.api.leaveHumanGroup(widget.group.id);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _blockOwnerInvites() async {
    try {
      await widget.api.blockHumanGroupInvitations(widget.group.ownerId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '已封鎖這位成員日後向你發出群組邀請。',
              'Future group invitations from this person are blocked.'))));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _showMembers() {
    showModalBottomSheet<void>(context: context,
        builder: (context) => SafeArea(child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(tr(context, '群組成員', 'Group members'))),
            ..._members.map((member) => ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(member.displayName),
              subtitle: member.role == 'owner'
                  ? Text(tr(context, '建立者', 'Owner')) : null,
            )),
          ],
        )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.group.title), actions: [
        IconButton(onPressed: _showMembers, icon: const Icon(Icons.people_outline),
            tooltip: tr(context, '查看成員', 'View members')),
        PopupMenuButton<String>(onSelected: (value) {
          if (value == 'invite') _invite();
          if (value == 'report') _report();
          if (value == 'block') _blockOwnerInvites();
          if (value == 'exit') _leaveOrClose();
        }, itemBuilder: (context) => [
          if (_isOwner) PopupMenuItem(value: 'invite',
              child: Text(tr(context, '邀請成員', 'Invite member'))),
          PopupMenuItem(value: 'report',
              child: Text(tr(context, '舉報群組', 'Report group'))),
          if (!_isOwner) PopupMenuItem(value: 'block',
              child: Text(tr(context, '封鎖建立者的未來邀請',
                  'Block future invites from owner'))),
          PopupMenuItem(value: 'exit', child: Text(_isOwner
              ? tr(context, '關閉群組', 'Close group')
              : tr(context, '退出群組', 'Leave group'))),
        ]),
      ]),
      body: SafeArea(child: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Text(tr(context,
            '此群組只有人與人訊息；AI 不參與，私人對話和記憶不會自動分享。',
            'People only. AI does not participate; private chats and memories are not shared.'))),
        if (_error != null) Padding(padding: const EdgeInsets.all(8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        Expanded(child: RefreshIndicator(onRefresh: _load,
          child: ListView.builder(
            padding: const EdgeInsets.all(14),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final message = _messages[index];
              final mine = message.senderId == widget.accountId;
              return Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Card(color: mine ? Theme.of(context).colorScheme.primaryContainer : null,
                  child: Padding(padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(message.senderName,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(message.content),
                    ]),
                  ),
                ),
              );
            },
          ),
        )),
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(children: [
            Expanded(child: TextField(controller: _draft,
                minLines: 1, maxLines: 4,
                onChanged: (_) => _retryId = null,
                decoration: InputDecoration(hintText: tr(context,
                    '傳送給群組成員', 'Message the group')))),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send),
                tooltip: tr(context, '傳送', 'Send')),
          ]),
        ),
      ])),
    );
  }
}
