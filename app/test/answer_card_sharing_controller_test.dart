import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/api_client.dart' show ApiException;
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/answer_card_sharing_api.dart';
import 'package:anxin_companion/src/answer_card_sharing_controller.dart';

const digest='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const date='2026-10-04T00:00:00Z';
CardPublicPayload body({String title='Selected guidance'})=>CardPublicPayload(title:title,selectedSections:['Selected text'],officialTerms:[],missingInformation:[],nextSteps:[],publicSources:[],verificationState:'no_verified_source',verificationScope:'AI answer is not independently verified. Sources are references only.');
OwnedAnswerCard card({String id='card',int version=3})=>OwnedAnswerCard(id:id,mode:'assistant_answer',version:version,publicPayload:body(),publicPayloadHash:digest,provenance:{'origin_message_id':'message','origin_hash':digest,'template_id':null,'template_version':null,'template_hash':null,'selected_original_excerpts':[{'id':'section','hash':digest,'edited':false}]},createdAt:date,updatedAt:date);
FamilyInvitation link({String id='link',String recipient='caregiver',String email='caregiver@example.test',int epoch=7,List<String> scopes=const ['family_messages']})=>FamilyInvitation(id:id,email:email,status:InvitationStatus.accepted,elderId:'elder',caregiverId:recipient,elderEmail:'elder@example.test',caregiverEmail:email,caregiverName:'Same name',authorizationEpoch:epoch,scopes:scopes);
AnswerCardShare share({String id='share',String recipient='caregiver',int version=3,int epoch=7,String sender='elder',CardPublicPayload? payload})=>AnswerCardShare(id:id,mode:'assistant_answer',cardVersion:version,senderId:sender,recipientId:recipient,linkId:'link',linkEpoch:epoch,publicPayload:payload??body(),publicPayloadHash:digest,createdAt:date);
AnswerCardSentShare sent({String id='share',String sender='elder',String cardId='card'})=>AnswerCardSentShare(id:id,mode:'assistant_answer',cardId:cardId,cardVersion:3,senderId:sender,recipientId:'caregiver',linkId:'link',linkEpoch:7,publicPayload:body(),publicPayloadHash:digest,createdAt:date,accessRevokedAt:null,accessRevocationReason:null);
class SharingApi implements AnswerCardSharingApi {
  int writes=0,reads=0;
  final requests=<Map<String,Object?>>[];
  final revokeIds=<String>[];
  Object? failure;
  AnswerCardShare? result;
  Completer<AnswerCardShare>? delayedShare;
  Completer<List<AnswerCardShare>>? delayedInbox;
  Completer<List<AnswerCardSentShare>>? delayedSent;
  List<AnswerCardShare> inbox=[];
  List<AnswerCardSentShare> history=[];
  AnswerCardShareRevokeReceipt? revokeResult;
  @override Future<AnswerCardShare> shareAnswerCard(String cardId,Map<String,Object?> request) async {writes++;requests.add(request);if(failure!=null)throw failure!;if(delayedShare!=null)return delayedShare!.future;return result??share();}
  @override Future<List<AnswerCardShare>> listAnswerCardInbox() async {reads++;if(delayedInbox!=null)return delayedInbox!.future;return inbox;}
  @override Future<List<AnswerCardSentShare>> listSentAnswerCardShares() async {reads++;if(delayedSent!=null)return delayedSent!.future;return history;}
  @override Future<AnswerCardShareRevokeReceipt> revokeAnswerCardShare(String shareId) async {writes++;revokeIds.add(shareId);if(failure!=null)throw failure!;return revokeResult??AnswerCardShareRevokeReceipt(id:shareId,revoked:true);}
}
void main(){
  late SharingApi api;
  late AnswerCardSharingController c;
  late FamilyInvitation currentLink;
  setUp((){api=SharingApi();c=AnswerCardSharingController(api:api);c.bindSession(ownerId:'elder',sessionIdentity:'session',role:UserRole.elder);currentLink=link();c.bindFamilyAuthorization(generation:1,links:[currentLink],accessUncertain:false);});
  tearDown(()=>c.dispose());
  void prepare(){expect(c.prepareShare(card(),currentLink),isTrue);}
  AnswerCardSentShare terminal({String id='share',String cardId='card'})=>AnswerCardSentShare.fromJson({...sent(id:id,cardId:cardId).toJson(),'access_revoked_at':date,'access_revocation_reason':'sender_revoked'});
  Future<void> loseRevokeReceipt()async{api.failure=const ApiException('lost receipt',statusCode:500);expect(await c.revokeShare(sent()),isFalse);expect(c.status,'result_unconfirmed');api.failure=null;}
  test('terminal revoke history invalidates an older parallel active snapshot',()async{
    await loseRevokeReceipt();
    final older=Completer<List<AnswerCardSentShare>>();api.delayedSent=older;final oldRead=c.loadSent();
    final newer=Completer<List<AnswerCardSentShare>>();api.delayedSent=newer;final newRead=c.loadSent();
    newer.complete([terminal()]);expect(await newRead,isTrue);
    expect(c.pendingRevoke,isNull);expect(c.status,'revoked');expect(c.sent.single.accessRevokedAt,date);
    final olderReadWasRetired=!c.busy;
    final latest=Completer<List<AnswerCardSentShare>>();api.delayedSent=latest;final latestRead=c.loadSent();
    expect(c.busy,isTrue);
    older.complete([sent()]);expect(await oldRead,isFalse);
    expect(olderReadWasRetired,isTrue,reason:'confirmed terminal result retires older reads');
    expect(c.busy,isTrue,reason:'old finally must not clear a new read token');
    expect(c.sent,isEmpty,reason:'old active body must not republish during the newer read');
    latest.complete([terminal()]);expect(await latestRead,isTrue);
    expect(c.sent.single.accessRevokedAt,date);expect(c.pendingRevoke,isNull);expect(c.busy,isFalse);
    expect(c.prepareShare(card(id:'new-card'),currentLink),isTrue);expect(api.writes,1);
  });
  test('committed revoke with lost receipt resolves only from exact terminal sender history',()async{
    await loseRevokeReceipt();api.history=[terminal()];expect(await c.loadSent(),isTrue);
    expect(c.status,'revoked');expect(c.error,isNull);expect(c.sent.single.accessRevokedAt,date);
    expect(c.prepareShare(card(id:'new-card'),currentLink),isTrue);expect(api.writes,1);
  });
  test('uncommitted revoke reload keeps exact original share available for explicit retry',()async{
    await loseRevokeReceipt();api.history=[sent()];expect(await c.loadSent(),isTrue);
    expect(c.status,'result_unconfirmed');expect(c.prepareShare(card(id:'new-card'),currentLink),isFalse);
    expect(await c.revokeShare(c.sent.single),isTrue);expect(api.revokeIds,['share','share']);
    expect(c.prepareShare(card(id:'new-card'),currentLink),isTrue);
  });
  test('missing sender history preserves unknown revoke retry row and original share id',()async{
    await loseRevokeReceipt();api.history=[];expect(await c.loadSent(),isTrue);
    expect(c.status,'result_unconfirmed');expect(c.sent.single.id,'share');
    expect(c.prepareShare(card(id:'new-card'),currentLink),isFalse);
    expect(await c.revokeShare(c.sent.single),isTrue);expect(api.revokeIds,['share','share']);
  });
  test('other terminal history does not resolve pending revoke or remove retry row',()async{
    await loseRevokeReceipt();api.history=[terminal(id:'other-share',cardId:'other-card')];expect(await c.loadSent(),isTrue);
    expect(c.status,'result_unconfirmed');expect(c.sent.map((row)=>row.id),containsAll(['share','other-share']));
    expect(c.prepareShare(card(id:'new-card'),currentLink),isFalse);
    expect(await c.revokeShare(c.sent.firstWhere((row)=>row.id=='share')),isTrue);expect(api.revokeIds,['share','share']);
  });
  test('same share id with another card cannot resolve or replace captured revoke snapshot',()async{
    await loseRevokeReceipt();api.history=[terminal(cardId:'other-card')];expect(await c.loadSent(),isTrue);
    expect(c.status,'result_unconfirmed');expect(c.sent.single.cardId,'card');expect(c.sent.single.accessRevokedAt,isNull);
    expect(c.prepareShare(card(id:'new-card'),currentLink),isFalse);
    expect(await c.revokeShare(c.sent.single),isTrue);expect(api.revokeIds,['share','share']);
  });
  test('old session terminal history cannot resolve a new session pending revoke',()async{
    await loseRevokeReceipt();api.delayedSent=Completer();final oldRead=c.loadSent();
    c.bindSession(ownerId:'elder',sessionIdentity:'replacement-session',role:UserRole.elder);
    currentLink=link();c.bindFamilyAuthorization(generation:1,links:[currentLink],accessUncertain:false);
    await loseRevokeReceipt();api.delayedSent!.complete([terminal()]);expect(await oldRead,isFalse);
    expect(c.status,'result_unconfirmed');expect(c.prepareShare(card(id:'new-card'),currentLink),isFalse);
    expect(await c.revokeShare(sent()),isTrue);expect(api.revokeIds,['share','share','share']);
  });
  test('preview captures only one card with exact live link and recipient identity',(){prepare();final p=c.preview!;expect(p.cardId,'card');expect(p.cardVersion,3);expect(p.publicPayloadHash,digest);expect(p.linkId,'link');expect(p.linkEpoch,7);expect(p.recipientId,'caregiver');expect(p.recipientEmail,'caregiver@example.test');expect(p.publicPayload.toJson().toString(),isNot(contains('origin_message_id')));expect(api.writes,0);});
  test('invitation or missing live scope never substitutes for authorized link',(){expect(c.prepareShare(card(),link(id:'invitation')),isFalse);expect(c.preview,isNull);currentLink=link(scopes:['care_tasks']);c.bindFamilyAuthorization(generation:2,links:[currentLink],accessUncertain:false);expect(c.prepareShare(card(),currentLink),isFalse);expect(api.writes,0);});
  test('share requires acknowledgement and sends only captured request fields',()async{prepare();expect(await c.sendReviewedShare(),isFalse);expect(api.writes,0);c.acknowledgePersonalReview(true);expect(await c.sendReviewedShare(),isTrue);final r=api.requests.single;expect(r.keys.toSet(),{'expected_version','previewed_payload_hash','recipient_id','expected_link_id','expected_link_epoch','client_share_id','personal_review_ack'});expect(r['expected_version'],3);expect(r['previewed_payload_hash'],digest);expect(r['expected_link_id'],'link');expect(r['expected_link_epoch'],7);expect(r['recipient_id'],'caregiver');expect(r['personal_review_ack'],true);expect(r.toString(),isNot(contains('Selected text')));expect(c.status,'shared');expect(c.sent.single.cardId,'card');});
  test('cancelled preview is zero writes and old cancellation cannot clear a newer card',(){prepare();final old=c.preview!.previewId;c.cancelPreview(expectedPreviewId:old);expect(c.preview,isNull);prepare();final newer=c.preview;c.cancelPreview(expectedPreviewId:old);expect(c.preview,same(newer));expect(api.writes,0);});
  test('same-name recipients must be selected by exact id and email',(){final other=link(id:'other-link',recipient:'other',email:'other@example.test');c.bindFamilyAuthorization(generation:2,links:[currentLink,other],accessUncertain:false);expect(c.prepareShare(card(),other),isTrue);expect(c.preview!.recipientId,'other');expect(c.preview!.recipientEmail,'other@example.test');expect(c.preview!.personalReviewAck,isFalse);});
  test('changing recipient clears the earlier acknowledgement and operation key',(){prepare();c.acknowledgePersonalReview(true);final old=c.preview!.clientShareId;final other=link(id:'other-link',recipient:'other',email:'other@example.test');c.bindFamilyAuthorization(generation:2,links:[currentLink,other],accessUncertain:false);expect(c.preview,isNull);expect(c.prepareShare(card(),other),isTrue);expect(c.preview!.personalReviewAck,isFalse);expect(c.preview!.clientShareId,isNot(old));});
  test('stable authorization refresh retains preview but mutation invalidates immediately',(){prepare();c.acknowledgePersonalReview(true);final old=c.preview;c.bindFamilyAuthorization(generation:1,links:[link()],accessUncertain:false);expect(c.preview,same(old));c.bindFamilyAuthorization(generation:2,links:[],accessUncertain:true);expect(c.preview,isNull);expect(c.inbox,isEmpty);expect(c.sent,isEmpty);expect(c.busy,isFalse);});
  test('reconnection cannot revive an old acknowledged preview',()async{prepare();c.acknowledgePersonalReview(true);c.bindFamilyAuthorization(generation:2,links:[],accessUncertain:true);currentLink=link(epoch:9);c.bindFamilyAuthorization(generation:3,links:[currentLink],accessUncertain:false);expect(await c.sendReviewedShare(),isFalse);expect(api.writes,0);prepare();expect(c.preview!.linkEpoch,9);expect(c.preview!.personalReviewAck,isFalse);});
  test('card mutation invalidates preview before any server result',()async{prepare();c.acknowledgePersonalReview(true);c.invalidateCard('card');expect(c.preview,isNull);expect(await c.sendReviewedShare(),isFalse);expect(api.writes,0);});
  for(final failure in [TimeoutException('synthetic'),const ApiException('synthetic',statusCode:500)]){
    test('unknown ${failure.runtimeType} result retains exact request and key for explicit retry',()async{prepare();c.acknowledgePersonalReview(true);api.failure=failure;expect(await c.sendReviewedShare(),isFalse);expect(c.status,'result_unconfirmed');expect(api.writes,1);expect(api.reads,0);final captured=jsonEncode(api.requests.single);final old=c.preview;c.acknowledgePersonalReview(false);expect(c.preview,same(old));expect(c.prepareShare(card(id:'other'),currentLink),isFalse);api.failure=null;expect(await c.sendReviewedShare(),isTrue);expect(jsonEncode(api.requests.last),captured);expect(api.writes,2);expect(c.sent,hasLength(1));});
  }
  test('409 and 410 do not refresh or resubmit a newer version',()async{prepare();c.acknowledgePersonalReview(true);api.failure=const ApiException('synthetic',statusCode:409);expect(await c.sendReviewedShare(),isFalse);expect(c.status,'conflict');expect(api.writes,1);expect(api.reads,0);});
  test('double click creates only one share operation',()async{prepare();c.acknowledgePersonalReview(true);api.delayedShare=Completer();final pending=c.sendReviewedShare();expect(await c.sendReviewedShare(),isFalse);api.delayedShare!.complete(share());expect(await pending,isTrue);expect(api.writes,1);});
  test('late share cannot repopulate a new account or clear new busy state',()async{prepare();c.acknowledgePersonalReview(true);api.delayedShare=Completer();final pending=c.sendReviewedShare();c.bindSession(ownerId:'other',sessionIdentity:'new',role:UserRole.elder);api.delayedShare!.complete(share());expect(await pending,isFalse);expect(c.preview,isNull);expect(c.sent,isEmpty);expect(c.error,isNull);expect(c.busy,isFalse);});
  test('pair mutation prevents a late successful share from restoring its preview',()async{prepare();c.acknowledgePersonalReview(true);api.delayedShare=Completer();final pending=c.sendReviewedShare();c.bindFamilyAuthorization(generation:2,links:[],accessUncertain:true);api.delayedShare!.complete(share());expect(await pending,isFalse);expect(c.sent,isEmpty);expect(c.preview,isNull);expect(c.busy,isFalse);});
  test('a valid DTO for the wrong recipient or snapshot cannot report success',()async{prepare();c.acknowledgePersonalReview(true);api.result=share(recipient:'other');expect(await c.sendReviewedShare(),isFalse);expect(c.status,'invalid_response');expect(c.sent,isEmpty);});
  test('guest never uses private sharing endpoints',()async{c.bindSession(ownerId:null,sessionIdentity:null,role:null);expect(c.prepareShare(card(),currentLink),isFalse);expect(await c.loadInbox(),isFalse);expect(await c.loadSent(),isFalse);expect(await c.revokeShare(sent()),isFalse);expect(api.reads,0);expect(api.writes,0);});
  test('caregiver inbox rejects foreign recipient and stale link epochs',()async{c.bindSession(ownerId:'caregiver',sessionIdentity:'caregiver-session',role:UserRole.caregiver);currentLink=link();c.bindFamilyAuthorization(generation:1,links:[currentLink],accessUncertain:false);api.inbox=[share()];expect(await c.loadInbox(),isTrue);expect(c.inbox.single.recipientId,'caregiver');api.inbox=[share(recipient:'foreign')];expect(await c.loadInbox(),isFalse);expect(c.inbox,isEmpty);api.inbox=[share(epoch:6)];expect(await c.loadInbox(),isFalse);expect(c.inbox,isEmpty);expect(c.prepareShare(card(),currentLink),isFalse);});
  test('late inbox and sent reads cannot resurrect revoked authorization',()async{api.delayedSent=Completer();final pending=c.loadSent();c.bindFamilyAuthorization(generation:2,links:[],accessUncertain:true);api.delayedSent!.complete([sent()]);expect(await pending,isFalse);expect(c.sent,isEmpty);expect(c.busy,isFalse);});
  test('revoke validates its exact receipt and invalidates old sent reads',()async{api.history=[sent()];expect(await c.loadSent(),isTrue);api.delayedSent=Completer();final oldRead=c.loadSent();expect(await c.revokeShare(sent()),isTrue);expect(c.status,'revoked');api.delayedSent!.complete([sent()]);expect(await oldRead,isFalse);expect(c.sent,isEmpty);});
  test('wrong revoke receipt cannot report success',()async{api.revokeResult=AnswerCardShareRevokeReceipt(id:'other',revoked:true);expect(await c.revokeShare(sent()),isFalse);expect(c.status,'invalid_response');});
}
