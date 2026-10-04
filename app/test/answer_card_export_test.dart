import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_models.dart';
import 'package:anxin_companion/src/answer_card_export.dart';

const _hash='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
CardPublicPayload _payload({String title='Guidance \u9999\u6e2f \u{1f44b}',List<String>? sections,List<String>? terms,List<String>? missing,List<String>? steps,List<AnswerCardSource>? sources,String state='ai_unverified'}) => CardPublicPayload(
 title:title,selectedSections:sections??['Only selected text \u4e2d\u6587 \u{1f44b}'],officialTerms:terms??['Official term'],
 missingInformation:missing??['Check eligibility'],nextSteps:steps??['Ask the service'],publicSources:sources??[
 const AnswerCardSource(sourceId:'internal-source-id',organisation:'SWD',title:'Public guidance',url:'https://www.swd.gov.hk/example',verificationScope:'Source scope',reviewedAt:'2026-10-03',contentHash:_hash)],
 verificationState:state,verificationScope:'Reference only');
ExportPreview _owned({CardPublicPayload? payload,String hash=_hash,int version=1,bool ack=true,String mode='assistant_answer'}) => ExportPreview(publicPayload:payload??_payload(),payloadHash:hash,personalReviewAck:ack,cardId:'card-1',version:version,mode:mode);
ExportPreview _guest({CardPublicPayload? payload}) => ExportPreview(publicPayload:payload??_payload(),payloadHash:'local:review-1',personalReviewAck:true,origin:ExportOrigin.guestLocal,mode:'assistant_answer');
class _Window implements AnswerCardPrintReservation {
 bool closed=false; bool fail=false; String? html; final List<String> events;
 _Window(this.events);
 @override bool get isClosed=>closed;
 @override void printHtml(String value) {if(fail)throw StateError('print unavailable');html=value;events.add('print');}
 @override void close(){closed=true;events.add('close');}
}
class _Platform implements AnswerCardExportPlatform {
 final events=<String>[]; late final _Window window=_Window(events); bool blocked=false,copyFails=false;String? text;
 @override AnswerCardPrintReservation? reservePrint(){events.add('reserve');return blocked?null:window;}
 @override Future<void> copyText(String value)async {if(copyFails)throw StateError('clipboard unavailable');text=value;events.add('copy');}
}
class _ParallelPlatform extends _Platform {
 final windows=<_Window>[];
 @override AnswerCardPrintReservation? reservePrint(){events.add('reserve');final next=_Window(events);windows.add(next);return next;}
}
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('canonical text contains every display field and original source date',(){
  expect(renderCardText(_payload()),
   'Guidance \u9999\u6e2f \u{1f44b}\n\nOnly selected text \u4e2d\u6587 \u{1f44b}\n\nOfficial terms / \u5b98\u65b9\u8853\u8a9e\n\nOfficial term\n\nMissing information / \u5c1a\u5f85\u78ba\u8a8d\n\nCheck eligibility\n\nNext steps / \u4e0b\u4e00\u6b65\n\nAsk the service\n\nVerification / \u6838\u5be6\u72c0\u614b\n\nai_unverified: AI answer is not independently verified.\n\nVerification scope / \u6838\u5be6\u7bc4\u570d\n\nReference only\n\nSources / \u4f86\u6e90\n\n1. SWD: Public guidance\n\nhttps://www.swd.gov.hk/example\n\nReviewed date / \u6838\u5c0d\u65e5\u671f: 2026-10-03\n\nRetrieved date / \u6aa2\u7d22\u65e5\u671f: Not provided / \u672a\u63d0\u4f9b\n\nEffective date / \u751f\u6548\u65e5\u671f: Not provided / \u672a\u63d0\u4f9b\n\nSource verification scope / \u4f86\u6e90\u6838\u5be6\u7bc4\u570d: Source scope');
 });
 test('all ten source snapshots and dates survive complete output',(){
  final sources=List.generate(10,(i)=>AnswerCardSource(sourceId:'internal-$i',organisation:'Organisation $i',title:'Source $i',url:'https://www.swd.gov.hk/source-$i',verificationScope:'Scope $i',reviewedAt:'2026-10-03',retrievedAt:'2026-10-02',effectiveDate:'2026-01-01'));
  final text=renderCardText(_payload(sources:sources));
  for(var i=0;i<10;i++){expect(text,contains('Organisation $i: Source $i'));expect(text,contains('https://www.swd.gov.hk/source-$i'));expect(text,contains('Scope $i'));}
  expect('2026-10-03'.allMatches(text).length,10);expect('2026-10-02'.allMatches(text).length,10);expect('2026-01-01'.allMatches(text).length,10);
 });
 test('missing terms steps sources are explicit without invented information',(){
  final text=renderCardText(_payload(terms:[],missing:[],steps:[],sources:[],state:'no_verified_source'));
  expect(text,contains('Not provided in original answer'));expect(text,contains('No verified source'));expect(text,contains('no_verified_source'));
  expect(text, isNot(contains('2026-10-04')));
 });
 test('each verification state retains explicit unverified or reviewed label',(){
  for(final state in ['reviewed_public_guidance','ai_unverified','user_edited_unverified','no_verified_source']){
   expect(renderCardText(_payload(state:state)),contains('$state:'));
  }
  expect(renderCardText(_payload()),contains('AI answer is not independently verified'));
 });
 test('HTML escapes all user text and carries no scripts remote assets or attributes',(){
  final payload=_payload(title:'<script>alert("x")</script> & \'title\'',sections:['<img src="https://evil.example/a" onerror="bad()">'],terms:['<b>term</b>'],missing:['& missing'],steps:['\'quoted\'']);
  final html=renderCardHtml(payload);
  expect(html,contains('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;title&#39;'));
  expect(html,contains('&lt;img src=&quot;https://evil.example/a&quot; onerror=&quot;bad()&quot;&gt;'));
  expect(html,contains('&lt;b&gt;term&lt;/b&gt;'));expect(html,contains('&amp; missing'));expect(html,contains('&#39;quoted&#39;'));
  expect(html,isNot(contains('<script')));expect(html,isNot(contains('<img')));expect(html,isNot(contains('<a ')));expect(html,isNot(contains('<link')));
  expect(html,contains('default-src'));expect(html,contains('charset="utf-8"'));
 });
 test('renderers never expose source ids hashes or owner provenance',(){
  for(final output in [renderCardText(_payload()),renderCardHtml(_payload())]){
   for(final secret in ['internal-source-id',_hash,'origin_message_id','conversation_id','memory_sources','access_token']){expect(output,isNot(contains(secret)));}
  }
 });
 test('invalid fields oversized complete JSON and text reject rather than truncate',(){
  final invalids=[_payload(title:'x'*241),_payload(sections:['x'*4001]),_payload(sections:List.filled(5,'x'*4000)),
   _payload(sections:List.filled(4,'\u4e2d'*4000),missing:List.filled(12,'\u4e2d'*4000)),
   _payload(sections:List.filled(4,'x'*4000),missing:List.filled(12,'x'*1200)),
   _payload(sources:[const AnswerCardSource(sourceId:'x',organisation:'x',title:'x',url:'javascript:alert(1)',verificationScope:'x')])];
  for(final payload in invalids){expect(()=>renderCardText(payload),throwsFormatException);expect(()=>renderCardHtml(payload),throwsFormatException);}
 });
 test('copy adapter receives exactly complete canonical text',()async{
  final platform=_Platform();final preview=_owned();
  final outcome=await AnswerCardExporter(platform:platform).exportCard(preview,ExportFormat.copyText,isCurrent:()=>true,revalidate:()async=>preview);
  expect(outcome,ExportOutcome.copied);expect(platform.text,renderCardText(preview.publicPayload,mode:preview.mode));expect(platform.events,['copy']);
 });
 test('print reserves synchronously before awaiting validation without body injection',()async{
  final platform=_Platform();final preview=_owned();final gate=Completer<ExportPreview>();
  final future=AnswerCardExporter(platform:platform).exportCard(preview,ExportFormat.printHtml,isCurrent:()=>true,revalidate:()=>gate.future);
  expect(platform.events,['reserve']);expect(platform.window.html,isNull);
  gate.complete(preview);expect(await future,ExportOutcome.dialogOpened);expect(platform.window.html,renderCardHtml(preview.publicPayload,mode:preview.mode));
 });
 test('blocked popup never calls validation or reports print success',()async{
  final platform=_Platform()..blocked=true;var validated=false;
  final outcome=await AnswerCardExporter(platform:platform).exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()async{validated=true;return _owned();});
  expect(outcome,ExportOutcome.blocked);expect(validated,isFalse);expect(platform.window.html,isNull);
 });
 test('changed session during validation closes blank window and emits nothing',()async{
  final platform=_Platform();final gate=Completer<ExportPreview>();var current=true;
  final future=AnswerCardExporter(platform:platform).exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>current,revalidate:()=>gate.future);
  current=false;gate.complete(_owned());expect(await future,ExportOutcome.cancelled);expect(platform.window.closed,isTrue);expect(platform.window.html,isNull);
 });
 test('changed hash version card or same hash altered body rejects before output',()async{
  final changed=[_owned(hash:'b'*64),_owned(version:2),ExportPreview(publicPayload:_payload(),payloadHash:_hash,personalReviewAck:true,cardId:'other-card',version:1,mode:'assistant_answer'),_owned(payload:_payload(title:'Changed body'))];
  for(final returned in changed){final platform=_Platform();
   expect(await AnswerCardExporter(platform:platform).exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()async=>returned),ExportOutcome.cancelled);
   expect(platform.window.closed,isTrue);expect(platform.window.html,isNull);
  }
 });
 test('missing personal review and invalid owner hash fail before reserving',()async{
  final platform=_Platform();final exporter=AnswerCardExporter(platform:platform);
  expect(await exporter.exportCard(_owned(ack:false),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()async=>_owned()),ExportOutcome.cancelled);
  expect(await exporter.exportCard(_owned(hash:'local:fake'),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()async=>_owned()),ExportOutcome.failed);
  expect(platform.events,isEmpty);
 });
 test('owner cannot export without server revalidation',()async{
  final platform=_Platform();expect(await AnswerCardExporter(platform:platform).exportCard(_owned(),ExportFormat.copyText,isCurrent:()=>true),ExportOutcome.failed);expect(platform.text,isNull);
 });
 test('guest local review token exports without server access',()async{
  final platform=_Platform();expect(await AnswerCardExporter(platform:platform).exportCard(_guest(),ExportFormat.copyText,isCurrent:()=>true),ExportOutcome.copied);
  expect(platform.text,renderCardText(_guest().publicPayload,mode:_guest().mode));
 });
 test('user closed reserved window cancels and validation errors close it',()async{
  final platform=_Platform();
  expect(await AnswerCardExporter(platform:platform).exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()async{platform.window.closed=true;return _owned();}),ExportOutcome.cancelled);
  final failed=_Platform();expect(await AnswerCardExporter(platform:failed).exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()async=>throw StateError('unavailable')),ExportOutcome.failed);expect(failed.window.closed,isTrue);expect(failed.window.html,isNull);
 });
 test('clipboard or print failure reports failed and closes print reservation',()async{
  final platform=_Platform()..copyFails=true;
  expect(await AnswerCardExporter(platform:platform).exportCard(_guest(),ExportFormat.copyText,isCurrent:()=>true),ExportOutcome.failed);
  final print=_Platform();print.window.fail=true;
  expect(await AnswerCardExporter(platform:print).exportCard(_guest(),ExportFormat.printHtml,isCurrent:()=>true),ExportOutcome.failed);expect(print.window.closed,isTrue);
 });
 test('edited AI export keeps original AI label while edited template stays unverified',()async{
  final edited=_payload(state:'user_edited_unverified');
  final ai=_Platform();final aiPreview=_owned(payload:edited);
  expect(await AnswerCardExporter(platform:ai).exportCard(aiPreview,ExportFormat.copyText,isCurrent:()=>true,revalidate:()async=>aiPreview),ExportOutcome.copied);
  expect(ai.text,contains('Origin / \u539f\u59cb\u4f86\u6e90\n\nAI answer / AI \u56de\u7b54'));
  expect(ai.text,contains('user_edited_unverified: User-edited content is not independently verified.'));
  final template=_Platform();final templatePreview=_owned(payload:edited,mode:'public_template');
  expect(await AnswerCardExporter(platform:template).exportCard(templatePreview,ExportFormat.copyText,isCurrent:()=>true,revalidate:()async=>templatePreview),ExportOutcome.copied);
  expect(template.text,contains('Public template / \u516c\u958b\u6a21\u677f'));expect(template.text,isNot(contains('AI answer /')));
  expect(template.text,contains('user_edited_unverified:'));expect(template.text,isNot(contains('Reviewed public guidance;')));
 });
 test('HTML origin label follows validated mode and unknown modes reject',(){
  final p=_payload(state:'user_edited_unverified');
  expect(renderCardHtml(p,mode:'assistant_answer'),contains('AI answer / AI \u56de\u7b54'));
  expect(renderCardHtml(p,mode:'public_template'),contains('Public template / \u516c\u958b\u6a21\u677f'));
  expect(()=>renderCardText(p,mode:'future_mode'),throwsFormatException);
  expect(()=>renderCardHtml(p,mode:'<script>'),throwsFormatException);
 });
 test('revalidated different origin mode cannot relabel reviewed output',()async{
  final p=_payload(state:'user_edited_unverified');final platform=_Platform();
  expect(await AnswerCardExporter(platform:platform).exportCard(_owned(payload:p),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()async=>_owned(payload:p,mode:'public_template')),ExportOutcome.cancelled);
  expect(platform.window.html,isNull);expect(platform.window.closed,isTrue);
 }); test('cancel immediately closes pending blank window and late validation cannot print',()async{
  final platform=_Platform();final exporter=AnswerCardExporter(platform:platform);final gate=Completer<ExportPreview>();
  final pending=exporter.exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()=>gate.future);
  expect(platform.window.closed,isFalse);expect(platform.window.html,isNull);
  exporter.cancelActiveExports();expect(platform.window.closed,isTrue);expect(platform.window.html,isNull);
  gate.complete(_owned());expect(await pending,ExportOutcome.cancelled);expect(platform.window.html,isNull);
  expect(platform.events.where((e)=>e=='close').length,1);
 });
 test('cancel prevents pending clipboard output and a fresh generation can export',()async{
  final platform=_Platform();final exporter=AnswerCardExporter(platform:platform);final gate=Completer<ExportPreview>();
  final pending=exporter.exportCard(_owned(),ExportFormat.copyText,isCurrent:()=>true,revalidate:()=>gate.future);
  exporter.cancelActiveExports();gate.complete(_owned());expect(await pending,ExportOutcome.cancelled);expect(platform.text,isNull);
  expect(await exporter.exportCard(_guest(),ExportFormat.copyText,isCurrent:()=>true),ExportOutcome.copied);
 });
 test('cancel closes all parallel pending reservations without mixing output',()async{
  final platform=_ParallelPlatform();final exporter=AnswerCardExporter(platform:platform);
  final first=Completer<ExportPreview>(),second=Completer<ExportPreview>();
  final a=exporter.exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()=>first.future);
  final b=exporter.exportCard(_owned(payload:_payload(title:'Other card')),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()=>second.future);
  expect(platform.windows.length,2);exporter.cancelActiveExports();expect(platform.windows.every((w)=>w.closed),isTrue);
  first.complete(_owned());second.complete(_owned(payload:_payload(title:'Other card')));
  expect(await a,ExportOutcome.cancelled);expect(await b,ExportOutcome.cancelled);expect(platform.windows.every((w)=>w.html==null),isTrue);
 });
 test('opened print preview remains cancellable and repeated cancel is harmless',()async{
  final platform=_Platform();final exporter=AnswerCardExporter(platform:platform);
  expect(await exporter.exportCard(_guest(),ExportFormat.printHtml,isCurrent:()=>true),ExportOutcome.dialogOpened);
  expect(platform.window.closed,isFalse);exporter.cancelActiveExports();expect(platform.window.closed,isTrue);
  exporter.cancelActiveExports();expect(platform.events.where((e)=>e=='close').length,1);
 });
 test('late revalidation error after explicit cancel stays cancelled',()async{
  final platform=_Platform();final exporter=AnswerCardExporter(platform:platform);final gate=Completer<ExportPreview>();
  final pending=exporter.exportCard(_owned(),ExportFormat.printHtml,isCurrent:()=>true,revalidate:()=>gate.future);
  exporter.cancelActiveExports();gate.completeError(StateError('late unavailable'));
  expect(await pending,ExportOutcome.cancelled);expect(platform.window.html,isNull);expect(platform.window.closed,isTrue);
 }); test('default native adapter uses Flutter Clipboard with complete text',()async{
  String? text;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,(call)async{
   if(call.method=='Clipboard.setData')text=(call.arguments as Map)['text'] as String;return null;
  });
  addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,null));
  expect(await AnswerCardExporter().exportCard(_guest(),ExportFormat.copyText,isCurrent:()=>true),ExportOutcome.copied);expect(text,renderCardText(_guest().publicPayload,mode:_guest().mode));
  expect(await AnswerCardExporter().exportCard(_guest(),ExportFormat.printHtml,isCurrent:()=>true),ExportOutcome.blocked);
 });
}
