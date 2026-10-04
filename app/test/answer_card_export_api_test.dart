import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'answer_card_fixtures.dart';

void main(){
  test('owned export preserves captured version hash and explicit acknowledgment',()async{
    final requests=<http.Request>[];
    final api=RestApiClient(origin:'http://localhost',client:MockClient((r)async{
      requests.add(r);return http.Response(jsonEncode({'card_version':1,'public_payload':answerCardFixture()['public_payload'],'public_payload_hash':answerHash}),200,headers:{'content-type':'application/json; charset=utf-8'});
    }))..accessToken='synthetic-token';
    final result=await api.getAnswerCardExportPreview('card-1',expectedVersion:1,previewedPayloadHash:answerHash,personalReviewAck:true);
    expect(result.cardVersion,1);expect(requests.single.method,'POST');
    expect(requests.single.url.path,'/answer-cards/card-1/export-preview');
    expect(jsonDecode(requests.single.body),{'expected_version':1,'previewed_payload_hash':answerHash,'personal_review_ack':true});
    expect(requests.single.headers['Authorization'],'Bearer synthetic-token');
  });
  test('export rejects wrong version hash and private extra fields',()async{
    for(final extra in [ {'card_version':2}, {'public_payload_hash':'b'*64},{'provenance':{'memory_id':'synthetic-private'}}]){
      final api=RestApiClient(client:MockClient((r)async=>http.Response(jsonEncode({'card_version':1,'public_payload':answerCardFixture()['public_payload'],'public_payload_hash':answerHash,...extra}),200,headers:{'content-type':'application/json; charset=utf-8'})));
      await expectLater(api.getAnswerCardExportPreview('card-1',expectedVersion:1,previewedPayloadHash:answerHash,personalReviewAck:true),throwsA(isA<ApiException>()));
    }
  });
  test('export 409 is surfaced without fetching or new validation',()async{
    var calls=0;final api=RestApiClient(client:MockClient((r)async{calls++;return http.Response('{"detail":"changed"}',409);}));
    await expectLater(api.getAnswerCardExportPreview('card-1',expectedVersion:1,previewedPayloadHash:answerHash,personalReviewAck:true),throwsA(isA<ApiException>()));expect(calls,1);
  });
  test('invalid captured values reject before network',()async{
    var calls=0;final api=RestApiClient(client:MockClient((r)async{calls++;return http.Response('{}',200);}));
    await expectLater(api.getAnswerCardExportPreview('card-1',expectedVersion:0,previewedPayloadHash:answerHash,personalReviewAck:true),throwsA(isA<ApiException>()));
    await expectLater(api.getAnswerCardExportPreview('card-1',expectedVersion:1,previewedPayloadHash:'bad',personalReviewAck:true),throwsA(isA<ApiException>()));expect(calls,0);
  });
}
