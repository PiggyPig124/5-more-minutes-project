import 'answer_card_models.dart';
export 'answer_card_models.dart';

abstract interface class AnswerCardSharingApi {
  Future<AnswerCardShare> shareAnswerCard(String cardId,Map<String,Object?> request);
  Future<List<AnswerCardShare>> listAnswerCardInbox();
  Future<List<AnswerCardSentShare>> listSentAnswerCardShares();
  Future<AnswerCardShareRevokeReceipt> revokeAnswerCardShare(String shareId);
}
class AnswerCardShare {
  const AnswerCardShare({required this.id,required this.mode,required this.cardVersion,required this.senderId,
    required this.recipientId,required this.linkId,required this.linkEpoch,required this.publicPayload,
    required this.publicPayloadHash,required this.createdAt});
  final String id,mode,senderId,recipientId,linkId,publicPayloadHash,createdAt;
  final int cardVersion,linkEpoch;
  final CardPublicPayload publicPayload;
  factory AnswerCardShare.fromJson(Object? raw){
    final m=_object(raw,_shareFields);
    final payload=CardPublicPayload.fromJson(m['public_payload']);
    final mode=_mode(m['mode'],payload);
    return AnswerCardShare(id:_id(m['id']),mode:mode,cardVersion:_version(m['card_version']),senderId:_id(m['sender_id']),
      recipientId:_id(m['recipient_id']),linkId:_id(m['link_id']),linkEpoch:_version(m['link_epoch']),
      publicPayload:payload,publicPayloadHash:_hash(m['public_payload_hash']),createdAt:_timestamp(m['created_at']));
  }
  Map<String,Object?> toJson()=>{'id':id,'mode':mode,'card_version':cardVersion,'sender_id':senderId,'recipient_id':recipientId,
    'link_id':linkId,'link_epoch':linkEpoch,'public_payload':publicPayload.toJson(),'public_payload_hash':publicPayloadHash,'created_at':createdAt};
}
class AnswerCardSentShare {
  const AnswerCardSentShare({required this.id,required this.mode,required this.cardId,required this.cardVersion,required this.senderId,
    required this.recipientId,required this.linkId,required this.linkEpoch,required this.publicPayload,
    required this.publicPayloadHash,required this.createdAt,required this.accessRevokedAt,required this.accessRevocationReason});
  final String id,mode,cardId,senderId,recipientId,linkId,publicPayloadHash,createdAt;
  final String? accessRevokedAt,accessRevocationReason;
  final int cardVersion,linkEpoch;
  final CardPublicPayload? publicPayload;
  factory AnswerCardSentShare.fromJson(Object? raw){
    final m=_object(raw,[..._shareFields,'card_id','access_revoked_at','access_revocation_reason']);
    final payload=m['public_payload']==null?null:CardPublicPayload.fromJson(m['public_payload']);
    final revoked=m['access_revoked_at']==null?null:_timestamp(m['access_revoked_at']);
    final reason=m['access_revocation_reason']==null?null:_text(m['access_revocation_reason'],200);
    if((revoked==null)!=(reason==null)||(payload==null&&revoked==null))throw const FormatException('Invalid share revocation metadata');
    return AnswerCardSentShare(id:_id(m['id']),mode:_mode(m['mode'],payload),cardId:_id(m['card_id']),
      cardVersion:_version(m['card_version']),senderId:_id(m['sender_id']),recipientId:_id(m['recipient_id']),
      linkId:_id(m['link_id']),linkEpoch:_version(m['link_epoch']),publicPayload:payload,
      publicPayloadHash:_hash(m['public_payload_hash']),createdAt:_timestamp(m['created_at']),
      accessRevokedAt:revoked,accessRevocationReason:reason);
  }
  Map<String,Object?> toJson()=>{'id':id,'mode':mode,'card_id':cardId,'card_version':cardVersion,'sender_id':senderId,
    'recipient_id':recipientId,'link_id':linkId,'link_epoch':linkEpoch,'public_payload':publicPayload?.toJson(),
    'public_payload_hash':publicPayloadHash,'created_at':createdAt,'access_revoked_at':accessRevokedAt,'access_revocation_reason':accessRevocationReason};
}
class AnswerCardShareRevokeReceipt {
  const AnswerCardShareRevokeReceipt({required this.id,required this.revoked});
  final String id;
  final bool revoked;
  factory AnswerCardShareRevokeReceipt.fromJson(Object? raw){
    final m=_object(raw,const ['id','revoked']);
    if(m['revoked']!=true)throw const FormatException('Invalid share revoke receipt');
    return AnswerCardShareRevokeReceipt(id:_id(m['id']),revoked:true);
  }
}
void validateAnswerCardShareRequest(String cardId,Map<String,Object?> request){
  _id(cardId);final m=_object(request,const ['expected_version','previewed_payload_hash','recipient_id','expected_link_id',
    'expected_link_epoch','client_share_id','personal_review_ack']);
  _version(m['expected_version']);_hash(m['previewed_payload_hash']);_id(m['recipient_id']);_id(m['expected_link_id']);
  _version(m['expected_link_epoch']);_text(m['client_share_id'],200);
  if(m['personal_review_ack'] is! bool)throw const FormatException('Invalid share review acknowledgement');
}
const _shareFields=['id','mode','card_version','sender_id','recipient_id','link_id','link_epoch','public_payload','public_payload_hash','created_at'];
Map<String,Object?> _object(Object? raw,List<String> fields){
  if(raw is! Map||raw.keys.any((k)=>k is! String||!fields.contains(k))||fields.any((key)=>!raw.containsKey(key)))throw const FormatException('Invalid answer card share fields');
  return Map<String,Object?>.from(raw);
}
String _text(Object? raw,int max){
  if(raw is! String||raw.trim().isEmpty||raw.runes.length>max)throw const FormatException('Invalid share text');
  return raw;
}
String _id(Object? raw)=>_text(raw,36);
String _hash(Object? raw){if(raw is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(raw))throw const FormatException('Invalid share hash');return raw;}
int _version(Object? raw){if(raw is! int||raw<1)throw const FormatException('Invalid share version');return raw;}
String _mode(Object? raw,CardPublicPayload? payload){
  if(raw!='assistant_answer'&&raw!='public_template')throw const FormatException('Invalid share origin mode');
  if(raw=='assistant_answer'&&payload?.verificationState=='reviewed_public_guidance')throw const FormatException('AI share cannot be reviewed public guidance');
  return raw as String;
}
String _timestamp(Object? raw){
  final s=_text(raw,100);
  final match=RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|\+00:00)$').firstMatch(s);
  final parsed=DateTime.tryParse(s);
  if(match==null||parsed==null||parsed.toIso8601String().substring(0,10)!=s.substring(0,10)||
    int.parse(match[4]!)>23||int.parse(match[5]!)>59||int.parse(match[6]!)>59){
    throw const FormatException('Invalid share timestamp');
  }
  return s;
}
