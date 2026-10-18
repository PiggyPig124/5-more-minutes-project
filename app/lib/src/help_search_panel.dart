import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_controller.dart';
import 'help_search_state.dart';
import 'localization.dart';
import 'models.dart';

/// A view lease prevents a closing Help page from cancelling its replacement.
class HelpSearchPanel extends StatefulWidget {
  const HelpSearchPanel({super.key, required this.controller});
  final AppController controller;

  @override
  State<HelpSearchPanel> createState() => _HelpSearchPanelState();
}

class _HelpSearchPanelState extends State<HelpSearchPanel>
    with AutomaticKeepAliveClientMixin {
  final _query = TextEditingController();
  late AppController _owner;
  late Object _identity;
  late Object _scope;

  @override
  bool get wantKeepAlive => true;

  void _bind() {
    _owner = widget.controller;
    _identity = _owner.helpSearchIdentity;
    _scope = _owner.openHelpSearchScope();
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant HelpSearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(_owner, widget.controller) ||
        _identity != widget.controller.helpSearchIdentity) {
      _owner.closeHelpSearchScope(_scope);
      _query.clear();
      _bind();
    }
  }

  @override
  void dispose() {
    _owner.closeHelpSearchScope(_scope);
    _query.dispose();
    super.dispose();
  }

  void _submit() => _owner.searchHelp(_query.text, scope: _scope);

  Widget _resource(ResourceItem item) => Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(tr(context,
                '來源機構：${item.organisation?.trim().isNotEmpty == true ? item.organisation : '未提供'}',
                'Source organisation: ${item.organisation?.trim().isNotEmpty == true ? item.organisation : 'Not provided'}')),
            if (item.excerpt.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(item.excerpt)
            ],
            if (item.verifiedAt != null) ...[
              const SizedBox(height: 8),
              Text(
                  tr(
                      context,
                      '核實日期：${item.verifiedAt!.year}/${item.verifiedAt!.month}/${item.verifiedAt!.day}',
                      'Verified: ${item.verifiedAt!.year}/${item.verifiedAt!.month}/${item.verifiedAt!.day}'),
                  style: Theme.of(context).textTheme.bodySmall)
            ],
            if (item.nextSteps.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(tr(context, '下一步', 'Next steps'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              ...item.nextSteps.map((step) => Text('• $step'))
            ],
            if (item.url != null)
              TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(item.url!),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(tr(context, '開啟官方來源', 'Open official source'))),
          ])));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = _owner.helpSearch;
    final samePending =
        state.isLoading && state.submittedQuery == _query.text.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
          margin: EdgeInsets.zero,
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(tr(context, '搜尋生活資訊', 'Search practical information'),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 10),
                    TextField(
                        controller: _query,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                            labelText: tr(context, '你想了解甚麼？',
                                'What would you like to know?'),
                            suffixIcon: IconButton(
                                tooltip: tr(context, '搜尋', 'Search'),
                                onPressed:
                                    _query.text.trim().isEmpty || samePending
                                        ? null
                                        : _submit,
                                icon: const Icon(Icons.search_rounded)))),
                  ]))),
      if (state.phase != HelpSearchPhase.idle) ...[
        const SizedBox(height: 14),
        Text(tr(context, '搜尋內容：${state.submittedQuery}',
            'Search: ${state.submittedQuery}')),
        const SizedBox(height: 8),
      ],
      if (state.isLoading)
        Semantics(
            liveRegion: true,
            child: Row(children: [
              const SizedBox(
                  width: 24, height: 24, child: CircularProgressIndicator()),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(tr(context, '正在搜尋生活資訊…',
                      'Searching practical information…'))),
            ])),
      if (state.phase == HelpSearchPhase.success && state.items.isEmpty)
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(tr(context, '暫時找不到合適的已核實資料。請稍後再試，或直接查詢相關官方服務。',
                    'No verified information matched. Try later or contact the relevant official service.')))),
      if (state.phase == HelpSearchPhase.error)
        Semantics(
            liveRegion: true,
            child: Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(tr(context, '資訊搜尋暫時未能使用，請重試。',
                              'Information search is unavailable. Please try again.')),
                          const SizedBox(height: 8),
                          TextButton.icon(
                              onPressed: () =>
                                  _owner.retryHelpSearch(scope: _scope),
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(tr(context, '重試搜尋', 'Retry search'))),
                        ])))),
      ...state.items.map(_resource),
    ]);
  }
}
