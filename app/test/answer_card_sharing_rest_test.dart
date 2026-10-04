import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:anxin_companion/src/api_client.dart';

Map<String,dynamic> golden()=>jsonDecode(File('test/fixtures/answer_card_sharing_golden.json').readAsStringSync()) as Map<String,dynamic>;
void main(){
  test('sharing REST uses captured owner card and exact inbox sent revoke routes',()async{
    final g=golden(),rows=<http.Request>[];final sent=(g['sent'] as List).single as Map;
    final api=RestApiClient(origin:'http://localhost',client:MockClient((r)async{
      rows.add(r);expect(r.headers['Authorization'],'Bearer synthetic-token');
      final body=r.url.path.endsWith('/inbox')?g['inbox']:r.url.path.endsWith('/sent')?g['sent']:r.url.path.endsWith('/revoke')?g['revoke']:g['share'];
      return http.Response(jsonEncode(body),200,headers:{'content-type':'application/json; charset=utf-8'});
    }))..accessToken='synthetic-token';
    final share=await api.shareAnswerCard(sent['card_id'] as String,Map<String,Object?>.from(g['share_request'] as Map));
    expect((await api.listAnswerCardInbox()).single.id,share.id);expect((await api.listSentAnswerCardShares()).single.cardId,sent['card_id']);
    await api.revokeAnswerCardShare(share.id);
    expect(rows.map((r)=>r.method),['POST','GET','GET','POST']);
    expect(rows.first.url.path,'/answer-cards/${sent['card_id']}/shares');
    expect(jsonDecode(rows.first.body),g['share_request']);expect(jsonDecode(rows.last.body),{});
  });
  test('share reply bound to captured fields despite caller map mutation while pending',()async{
    final g=golden(),request=Map<String,Object?>.from(g['share_request'] as Map),gate=Completer<http.Response>();
    final api=RestApiClient(client:MockClient((r)=>gate.future));
    final pending=api.shareAnswerCard('card',request);request['recipient_id']='changed-after-send';request['expected_link_epoch']=99;
    gate.complete(http.Response(jsonEncode(g['share']),201,headers:{'content-type':'application/json; charset=utf-8'}));
    expect((await pending).recipientId,(g['share'] as Map)['recipient_id']);
  });
  test('valid share DTO with wrong captured recipient version epoch or hash rejects',()async{
    final g=golden();
    for(final extra in [{'recipient_id':'different-recipient'},{'card_version':2},{'link_epoch':2},{'public_payload_hash':'b'*64}]){
      var calls=0;final api=RestApiClient(client:MockClient((r)async{calls++;return http.Response(jsonEncode({...g['share'] as Map,...extra}),201,headers:{'content-type':'application/json; charset=utf-8'});}));
      await expectLater(api.shareAnswerCard('card',Map<String,Object?>.from(g['share_request'] as Map)),throwsA(isA<ApiException>()));expect(calls,1);
    }
  });
  test('share revoked conflict and wrong withdrawal receipt never fetch or replay',()async{
    final g=golden();for(final status in [409,410]){
      var calls=0;final api=RestApiClient(client:MockClient((r)async{calls++;return http.Response('{"detail":"stale"}',status);}));
      await expectLater(api.shareAnswerCard('card',Map<String,Object?>.from(g['share_request'] as Map)),throwsA(isA<ApiException>()));expect(calls,1);
    }
    final api=RestApiClient(client:MockClient((r)async=>http.Response('{"id":"other","revoked":true}',200)));
    await expectLater(api.revokeAnswerCardShare('share'),throwsA(isA<ApiException>()));
  });
}
