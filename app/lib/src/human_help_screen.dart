import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'localization.dart';
import 'models.dart';

typedef HumanHelpResourceLoader = Future<ResourceSearchResult> Function(
    {required String query, int? limit});
typedef HumanHelpUrlLauncher = Future<bool> Function(Uri uri);

/// Public referrals only. This screen has no private reads or message API.
class HumanHelpScreen extends StatefulWidget {
  const HumanHelpScreen({
    super.key,
    this.api,
    this.resourceLoader,
    this.urlLauncher,
    this.onOpenFamily,
  });

  final GuestResourceApi? api;
  final HumanHelpResourceLoader? resourceLoader;
  final HumanHelpUrlLauncher? urlLauncher;
  final VoidCallback? onOpenFamily;

  @override
  State<HumanHelpScreen> createState() => _HumanHelpScreenState();
}

class _HumanHelpScreenState extends State<HumanHelpScreen> {
  // These queries deliberately never include a conversation or personal details.
  static const _queries = [
    'carer support',
    'home care services',
    'elderly centre',
  ];
  // A source change requires a fresh review. A known host alone is insufficient.
  static const _reviewedSources = {
    'swd-carer-support-hotline':
        'https://www.swd.gov.hk/en/pubsvc/elderly/cat_careersupp/carersuppo/index.html',
    'swd-home-care-services-frail-elderly':
        'https://www.swd.gov.hk/en/pubsvc/elderly/cat_commcare/homebase_ccs/',
    'swd-elderly-centres-directory-2026-05':
        'https://www.swd.gov.hk/storage/asset/section/177/List%20of%20Elderly%20Centres/List_of_DECCs_NECs_SC.pdf',
  };

  List<ResourceItem> _items = const [];
  bool _loading = true;
  String? _openingId;
  bool _launchFailed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HumanHelpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.resourceLoader != widget.resourceLoader) {
      _load();
    }
  }

  bool _isReviewed(ResourceItem item) {
    final approved = _reviewedSources[item.id];
    final uri = Uri.tryParse(item.url ?? '');
    return approved != null &&
        item.url == approved &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'www.swd.gov.hk' &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        item.verifiedAt != null &&
        item.title.trim().isNotEmpty &&
        item.excerpt.trim().isNotEmpty &&
        item.nextSteps.any((step) => step.trim().isNotEmpty);
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _items = const [];
      _launchFailed = false;
      _openingId = null;
    });
    try {
      final loader = widget.resourceLoader ?? widget.api?.searchGuestResources;
      if (loader == null) throw StateError('Public referral API unavailable');
      final results = await Future.wait(
          _queries.map((query) => loader(query: query, limit: 10)));
      if (!mounted || generation != _generation) return;
      final byId = <String, ResourceItem>{};
      for (final result in results) {
        for (final item in result.items) {
          if (_isReviewed(item)) byId.putIfAbsent(item.id, () => item);
        }
      }
      setState(() {
        _items = byId.values.toList(growable: false);
        _loading = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = const [];
        _loading = false;
      });
    }
  }

  Future<void> _open(ResourceItem item) async {
    if (_openingId != null || !_isReviewed(item)) return;
    final generation = _generation;
    setState(() {
      _openingId = item.id;
      _launchFailed = false;
    });
    var opened = false;
    try {
      final uri = Uri.parse(item.url!);
      opened = await (widget.urlLauncher?.call(uri) ??
          launchUrl(uri, mode: LaunchMode.externalApplication));
    } on Object {
      // Keep the reviewed website available for another explicit attempt.
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _openingId = null;
      _launchFailed = !opened;
    });
  }

  String _date(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Widget _card(List<Widget> children) => Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children)));

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(tr(context, '找真人幫忙', 'Ask a person'))),
      body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
          children: [
            Text(
                tr(context, '個人模式是自選的。不登入也可查看公共支援。',
                    'Personal mode is optional. Public support is available without signing in.'),
                style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 12),
            Text(tr(
                context,
                '這裡提供公開的真人支援途徑，不會自動傳送訊息、登記或轉交你的私人資料。你可自行決定是否及如何聯絡。',
                'Choose a public route to human support. Nothing is sent or registered automatically, and your private information is not transferred. You decide whether and how to contact a service.')),
            const SizedBox(height: 16),
            _card([
              Text(tr(context, '家人支援', 'Family support'),
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              if (widget.onOpenFamily == null)
                Text(tr(context, '登入後可在家人功能中選擇可聯絡的家人。不登入也可在此查看公共支援。',
                    'Sign in and use Family to choose an available family contact. Public support is available here without signing in.'))
              else ...[
                Text(tr(context, '開啟現有家人訊息頁。請先核對收件人和訊息，然後自行選擇是否傳送。此頁不會發送訊息。',
                    'Open the existing Family messages page. Review the recipient and message before choosing to send. This page does not send a message.')),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed: widget.onOpenFamily,
                    icon: const Icon(Icons.people_outline),
                    label: Text(tr(context, '開啟家人訊息', 'Open Family messages'))),
              ],
            ]),
            _card([
              Text(tr(context, '緊急情況', 'Urgent danger'),
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(tr(
                  context,
                  '在香港如面臨即時危險，請致電999；香港以外地區請聯絡當地緊急服務，或請身邊的人協助。此應用程式不會召喚緊急服務，也不能取代緊急服務或個人緊急警報服務。以下公共支援也不等於緊急服務。',
                  'In Hong Kong, call 999 for immediate danger; outside Hong Kong use local emergency services or ask someone nearby to help. This app does not call emergency services and does not replace emergency services or a personal emergency alarm service. The public support below is not emergency response.')),
              const SizedBox(height: 8),
              Text(tr(context, '來源：香港警務處', 'Source: Hong Kong Police Force')),
              const Text(
                  'https://www.police.gov.hk/ppp_en/contact_us.html?st=headingOne'),
              Text(tr(context, '查閱日期：2026-10-15', 'Checked: 2026-10-15')),
            ]),
            Text(tr(context, '公共社會服務支援', 'Public social-service support'),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(tr(context, '服務資料按原核實日期顯示；聯絡前請向服務機構確認現時安排及資格。',
                'Details show their original verification date. Confirm current arrangements and eligibility with the service before contacting it.')),
            const SizedBox(height: 12),
            if (_loading)
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(tr(context, '正在查閱已核實的公共支援…',
                      'Looking up verified public support…')))
            else if (_items.isEmpty)
              _card([
                Text(tr(context, '目前沒有可用的已核實公共支援途徑。',
                    'No verified public channel is available right now.')),
                const SizedBox(height: 12),
                OutlinedButton(
                    onPressed: _load, child: Text(tr(context, '重試', 'Retry'))),
              ])
            else
              ..._items.map((item) => _resourceCard(context, item)),
            if (_launchFailed)
              Text(tr(context, '無法開啟網站，請再試一次。',
                  'Could not open the website. Please try again.')),
          ]));

  Widget _resourceCard(BuildContext context, ResourceItem item) => _card([
        Text(item.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        // Show approved supplied prose as text; never extract or dial a number.
        Text(item.excerpt),
        const SizedBox(height: 8),
        Text(tr(context, '來源：www.swd.gov.hk', 'Source: www.swd.gov.hk')),
        Text(tr(context, '核實日期：${_date(item.verifiedAt!)}',
            'Verified: ${_date(item.verifiedAt!)}')),
        if (item.conditions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(tr(context, '服務安排及條件', 'Service details and conditions'),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          ...item.conditions
              .where((text) => text.trim().isNotEmpty)
              .map(Text.new),
        ],
        const SizedBox(height: 8),
        Text(tr(context, '下一步', 'Next steps'),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        ...item.nextSteps.where((text) => text.trim().isNotEmpty).map(Text.new),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: _openingId == null ? () => _open(item) : null,
            icon: const Icon(Icons.open_in_new),
            label: Text(tr(context, '開啟官方網站', 'Open official website'))),
      ]);
}
