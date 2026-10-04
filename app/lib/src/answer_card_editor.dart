import 'package:flutter/material.dart';
import 'answer_card_controller.dart';
import 'answer_card_models.dart';
import 'localization.dart';
import 'answer_card_export_screen.dart';

String answerCardStatusText(BuildContext context, String? status) {
  return switch (status) {
    'saved' => tr(context, '已儲存獨立私人副本。刪除原對話不會刪除此卡；可單獨刪除此卡。',
        'Saved an independent private copy. Deleting the conversation does not delete this card; you can delete it separately.'),
    'deleted' => tr(context, '已刪除此私人卡及其正文。',
        'The private card and its body have been deleted.'),
    'result_unconfirmed' => tr(context, '結果未確認。可保持目前內容重試；不會自動重新提交。',
        'The result is unconfirmed. You can retry with the same content; nothing is resubmitted automatically.'),
    'conflict' => tr(context, '內容或版本已變更。請取消並重新選擇、核對；不會自動重新提交。',
        'The content or version changed. Cancel and select it again for review; nothing is resubmitted automatically.'),
    'invalid_draft' => tr(context, '請填寫標題、選擇至少一段非空正文，並檢查內容長度。',
        'Enter a title, select at least one nonempty paragraph and check the content length.'),
    'guest_only' => tr(context, '訪客草稿只留在記憶體。登入後須重新選擇內容；不會自動轉移。',
        'Guest drafts stay in memory only. Sign in and select the content again; drafts are not transferred automatically.'),
    'reviewed' => '',
    _ => tr(context, '目前未能完成此操作。請稍後重試或取消。',
        'This action could not be completed. Try again later or cancel.'),
  };
}

String answerCardVerificationText(BuildContext context, String state) =>
    switch (state) {
      'reviewed_public_guidance' => tr(context, '公共指引已核對；個案須向機構確認',
          'Public guidance reviewed; confirm individual circumstances with the agency'),
      'ai_unverified' =>
        tr(context, 'AI 回答，未逐項核實', 'AI answer; not independently verified'),
      'user_edited_unverified' =>
        tr(context, '使用者編輯，未核實', 'User edited; unverified'),
      _ =>
        tr(context, '未核實，暫無可核實出處', 'Unverified; no verified source available'),
    };

/// Renders only the public DTO. Owner provenance and source hashes are excluded.
class AnswerCardPreview extends StatelessWidget {
  const AnswerCardPreview(
      {required this.payload, required this.mode, super.key});
  final CardPublicPayload payload;
  final String mode;

  @override
  Widget build(BuildContext context) {
    final absent = tr(context, '未提供', 'Not provided');
    Widget group(String heading, List<String> values) => Padding(
          padding: const EdgeInsets.only(top: 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(heading, style: Theme.of(context).textTheme.titleMedium),
            for (final text in values.isEmpty ? [absent] : values)
              Padding(
                  padding: const EdgeInsets.only(top: 8), child: Text(text)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(payload.title, style: Theme.of(context).textTheme.headlineSmall),
      if (mode == 'assistant_answer')
        Text(tr(context, '出處：AI 回答', 'Origin: AI answer')),
      if (mode == 'public_template')
        Text(tr(context, '範本內容為中文；英文全文未另行核對。',
            'Template content is Chinese; an English version has not been reviewed.')),
      Text(answerCardVerificationText(context, payload.verificationState)),
      group(tr(context, '核驗範圍', 'Verification scope'),
          [payload.verificationScope]),
      group(tr(context, '選定正文', 'Selected body'), payload.selectedSections),
      group(tr(context, '官方術語', 'Official terms'), payload.officialTerms),
      group(tr(context, '待確認事項', 'Information to confirm'),
          payload.missingInformation),
      group(tr(context, '下一步', 'Next steps'), payload.nextSteps),
      group(
          tr(context, '參考來源', 'Reference sources'),
          payload.publicSources.isEmpty
              ? []
              : [
                  tr(context, '來源不代表個案或整份 AI 回答已核實。',
                      'Sources do not verify individual circumstances or the entire AI answer.')
                ]),
      for (final source in payload.publicSources)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(source.organisation),
                Text(source.title),
                Text(source.url, softWrap: true),
                Text(
                    '${tr(context, '審閱日期', 'Reviewed')}: ${source.reviewedAt ?? absent}'),
                Text(
                    '${tr(context, '檢索日期', 'Retrieved')}: ${source.retrievedAt ?? absent}'),
                Text(
                    '${tr(context, '生效日期', 'Effective date')}: ${source.effectiveDate ?? absent}'),
                Text(
                    '${tr(context, '核驗範圍', 'Verification scope')}: ${source.verificationScope}'),
              ],
            )),
    ]);
  }
}

class AnswerCardEditorScreen extends StatefulWidget {
  const AnswerCardEditorScreen({required this.controller, super.key});
  final AnswerCardController controller;
  @override
  State<AnswerCardEditorScreen> createState() => _AnswerCardEditorScreenState();
}

class _AnswerCardEditorScreenState extends State<AnswerCardEditorScreen> {
  final _fields = <String, TextEditingController>{};
  final _originalSections = <String, String>{};
  late final int _generation;
  late int? _draftId;
  late final int _draftGeneration;
  bool _retired = false;
  bool _saving = false;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _generation = widget.controller.generation;
    _draftId = widget.controller.draft?.draftId;
    _draftGeneration = widget.controller.draftGeneration;
    _captureOriginal();
    widget.controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  bool get _current =>
      !_retired &&
      widget.controller.generation == _generation &&
      widget.controller.draftGeneration == _draftGeneration &&
      (_draftId == null || widget.controller.draft?.draftId == _draftId);

  void _clearText() {
    for (final field in _fields.values) {
      field.clear();
      field.dispose();
    }
    _fields.clear();
    _originalSections.clear();
  }

  void _captureOriginal() {
    final draft = widget.controller.draft;
    if (draft == null) return;
    for (final section in draft.sections) {
      _originalSections.putIfAbsent(section.id, () => section.text);
    }
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    FocusManager.instance.primaryFocus?.unfocus();
    _clearText();
    final route = _route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || route == null || !route.isActive) return;
      final navigator = route.navigator;
      if (navigator != null && navigator.canPop()) navigator.removeRoute(route);
    });
  }

  void _changed() {
    if (!mounted) return;
    if (_current && _draftId == null) {
      _draftId = widget.controller.draft?.draftId;
      _captureOriginal();
    }
    if (!_current) _retire();
    setState(() {});
  }

  void _cancel() {
    if (_current) {
      widget.controller.cancelDraft(
          expectedDraftId: _draftId, expectedDraftGeneration: _draftGeneration);
    }
    _retire();
    if (mounted) setState(() {});
  }

  TextEditingController _field(String key, String value) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: value));

  Widget _input(String key, String label, String initial,
          ValueChanged<String> changed) =>
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: TextField(
          key: ValueKey(key),
          controller: _field(key, initial),
          enabled: !widget.controller.busy,
          minLines: 1,
          maxLines: null,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
          onChanged: changed,
        ),
      );

  List<String> _lines(String value) =>
      value.split('\n').where((line) => line.trim().isNotEmpty).toList();

  Future<void> _save() async {
    if (!_current || _saving || widget.controller.busy) return;
    _saving = true;
    final saved = await widget.controller.saveReviewedDraft();
    _saving = false;
    if (!mounted ||
        widget.controller.generation != _generation ||
        _route?.isCurrent != true) {
      return;
    }
    if (saved) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(answerCardStatusText(context, 'saved'))));
      _retire();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final draft = _current ? controller.draft : null;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
            title: Text(tr(context, '整理答案卡', 'Edit answer card')),
            leading: BackButton(onPressed: _cancel)),
        body: draft == null
            ? Center(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (_current && controller.busy)
                        const CircularProgressIndicator(),
                      Text(_current && controller.busy
                          ? tr(context, '正在準備所選回答…',
                              'Preparing the selected answer…')
                          : tr(context, '草稿已清除。', 'Draft cleared.')),
                      if (_current && controller.error != null)
                        Text(answerCardStatusText(context, controller.status)),
                      OutlinedButton(
                          key: const ValueKey('card-cancel'),
                          onPressed: _cancel,
                          child: Text(tr(context, '取消', 'Cancel'))),
                    ])))
            : SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                    16, 16, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (controller.error != null ||
                          ['result_unconfirmed', 'conflict']
                              .contains(controller.status))
                        Text(answerCardStatusText(context, controller.status),
                            key: const ValueKey('card-error')),
                      if (controller.status == 'result_unconfirmed')
                        Text(tr(context, '清除草稿不會取消可能已送達的儲存。可返回私人卡列表重新載入以核對。',
                            'Clearing the draft does not cancel a save that may already have reached the server. Reload your private card list to check.')),
                      if (draft.isGuest)
                        Text(answerCardStatusText(context, 'guest_only')),
                      if (draft.reviewed && controller.preview != null) ...[
                        Text(tr(context, '完整成卡預覽', 'Complete card preview'),
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 16),
                        AnswerCardPreview(
                            payload: controller.preview!, mode: draft.mode),
                        const SizedBox(height: 24),
                        Text(tr(context, '請檢查選定內容中的個人資料。私人儲存只包含此預覽的內容。',
                            'Check the selected content for personal information. Private saving includes only this preview.')),
                        if (draft.isGuest) OutlinedButton(
                          key: const ValueKey('card-guest-export'),
                          onPressed: controller.busy ? null : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => AnswerCardExportScreen(
                              controller: controller, guestPayload: controller.preview!, guestMode: draft.mode))),
                          child: Text(tr(context, '匯出這張訪客卡', 'Export this guest card'))),
                        if (!draft.isGuest)
                          FilledButton(
                              key: const ValueKey('card-save'),
                              onPressed: controller.busy ||
                                      _saving ||
                                      ['conflict', 'unavailable']
                                          .contains(controller.status)
                                  ? null
                                  : _save,
                              child: Text(tr(context, '確認並私人儲存',
                                  'Confirm and save privately'))),
                        OutlinedButton(
                            key: const ValueKey('card-edit-back'),
                            onPressed: controller.busy ||
                                    [
                                      'result_unconfirmed',
                                      'invalid_response',
                                      'conflict',
                                      'unavailable'
                                    ].contains(controller.status)
                                ? null
                                : controller.editBack,
                            child:
                                Text(tr(context, '返回編輯', 'Back to editing'))),
                      ] else ...[
                        if (draft.mode == 'public_template')
                          Text(tr(context, '範本內容為中文；英文全文未另行核對。',
                              'Template content is Chinese; an English version has not been reviewed.')),
                        _input('card-title', tr(context, '標題', 'Title'),
                            draft.title, controller.setTitle),
                        const SizedBox(height: 20),
                        Text(
                            tr(context, '原內容 — 僅供你選擇，並非最終卡正文',
                                'Original content — for your selection; separate from the final card'),
                            style: Theme.of(context).textTheme.titleMedium),
                        if (draft.mode == 'assistant_answer')
                          Text(tr(context, '所有段落預設不選。只勾選要保留的內容，並移除個人資料。',
                              'All paragraphs start unchecked. Choose only the content to keep and remove personal information.')),
                        for (var index = 0;
                            index < draft.sections.length;
                            index++) ...[
                          CheckboxListTile(
                              key: ValueKey('card-section-$index'),
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: draft.selectedSectionIds
                                  .contains(draft.sections[index].id),
                              title: Text(
                                  '${tr(context, '保留段落', 'Include paragraph')} ${index + 1}'),
                              onChanged: controller.busy
                                  ? null
                                  : (selected) => controller.selectSection(
                                      draft.sections[index].id,
                                      selected == true)),
                          Text(_originalSections[draft.sections[index].id] ??
                              ''),
                          if (draft.selectedSectionIds
                              .contains(draft.sections[index].id))
                            _input(
                                'card-edit-section-$index',
                                tr(context, '選定正文（可刪去個人資料）',
                                    'Selected text (remove personal details)'),
                                draft.sections[index].text,
                                (text) => controller.editSection(
                                    draft.sections[index].id, text)),
                        ],
                        _input(
                            'card-terms',
                            tr(context, '官方術語／自行填寫（每行一項）',
                                'Official terms / your entries (one per line)'),
                            draft.officialTerms.join('\n'),
                            (text) =>
                                controller.setOfficialTerms(_lines(text))),
                        _input(
                            'card-missing',
                            tr(context, '待確認事項／自行填寫（每行一項）',
                                'Information to confirm / your entries (one per line)'),
                            draft.missingInformation.join('\n'),
                            (text) =>
                                controller.setMissingInformation(_lines(text))),
                        _input(
                            'card-steps',
                            tr(context, '下一步／自行填寫（每行一項）',
                                'Next steps / your entries (one per line)'),
                            draft.nextSteps.join('\n'),
                            (text) => controller.setNextSteps(_lines(text))),
                        if (draft.officialTerms.isEmpty ||
                            draft.nextSteps.isEmpty)
                          Text(tr(context, '原內容未提供的術語或下一步不會自動補充。',
                              'Terms or next steps absent from the original content are not added automatically.')),
                        const SizedBox(height: 16),
                        Text(tr(context, '選擇參考來源（日期及範圍保持原樣）',
                            'Select reference sources (original dates and scope retained)')),
                        if (draft.publicSources.isEmpty)
                          Text(tr(context, '原內容未提供可核實來源。',
                              'The original content provides no verified source.')),
                        for (final source in draft.publicSources)
                          CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(source.title),
                              subtitle:
                                  Text('${source.organisation}\n${source.url}'),
                              value: draft.selectedSourceIds
                                  .contains(source.sourceId),
                              onChanged: controller.busy
                                  ? null
                                  : (selected) => controller.selectSource(
                                      source.sourceId, selected == true)),
                        FilledButton(
                            key: const ValueKey('card-review'),
                            onPressed: controller.busy
                                ? null
                                : () {
                                    FocusManager.instance.primaryFocus
                                        ?.unfocus();
                                    controller.reviewDraft();
                                  },
                            child: Text(tr(
                                context, '查看完整成卡預覽', 'Review complete card'))),
                      ],
                      const SizedBox(height: 12),
                      OutlinedButton(
                          key: const ValueKey('card-cancel'),
                          onPressed: _cancel,
                          child: Text(tr(
                              context, '取消並清除草稿', 'Cancel and clear draft'))),
                    ]),
              ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    if (_current) {
      widget.controller.cancelDraft(
          expectedDraftId: _draftId, expectedDraftGeneration: _draftGeneration);
    }
    _clearText();
    super.dispose();
  }
}
