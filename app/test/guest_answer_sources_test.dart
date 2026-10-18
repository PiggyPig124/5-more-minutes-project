import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:anxin_companion/src/localization.dart';

const source = <String,Object?>{
  'source_id':'mtr-journey-planner','organisation':'MTR Corporation',
  'title':'Official journey planner','url':'https://www.mtr.com.hk/ch/customer/main/jp.html',
  'reviewed_at':'2026-09-20','retrieved_at':null,'effective_date':null,
  'verification_scope':'Reviewed resource record only; the AI answer is not verified.',
  'content_hash':'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
};
const replyText='Use the official journey planner. I cannot calculate a route or fare.';
AppController controllerFor(Map<String,Object?> response) {
  final api=RestApiClient(client:MockClient((r)async=>http.Response(jsonEncode(response),200)));
  return AppController(api:api,sessionStore:SessionStore(MemoryLocalStore()))
    ..guestSession=const GuestSession(id:'synthetic-guest');
}
Map<String,Object?> response({List<Object?>? sources,int version=1})=>{
  'reply':replyText,'mode':'official_guidance','answer_card_sources_version':version,
  'answer_card_sources':sources??[source],
};

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  test('guest HTTP reply preserves only versioned public sources in RAM metadata',()async{
    final c=controllerFor(response());
    expect(await c.sendGuestMessage('How do I travel by MTR?'),isTrue);
    final metadata=c.guestMessageMetadata[1];
    expect(metadata?['answer_card_sources']??[],isNotEmpty);
    expect((metadata!['answer_card_sources'] as List).single,source);
    await c.endGuestSession();
    expect(c.guestMessageMetadata,isEmpty);
    c.dispose();
  });
  test('unversioned source snapshots do not become trusted card references',()async{
    final c=controllerFor(response(version:2));
    expect(await c.sendGuestMessage('MTR?'),isTrue);
    expect(c.guestMessageMetadata[1]?['answer_card_sources']??[],isEmpty);
    c.dispose();
  });
  test('arbitrary links and private fields cannot enter public source metadata',()async{
    final c=controllerFor(response(sources:[{...source,'url':'https://evil.invalid/?token=private','private_memory':'private'}]));
    expect(await c.sendGuestMessage('MTR?'),isTrue);
    expect(c.guestMessageMetadata[1]?['answer_card_sources']??[],isEmpty);
    c.dispose();
  });
  testWidgets('current guest answer offers explicit source selection and keeps AI unverified',(t)async{
    final c=controllerFor(response());
    await c.sendGuestMessage('MTR?');
    final message=ChatMessage(id:'guest-1',conversationId:'guest',body:replyText,isFromUser:false,createdAt:null,
      metadata:c.guestMessageMetadata[1]??const{});
    await t.pumpWidget(ProviderScope(overrides:[appControllerProvider.overrideWith((ref)=>c)],child:MaterialApp(
      locale:englishLocale,supportedLocales:appSupportedLocales,localizationsDelegates:appLocalizationsDelegates,
      home:Scaffold(body:MessageBubble(message:message)))));
    await t.pumpAndSettle();
    await t.tap(find.text('Make answer card'));await t.pumpAndSettle();
    expect(find.text('Official journey planner'),findsOneWidget);
    final sourceCheck=find.ancestor(of:find.text('Official journey planner'),matching:find.byType(CheckboxListTile));
    expect(t.widget<CheckboxListTile>(sourceCheck).value,isFalse);
    await t.tap(find.byKey(const ValueKey('card-section-0')));await t.pumpAndSettle();
    await t.ensureVisible(sourceCheck);await t.tap(sourceCheck);await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('card-review')));await t.tap(find.byKey(const ValueKey('card-review')));await t.pumpAndSettle();
    expect(find.text('AI answer; not independently verified'),findsOneWidget);
    expect(find.textContaining('2026-09-20'),findsWidgets);
    expect(find.byKey(const ValueKey('card-save')),findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
