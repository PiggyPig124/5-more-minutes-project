import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_controller.dart';
import 'package:anxin_companion/src/answer_card_export.dart';
import 'package:anxin_companion/src/answer_card_export_api.dart';
import 'package:anxin_companion/src/answer_card_export_screen.dart';
import 'answer_card_widget_fixtures.dart';

class EgressApi extends WidgetCardsApi implements AnswerCardExportApi{
  int exportCalls=0;Completer<AnswerCardExportSnapshot>? pending;
  @override Future<AnswerCardExportSnapshot> getAnswerCardExportPreview(String id,{required int expectedVersion,required String previewedPayloadHash,required bool personalReviewAck})async{
    exportCalls++;expect(id,'synthetic-card');expect(expectedVersion,1);expect(previewedPayloadHash,widgetHash);expect(personalReviewAck,true);
    return pending?.future??Future.value(AnswerCardExportSnapshot(cardVersion:1,publicPayload:stored.single.publicPayload,publicPayloadHash:widgetHash));
  }
}
class TextEgress implements AnswerCardExportPlatform{
  final copies=<String>[];
  @override AnswerCardPrintReservation? reservePrint()=>null;
  @override Future<void> copyText(String text)async{copies.add(text);}
}
Future<AnswerCardController> cards(EgressApi api)async{
  api.stored=[widgetOwned()];final c=AnswerCardController(api:api)..bindSession(ownerId:'synthetic-owner',sessionIdentity:Object());await c.loadCards();return c;
}
Future<void> mount(WidgetTester t,Widget screen)async{
  await t.pumpWidget(MaterialApp(home:Builder(builder:(context)=>Scaffold(body:TextButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>screen)),child:const Text('Open export'))))));
  await t.tap(find.text('Open export'));await t.pumpAndSettle();
}
void main(){
  testWidgets('export requires full public preview and explicit personal review before API or copy',(t)async{
    final api=EgressApi(),out=TextEgress();final c=await cards(api);
    await mount(t,AnswerCardExportScreen(controller:c,api:api,card:c.cards.single,exporter:AnswerCardExporter(platform:out)));
    expect(find.text('Synthetic safe guidance.'),findsOneWidget);expect(find.textContaining('synthetic-message'),findsNothing);
    final button=find.byKey(const ValueKey('card-export-copy'));await t.ensureVisible(button);
    expect(t.widget<FilledButton>(button).onPressed,isNull);expect(api.exportCalls,0);
    final ack=find.byKey(const ValueKey('card-export-ack'));await t.ensureVisible(ack);await t.tap(ack);await t.pump();
    await t.ensureVisible(button);await t.tap(button);await t.pumpAndSettle();
    expect(api.exportCalls,1);expect(out.copies.single,renderCardText(c.cards.single.publicPayload,mode:'assistant_answer'));
    expect(out.copies.single,contains('AI answer'));expect(out.copies.single, isNot(contains('synthetic-message')));
    expect(find.textContaining('copied'),findsOneWidget);c.dispose();
  });
  testWidgets('account change during export validation removes old preview and emits no late clipboard',(t)async{
    final api=EgressApi()..pending=Completer(),out=TextEgress();final c=await cards(api);final old=c.cards.single;
    await mount(t,AnswerCardExportScreen(controller:c,api:api,card:old,exporter:AnswerCardExporter(platform:out)));
    final ack=find.byKey(const ValueKey('card-export-ack'));await t.ensureVisible(ack);await t.tap(ack);await t.pump();
    final copy=find.byKey(const ValueKey('card-export-copy'));await t.ensureVisible(copy);await t.tap(copy);await t.pump();
    c.bindSession(ownerId:'other-owner',sessionIdentity:Object());await t.pumpAndSettle();
    expect(find.text('Synthetic safe guidance.'),findsNothing);expect(find.text('Open export'),findsOneWidget);
    api.pending!.complete(AnswerCardExportSnapshot(cardVersion:1,publicPayload:old.publicPayload,publicPayloadHash:widgetHash));await t.pumpAndSettle();expect(out.copies,isEmpty);c.dispose();
  });
  testWidgets('guest export is local and loses acknowledgment after draft edit',(t)async{
    final c=AnswerCardController()..bindSession(ownerId:null,sessionIdentity:null,guestIdentity:'synthetic-guest');
    c.prepareGuestAnswer('Synthetic public guest text.');c.selectSection(c.draft!.sections.single.id,true);expect(c.reviewDraft(),true);
    final out=TextEgress();await mount(t,AnswerCardExportScreen(controller:c,guestPayload:c.preview!,guestMode:c.draft!.mode,exporter:AnswerCardExporter(platform:out)));
    final ack=find.byKey(const ValueKey('card-export-ack'));await t.ensureVisible(ack);await t.tap(ack);await t.pump();
    final copy=find.byKey(const ValueKey('card-export-copy'));await t.ensureVisible(copy);await t.tap(copy);await t.pumpAndSettle();expect(out.copies.single,contains('Synthetic public guest text.'));
    c.editBack();await t.pumpAndSettle();expect(find.byKey(const ValueKey('card-export-copy')),findsNothing);c.dispose();
  });
}
