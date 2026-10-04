import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_sharing_api.dart';

const digest='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String,Object?> payload()=>{'title':'Guidance','selected_sections':['Safe selected text'],'official_terms':<String>[],'missing_information':<String>[],'next_steps':<String>[],'public_sources':<Object>[],'verification_state':'no_verified_source','verification_scope':'Unverified AI guidance'};
Map<String,Object?> shared()=>{'id':'share','mode':'assistant_answer','card_version':3,'sender_id':'elder','recipient_id':'caregiver','link_id':'link','link_epoch':7,'public_payload':payload(),'public_payload_hash':digest,'created_at':'2026-10-04T00:00:00Z'};
Map<String,Object?> sent()=>{...shared(),'card_id':'card','access_revoked_at':null,'access_revocation_reason':null};
Map<String,Object?> request()=>{'expected_version':3,'previewed_payload_hash':digest,'recipient_id':'caregiver','expected_link_id':'link','expected_link_epoch':7,'client_share_id':'operation','personal_review_ack':true};
void main(){
  test('actual synthetic HTTP golden preserves strict sharing contract v2',(){
    final raw=jsonDecode(File('test/fixtures/answer_card_sharing_golden.json').readAsStringSync()) as Map<String,dynamic>;
    expect(raw['contract_version'],2);
    final share=AnswerCardShare.fromJson(raw['share']);
    expect(share.toJson(),raw['share']);
    final sentRows=(raw['sent'] as List).map(AnswerCardSentShare.fromJson).toList();
    validateAnswerCardShareRequest(sentRows.single.cardId,Map<String,Object?>.from(raw['share_request'] as Map));
    expect(sentRows.single.toJson(),(raw['sent'] as List).single);
    for(final row in raw['inbox'] as List){expect(AnswerCardShare.fromJson(row).toJson(),row);}
    for(final name in ['revoked_sent','deleted_sent']){
      for(final row in raw[name] as List){expect(AnswerCardSentShare.fromJson(row).toJson(),row);}
    }
    final deleted=AnswerCardSentShare.fromJson((raw['deleted_sent'] as List).single);
    expect(deleted.publicPayload,isNull);
    expect(deleted.accessRevocationReason,'sender_revoked');
    expect(AnswerCardShareRevokeReceipt.fromJson(raw['revoke']).id,share.id);
  });
  test('share DTO is closed and excludes owner provenance and card id',(){final dto=AnswerCardShare.fromJson(shared());expect(dto.cardVersion,3);expect(dto.linkEpoch,7);expect(dto.mode,'assistant_answer');expect(dto.toJson(),shared());for(final key in ['card_id','provenance','origin_message_id','memory_sources','recipient_email']){expect(()=>AnswerCardShare.fromJson({...shared(),key:'private'}),throwsFormatException);}});
  test('share DTO rejects missing fields, invalid ids versions hashes and forged AI status',(){for(final key in shared().keys){final bad=shared()..remove(key);expect(()=>AnswerCardShare.fromJson(bad),throwsFormatException);}for(final entry in {'card_version':0,'link_epoch':'7','public_payload_hash':'bad','mode':'unknown','recipient_id':''}.entries){expect(()=>AnswerCardShare.fromJson({...shared(),entry.key:entry.value}),throwsFormatException);}expect(()=>AnswerCardShare.fromJson({...shared(),'public_payload':{...payload(),'verification_state':'reviewed_public_guidance'}}),throwsFormatException);});
  test('sent deletion returns no body and requires server revocation metadata',(){final raw={...sent(),'public_payload':null,'access_revoked_at':'2026-10-04T01:00:00Z','access_revocation_reason':'card_deleted'};expect(AnswerCardSentShare.fromJson(raw).publicPayload,isNull);expect(()=>AnswerCardSentShare.fromJson({...sent(),'public_payload':null}),throwsFormatException);expect(()=>AnswerCardSentShare.fromJson({...sent(),'access_revoked_at':'2026-10-04T01:00:00Z'}),throwsFormatException);});
  test('sent historical revocation retains only its public snapshot',(){final raw={...sent(),'access_revoked_at':'2026-10-04T01:00:00Z','access_revocation_reason':'sender_revoked'};final dto=AnswerCardSentShare.fromJson(raw);expect(dto.publicPayload!.selectedSections,['Safe selected text']);expect(dto.toJson(),raw);expect(()=>AnswerCardSentShare.fromJson({...raw,'owner_email':'private'}),throwsFormatException);});
  test('revoke receipt requires exact closed id and literal true',(){expect(AnswerCardShareRevokeReceipt.fromJson({'id':'share','revoked':true}).revoked,isTrue);for(final raw in [{'id':'share','revoked':false},{'id':'share'},{'id':'share','revoked':'true'},{'id':'share','revoked':true,'payload':payload()}]){expect(()=>AnswerCardShareRevokeReceipt.fromJson(raw),throwsFormatException);}});
  test('share request validates captured fields without exposing display body',(){expect(()=>validateAnswerCardShareRequest('card',request()),returnsNormally);for(final key in request().keys){final bad=request()..remove(key);expect(()=>validateAnswerCardShareRequest('card',bad),throwsFormatException);}for(final key in ['public_payload','recipient_email','provenance','content']){expect(()=>validateAnswerCardShareRequest('card',{...request(),key:'private'}),throwsFormatException);}expect(()=>validateAnswerCardShareRequest('card',{...request(),'expected_link_epoch':0}),throwsFormatException);expect(()=>validateAnswerCardShareRequest('card',{...request(),'personal_review_ack':'true'}),throwsFormatException);});
}
