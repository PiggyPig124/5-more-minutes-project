import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'answer_card_controller.dart';
import 'answer_card_editor.dart';
import 'answer_card_export.dart';
import 'answer_card_export_api.dart';
import 'answer_card_models.dart';
import 'localization.dart';

/// A separate, review-bound egress step; it never renders owner provenance.
class AnswerCardExportScreen extends StatefulWidget {
  const AnswerCardExportScreen({required this.controller, this.api, this.card,
    this.guestPayload, this.guestMode, this.exporter, super.key});
  final AnswerCardController controller;
  final AnswerCardExportApi? api;
  final OwnedAnswerCard? card;
  final CardPublicPayload? guestPayload;
  final String? guestMode;
  final AnswerCardExporter? exporter;
  @override State<AnswerCardExportScreen> createState()=>_AnswerCardExportScreenState();
}
class _AnswerCardExportScreenState extends State<AnswerCardExportScreen> {
  late final int _generation, _draftGeneration;
  late final AnswerCardExporter _exporter;
  ExportPreview? _preview;
  bool _ack=false, _busy=false, _retired=false;
  ExportOutcome? _outcome;
  ModalRoute<dynamic>? _route;
  @override void initState(){
    super.initState();_generation=widget.controller.generation;
    _draftGeneration=widget.controller.draftGeneration;
    _exporter=widget.exporter??AnswerCardExporter();
    final card=widget.card;
    if(card!=null){
      _preview=ExportPreview(publicPayload:card.publicPayload,payloadHash:card.publicPayloadHash,
        personalReviewAck:false,mode:card.mode,cardId:card.id,version:card.version);
    }else if(widget.controller.isGuest&&widget.guestPayload!=null&&widget.guestMode!=null){
      _preview=ExportPreview(publicPayload:widget.guestPayload!,payloadHash:'local:$_generation:$_draftGeneration',
        personalReviewAck:false,mode:widget.guestMode!,origin:ExportOrigin.guestLocal);
    }
    widget.controller.addListener(_changed);
  }
  @override void didChangeDependencies(){super.didChangeDependencies();_route??=ModalRoute.of(context);}
  bool get _current{
    final p=_preview;final c=widget.controller;
    if(_retired||p==null||c.generation!=_generation||c.busy)return false;
    if(p.origin==ExportOrigin.guestLocal){
      return c.isGuest&&c.draftGeneration==_draftGeneration&&c.draft?.reviewed==true&&
        c.draft?.mode==p.mode&&c.preview!=null&&jsonEncode(c.preview!.toJson())==jsonEncode(p.publicPayload.toJson());
    }
    final card=c.cards.where((x)=>x.id==p.cardId).firstOrNull;
    return !c.isGuest&&card!=null&&card.version==p.version&&card.mode==p.mode&&
      card.publicPayloadHash==p.payloadHash&&jsonEncode(card.publicPayload.toJson())==jsonEncode(p.publicPayload.toJson());
  }
  void _changed(){
    if(!mounted)return;
    if(!_current){
      _retired=true;_ack=false;_preview=null;_exporter.cancelActiveExports();
      final route=_route;
      WidgetsBinding.instance.addPostFrameCallback((_){if(mounted&&route!=null&&route.isActive&&route.navigator!.canPop())route.navigator!.removeRoute(route);});
    }
    setState((){});
  }
  Future<void> _export(ExportFormat format)async{
    if(!_current||!_ack||_busy)return;
    final p=_preview!;
    final reviewed=ExportPreview(publicPayload:p.publicPayload,payloadHash:p.payloadHash,
      personalReviewAck:true,mode:p.mode,cardId:p.cardId,version:p.version,origin:p.origin);
    setState((){_busy=true;_outcome=null;});
    final result=await _exporter.exportCard(reviewed,format,isCurrent:()=>mounted&&_current,
      revalidate:p.origin==ExportOrigin.guestLocal?null:()async{
        final api=widget.api;if(api==null)throw StateError('Export capability unavailable');
        final r=await api.getAnswerCardExportPreview(p.cardId!,expectedVersion:p.version!,
          previewedPayloadHash:p.payloadHash,personalReviewAck:true);
        return ExportPreview(publicPayload:r.publicPayload,payloadHash:r.publicPayloadHash,
          personalReviewAck:true,mode:p.mode,cardId:p.cardId,version:r.cardVersion);
      });
    if(!mounted||!_current)return;
    setState((){_busy=false;_outcome=result;});
  }
  @override Widget build(BuildContext context){
    final p=_preview;final enabled=_current&&_ack&&!_busy;
    return Scaffold(appBar:AppBar(title:Text(tr(context,'匯出答案卡','Export answer card'))),
      body:p==null?const SizedBox.shrink():SingleChildScrollView(padding:const EdgeInsets.all(16),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          AnswerCardPreview(payload:p.publicPayload,mode:p.mode),
          const SizedBox(height:24),
          CheckboxListTile(key:const ValueKey('card-export-ack'),contentPadding:EdgeInsets.zero,
            controlAffinity:ListTileControlAffinity.leading,value:_ack,
            onChanged:_busy?null:(v)=>setState((){_ack=v==true;_outcome=null;}),
            title:Text(tr(context,'我已檢查完整卡片，並確認沒有不想匯出的個人資料。','I reviewed the complete card and removed personal details I do not want to export.'))),
          if(_busy)const LinearProgressIndicator(),
          if(_outcome!=null)Text(_message(context,_outcome!)),
          FilledButton(key:const ValueKey('card-export-copy'),onPressed:enabled?()=>_export(ExportFormat.copyText):null,
            child:Text(tr(context,'複製完整文字','Copy complete text'))),
          if(kIsWeb)OutlinedButton(key:const ValueKey('card-export-print'),onPressed:enabled?()=>_export(ExportFormat.printHtml):null,
            child:Text(tr(context,'列印／另存 PDF','Print / save as PDF'))),
          Text(tr(context,'複製或列印只包含本頁卡片。列印對話框開啟不代表已儲存 PDF。','Copying or printing includes only this card. Opening the print dialog does not mean a PDF was saved.')),
        ])));
  }
  String _message(BuildContext context,ExportOutcome o)=>switch(o){
    ExportOutcome.copied=>tr(context,'已複製完整卡片文字。','Complete card text copied.'),
    ExportOutcome.dialogOpened=>tr(context,'已開啟列印對話框。可選擇另存 PDF；是否完成請自行確認。','Print dialog opened. You can choose Save as PDF; check the result yourself.'),
    ExportOutcome.blocked=>tr(context,'列印視窗被阻擋。請允許彈出視窗，再明確重試。','Print window blocked. Allow pop-ups, then retry explicitly.'),
    ExportOutcome.cancelled=>tr(context,'預覽已失效或視窗已關閉。請重新開啟並檢查卡片。','The preview changed or the window closed. Open and review the card again.'),
    ExportOutcome.failed=>tr(context,'未完成匯出。請重新檢查卡片並明確重試。','Export did not complete. Review the card and retry explicitly.'),
  };
  @override void dispose(){widget.controller.removeListener(_changed);_exporter.cancelActiveExports();_preview=null;super.dispose();}
}
