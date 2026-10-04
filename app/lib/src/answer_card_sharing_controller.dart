import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'models.dart' show FamilyInvitation,UserRole;
import 'answer_card_sharing_api.dart';
import 'api_client.dart' show ApiException;

class AnswerCardSharePreview {
  const AnswerCardSharePreview({required this.previewId,required this.sessionGeneration,required this.familyGeneration,
    required this.cardId,required this.cardVersion,required this.mode,required this.publicPayload,
    required this.publicPayloadHash,required this.senderId,required this.recipientId,required this.recipientEmail,
    this.recipientName,required this.linkId,required this.linkEpoch,required this.clientShareId,
    required this.personalReviewRequired,required this.personalReviewAck,int cardGeneration=0}):_cardGeneration=cardGeneration;
  final int previewId,sessionGeneration,familyGeneration,cardVersion,linkEpoch,_cardGeneration;
  final String cardId,mode,publicPayloadHash,senderId,recipientId,recipientEmail,linkId,clientShareId;
  final String? recipientName;
  final CardPublicPayload publicPayload;
  final bool personalReviewRequired,personalReviewAck;
  AnswerCardSharePreview _ack(bool value)=>AnswerCardSharePreview(previewId:previewId,sessionGeneration:sessionGeneration,
    familyGeneration:familyGeneration,cardId:cardId,cardVersion:cardVersion,mode:mode,publicPayload:publicPayload,
    publicPayloadHash:publicPayloadHash,senderId:senderId,recipientId:recipientId,recipientEmail:recipientEmail,
    recipientName:recipientName,linkId:linkId,linkEpoch:linkEpoch,clientShareId:clientShareId,
    personalReviewRequired:personalReviewRequired,personalReviewAck:value,cardGeneration:_cardGeneration);
}

/// Sharing is independent from card editing and never persists previews locally.
class AnswerCardSharingController extends ChangeNotifier {
  AnswerCardSharingController({AnswerCardSharingApi? api}):_api=api;
  final AnswerCardSharingApi? _api;
  String? _ownerId,_error,_status;
  Object? _sessionIdentity;
  UserRole? _role;
  int _generation=0,_familyGeneration=0,_previewCounter=0,_tokenCounter=0,_readGeneration=0;
  int? _externalFamilyGeneration,_mutationToken;
  String? _mutationCardId;
  String _authorizationSignature='';
  bool _accessUncertain=true,_disposed=false;
  List<FamilyInvitation> _links=[];
  final _cardGenerations=<String,int>{};
  final _activeReads=<int>{};
  AnswerCardSharePreview? _preview;
  Map<String,Object?>? _pendingShareRequest;
  AnswerCardSentShare? _pendingRevoke;
  List<AnswerCardShare> _inbox=[];
  List<AnswerCardSentShare> _sent=[];
  AnswerCardSharePreview? get preview=>_preview;
  AnswerCardSentShare? get pendingRevoke=>_pendingRevoke;
  List<AnswerCardShare> get inbox=>List.unmodifiable(_inbox);
  List<AnswerCardSentShare> get sent=>List.unmodifiable(_sent);
  bool get busy=>_mutationToken!=null||_activeReads.isNotEmpty;
  String? get error=>_error;
  String? get status=>_status;
  int get generation=>_generation;
  int get familyGeneration=>_familyGeneration;
  bool get _ownerAvailable=>_ownerId!=null&&_ownerId!.trim().isNotEmpty&&(_role==UserRole.elder||_role==UserRole.caregiver);
  bool get _pending=>_pendingShareRequest!=null||_pendingRevoke!=null;
  void _notify(){if(!_disposed)notifyListeners();}
  void _fail(String status){_status=status;_error='The sharing operation could not be confirmed. Review this card and try again.';_notify();}
  String _key()=>'answer-share-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}-${++_tokenCounter}';
  void _invalidateReads(){_readGeneration++;_activeReads.clear();}
  void _clear(){_preview=null;_pendingShareRequest=null;_pendingRevoke=null;_inbox=[];_sent=[];_mutationToken=null;
    _mutationCardId=null;_invalidateReads();_error=null;_status=null;}
  void bindSession({required String? ownerId,required Object? sessionIdentity,required UserRole? role}){
    if(_disposed||(ownerId==_ownerId&&sessionIdentity==_sessionIdentity&&role==_role))return;
    _ownerId=ownerId;_sessionIdentity=sessionIdentity;_role=role;_generation++;_familyGeneration++;
    _links=[];_externalFamilyGeneration=null;_authorizationSignature='';_accessUncertain=true;_cardGenerations.clear();_clear();_notify();
  }
  void bindFamilyAuthorization({required int generation,required List<FamilyInvitation> links,required bool accessUncertain}){
    if(_disposed)return;
    final signature=_signature(links);
    final changed=generation!=_externalFamilyGeneration||signature!=_authorizationSignature||accessUncertain!=_accessUncertain;
    _links=List.unmodifiable(links);_externalFamilyGeneration=generation;_authorizationSignature=signature;_accessUncertain=accessUncertain;
    if(changed){_familyGeneration++;_clear();_notify();}
  }
  bool _live(FamilyInvitation link)=>!_accessUncertain&&link.actionable&&link.allowsFamilyMessages&&
    link.id.trim().isNotEmpty&&link.elderId?.trim().isNotEmpty==true&&link.caregiverId?.trim().isNotEmpty==true&&
    link.elderId!=link.caregiverId&&(link.caregiverEmail?.trim().isNotEmpty??false);
  bool _previewCurrent(AnswerCardSharePreview p)=>!_disposed&&p.sessionGeneration==_generation&&p.familyGeneration==_familyGeneration&&
    p._cardGeneration==(_cardGenerations[p.cardId]??0)&&_preview?.previewId==p.previewId;
  bool _grantMatches(AnswerCardSharePreview p)=>_ownerId==p.senderId&&_role==UserRole.elder&&
    _links.any((link)=>_live(link)&&link.id==p.linkId&&link.authorizationEpoch==p.linkEpoch&&
      link.elderId==p.senderId&&link.caregiverId==p.recipientId&&link.caregiverEmail==p.recipientEmail);
  bool prepareShare(OwnedAnswerCard card,FamilyInvitation link){
    if(_disposed||!_ownerAvailable||_role!=UserRole.elder||_api==null||_mutationToken!=null||_pending)return false;
    if(!_links.any((current)=>identical(current,link))||!_live(link)||link.elderId!=_ownerId){_fail('invalid_preview');return false;}
    try{
      OwnedAnswerCard.fromJson({'id':card.id,'mode':card.mode,'version':card.version,'public_payload':card.publicPayload.toJson(),
        'public_payload_hash':card.publicPayloadHash,'provenance':card.provenance,'created_at':card.createdAt,'updated_at':card.updatedAt});
      final p=AnswerCardSharePreview(previewId:++_previewCounter,sessionGeneration:_generation,familyGeneration:_familyGeneration,
        cardId:card.id,cardVersion:card.version,mode:card.mode,publicPayload:card.publicPayload,publicPayloadHash:card.publicPayloadHash,
        senderId:_ownerId!,recipientId:link.caregiverId!,recipientEmail:link.caregiverEmail!,recipientName:link.caregiverName,
        linkId:link.id,linkEpoch:link.authorizationEpoch!,clientShareId:_key(),
        personalReviewRequired:card.mode=='assistant_answer'||card.publicPayload.verificationState!='reviewed_public_guidance',
        personalReviewAck:false,cardGeneration:_cardGenerations[card.id]??0);
      _preview=p;_error=null;_status=null;_notify();return true;
    }catch(_){_fail('invalid_preview');return false;}
  }
  void acknowledgePersonalReview(bool value){
    if(_disposed||_preview==null||_pending||_mutationToken!=null)return;
    if(!_previewCurrent(_preview!)||!_grantMatches(_preview!)){cancelPreview();return;}
    _preview=_preview!._ack(value);_error=null;_status=null;_notify();
  }
  void cancelPreview({int? expectedPreviewId}){
    if(_disposed||(expectedPreviewId!=null&&expectedPreviewId!=_preview?.previewId))return;
    final id=_preview?.cardId;_preview=null;_pendingShareRequest=null;
    if(id!=null&&_mutationCardId==id&&_pendingRevoke==null){_mutationToken=null;_mutationCardId=null;}
    _error=null;_status=null;_notify();
  }
  void invalidateCard(String cardId){
    if(_disposed)return;
    _cardGenerations[cardId]=(_cardGenerations[cardId]??0)+1;_invalidateReads();_inbox=[];
    _sent=_sent.where((share)=>share.cardId!=cardId).toList();
    if(_preview?.cardId==cardId){_preview=null;_pendingShareRequest=null;}
    if(_pendingRevoke?.cardId==cardId)_pendingRevoke=null;
    if(_mutationCardId==cardId){_mutationToken=null;_mutationCardId=null;}
    _error=null;_status=null;_notify();
  }
  bool _mutationCurrent(int token,int session,int family)=>!_disposed&&token==_mutationToken&&session==_generation&&family==_familyGeneration;
  Future<bool> sendReviewedShare()async{
    final p=_preview;
    if(_disposed||p==null||!_ownerAvailable||_api==null||_mutationToken!=null||_pendingRevoke!=null)return false;
    if(!_previewCurrent(p)||!_grantMatches(p)){cancelPreview(expectedPreviewId:p.previewId);_fail('authorization_changed');return false;}
    if(p.personalReviewRequired&&!p.personalReviewAck){_fail('invalid_preview');return false;}
    final request=_pendingShareRequest??=Map<String,Object?>.unmodifiable({'expected_version':p.cardVersion,
      'previewed_payload_hash':p.publicPayloadHash,'recipient_id':p.recipientId,'expected_link_id':p.linkId,
      'expected_link_epoch':p.linkEpoch,'client_share_id':p.clientShareId,'personal_review_ack':p.personalReviewAck});
    final token=++_tokenCounter,session=_generation,family=_familyGeneration;
    _mutationToken=token;_mutationCardId=p.cardId;_invalidateReads();_error=null;_status=null;_notify();
    try{
      validateAnswerCardShareRequest(p.cardId,request);
      final raw=await _api.shareAnswerCard(p.cardId,request);
      if(!_mutationCurrent(token,session,family)||!_previewCurrent(p))return false;
      final result=AnswerCardShare.fromJson(raw.toJson());
      if(result.mode!=p.mode||result.cardVersion!=p.cardVersion||result.senderId!=p.senderId||result.recipientId!=p.recipientId||
        result.linkId!=p.linkId||result.linkEpoch!=p.linkEpoch||result.publicPayloadHash!=p.publicPayloadHash||
        !_same(result.publicPayload.toJson(),p.publicPayload.toJson())||
        _sent.any((item)=>item.id==result.id&&item.cardId!=p.cardId)){_fail('invalid_response');return false;}
      final item=AnswerCardSentShare(id:result.id,mode:result.mode,cardId:p.cardId,cardVersion:result.cardVersion,
        senderId:result.senderId,recipientId:result.recipientId,linkId:result.linkId,linkEpoch:result.linkEpoch,
        publicPayload:result.publicPayload,publicPayloadHash:result.publicPayloadHash,createdAt:result.createdAt,
        accessRevokedAt:null,accessRevocationReason:null);
      _sent=[item,..._sent.where((old)=>old.id!=item.id)];_preview=null;_pendingShareRequest=null;_status='shared';_error=null;return true;
    }catch(e){if(_mutationCurrent(token,session,family)&&_previewCurrent(p))_mutationFailure(e);return false;
    }finally{if(_mutationCurrent(token,session,family)){_mutationToken=null;_mutationCardId=null;_notify();}}
  }
  bool _readCurrent(int session,int family,int read)=>!_disposed&&session==_generation&&family==_familyGeneration&&read==_readGeneration;
  Future<bool> loadInbox()async{
    if(_disposed||!_ownerAvailable||_api==null||_mutationToken!=null||_accessUncertain)return false;
    final token=++_tokenCounter,session=_generation,family=_familyGeneration,read=_readGeneration;
    _activeReads.add(token);_inbox=[];if(!_pending){_error=null;_status=null;}_notify();
    try{final raw=await _api.listAnswerCardInbox();if(!_readCurrent(session,family,read))return false;
      final result=raw.map((item)=>AnswerCardShare.fromJson(item.toJson())).toList();
      if(!_unique(result.map((item)=>item.id))||result.any((item)=>item.recipientId!=_ownerId||
        !_links.any((link)=>_live(link)&&link.id==item.linkId&&link.authorizationEpoch==item.linkEpoch&&
          link.elderId==item.senderId&&link.caregiverId==item.recipientId))){_fail('invalid_response');return false;}
      _inbox=result;return true;
    }catch(_){if(_readCurrent(session,family,read)&&!_pending)_fail('invalid_response');return false;
    }finally{if(_activeReads.remove(token))_notify();}
  }
  Future<bool> loadSent()async{
    if(_disposed||!_ownerAvailable||_api==null||_mutationToken!=null)return false;
    final token=++_tokenCounter,session=_generation,family=_familyGeneration,read=_readGeneration;
    _activeReads.add(token);_sent=[];if(!_pending){_error=null;_status=null;}_notify();
    try{final raw=await _api.listSentAnswerCardShares();if(!_readCurrent(session,family,read))return false;
      final result=raw.map((item)=>AnswerCardSentShare.fromJson(item.toJson())).toList();
      if(!_unique(result.map((item)=>item.id))||result.any((item)=>item.senderId!=_ownerId||item.recipientId==_ownerId)){
        _fail('invalid_response');return false;}
      final pending=_pendingRevoke;
      if(pending!=null){
        final confirmed=result.any((item)=>item.id==pending.id&&item.cardId==pending.cardId&&
          item.senderId==pending.senderId&&item.recipientId==pending.recipientId&&item.mode==pending.mode&&
          item.cardVersion==pending.cardVersion&&item.linkId==pending.linkId&&item.linkEpoch==pending.linkEpoch&&
          item.publicPayloadHash==pending.publicPayloadHash&&item.createdAt==pending.createdAt&&
          item.accessRevokedAt!=null&&item.accessRevocationReason!=null&&
          (item.publicPayload==null||_same(item.publicPayload!.toJson(),pending.publicPayload?.toJson())));
        if(confirmed){
          _readGeneration++;
          _activeReads.removeWhere((activeToken)=>activeToken!=token);
          _pendingRevoke=null;_status='revoked';_error=null;
        }else{
          // Missing or unrelated history cannot establish the result of this operation.
          // Keep the captured row so an explicit retry still addresses its exact ID.
          _sent=[pending,...result.where((item)=>item.id!=pending.id)];return true;
        }
      }
      _sent=result;return true;
    }catch(_){if(_readCurrent(session,family,read)&&!_pending)_fail('invalid_response');return false;
    }finally{if(_activeReads.remove(token))_notify();}
  }
  Future<bool> revokeShare(AnswerCardSentShare share)async{
    if(_disposed||!_ownerAvailable||_api==null||_mutationToken!=null||_pendingShareRequest!=null||share.senderId!=_ownerId)return false;
    if(_pendingRevoke!=null&&_pendingRevoke!.id!=share.id){_fail('result_unconfirmed');return false;}
    try{AnswerCardSentShare.fromJson(share.toJson());}catch(_){_fail('invalid_response');return false;}
    final captured=_pendingRevoke??=share;
    final token=++_tokenCounter,session=_generation,family=_familyGeneration;
    _mutationToken=token;_mutationCardId=captured.cardId;_invalidateReads();_error=null;_status=null;_notify();
    try{final raw=await _api.revokeAnswerCardShare(captured.id);
      if(!_mutationCurrent(token,session,family))return false;
      final result=AnswerCardShareRevokeReceipt.fromJson({'id':raw.id,'revoked':raw.revoked});
      if(result.id!=captured.id||!result.revoked){_fail('invalid_response');return false;}
      _sent=_sent.where((item)=>item.id!=captured.id).toList();_pendingRevoke=null;_status='revoked';_error=null;return true;
    }catch(e){if(_mutationCurrent(token,session,family))_mutationFailure(e);return false;
    }finally{if(_mutationCurrent(token,session,family)){_mutationToken=null;_mutationCardId=null;_notify();}}
  }
  void _mutationFailure(Object e){
    if(e is ApiException&&(e.statusCode==409||e.statusCode==410)){
      _fail('conflict');
    }else if(e is ApiException&&e.statusCode!=null&&e.statusCode!>=500&&e.statusCode!<=599){
      _fail('result_unconfirmed');
    }else if(e is ApiException&&e.statusCode!=null){
      _fail('unavailable');
    }else if(e is FormatException){
      _fail('invalid_response');
    }else{
      _fail('result_unconfirmed');
    }
  }
  @override void dispose(){_disposed=true;_generation++;_familyGeneration++;_links=[];_cardGenerations.clear();_clear();super.dispose();}
}
String _signature(List<FamilyInvitation> links){
  final entries=links.map((link)=>jsonEncode([link.id,link.elderId,link.caregiverId,link.caregiverEmail,
    link.elderEmail,link.authorizationEpoch,link.status.toString(),List<String>.of(link.scopes)..sort()])).toList()..sort();
  return entries.join('|');
}
bool _unique(Iterable<String> ids){final values=ids.toList();return values.toSet().length==values.length;}
Object? _sorted(Object? value){if(value is Map){final keys=value.keys.cast<String>().toList()..sort();return{for(final key in keys)key:_sorted(value[key])};}if(value is List)return value.map(_sorted).toList();return value;}
bool _same(Object? a,Object? b)=>jsonEncode(_sorted(a))==jsonEncode(_sorted(b));
