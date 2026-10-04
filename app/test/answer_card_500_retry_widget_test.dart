import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_controller.dart';
import 'package:anxin_companion/src/answer_card_editor.dart';
import 'package:anxin_companion/src/answer_card_screen.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'answer_card_widget_fixtures.dart';

class CommittedBut500CrudApi extends WidgetCardsApi {
  CommittedBut500CrudApi(this.operation);
  final String operation;
  Map<String, Object?> captured(Map<String, Object?> request) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(request)) as Map);
  @override
  Future<OwnedAnswerCard> createAnswerCard(Map<String, Object?> request) async {
    writes++;
    requests.add(captured(request));
    if (writes == 1) {
      stored = [widgetOwned(request: request)];
      throw const ApiException('Synthetic500aftercommit', statusCode: 500);
    }
    return stored.single;
  }

  @override
  Future<OwnedAnswerCard> updateAnswerCard(
      String id, Map<String, Object?> request) async {
    writes++;
    requests.add(captured(request));
    if (writes == 1) {
      stored = [
        widgetOwned(
            version: (request['expected_version'] as int) + 1, request: request)
      ];
      throw const ApiException('Synthetic500aftercommit', statusCode: 500);
    }
    return stored.single;
  }

  @override
  Future<AnswerCardDeleteReceipt> deleteAnswerCard(
      {required String cardId,
      required int expectedVersion,
      required String clientOperationId}) async {
    writes++;
    requests.add({
      'card_id': cardId,
      'expected_version': expectedVersion,
      'client_operation_id': clientOperationId
    });
    stored = [];
    if (writes == 1) {
      throw const ApiException('Synthetic500aftercommit', statusCode: 500);
    }
    return AnswerCardDeleteReceipt(
        id: cardId, version: expectedVersion + 1, deleted: true);
  }
}

Future<void> visibleTap(WidgetTester t, Key key) async {
  final f = find.byKey(key);
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  for (final mode in ['create', 'edit']) {
    testWidgets(
        'HTTP500 after committed $mode keeps original-key UI retry reachable',
        (t) async {
      final api = CommittedBut500CrudApi(mode);
      final c = AnswerCardController(api: api)
        ..bindSession(ownerId: 'owner', sessionIdentity: 'session');
      if (mode == 'create') {
        await c.prepareFromMessage('synthetic-message');
        c.selectSection('s0', true);
      } else {
        api.stored = [widgetOwned()];
        await c.loadCards();
        c.startEdit(c.cards.single);
      }
      expect(c.reviewDraft(), isTrue);
      await t
          .pumpWidget(MaterialApp(home: AnswerCardEditorScreen(controller: c)));
      await t.pumpAndSettle();
      await visibleTap(t, const ValueKey('card-save'));
      expect(c.status, 'result_unconfirmed');
      expect(api.writes, 1);
      expect(api.stored, hasLength(1));
      final original = jsonEncode(api.requests.single);
      final title = c.draft!.title;
      c.setTitle('Must not mutate an unresolved operation');
      c.editBack();
      expect(c.draft!.title, title);
      expect(c.draft!.reviewed, isTrue);
      expect(
          t
              .widget<FilledButton>(find.byKey(const ValueKey('card-save')))
              .onPressed,
          isNotNull);
      expect(
          t
              .widget<OutlinedButton>(
                  find.byKey(const ValueKey('card-edit-back')))
              .onPressed,
          isNull);
      await t.pump(const Duration(seconds: 1));
      expect(api.writes, 1);
      await visibleTap(t, const ValueKey('card-save'));
      expect(api.writes, 2);
      expect(jsonEncode(api.requests.last), original);
      expect(api.stored, hasLength(1));
      expect(c.cards.single.version, mode == 'create' ? 1 : 2);
      await t.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
  testWidgets(
      'HTTP500 after committed delete keeps explicit same-version UI retry',
      (t) async {
    final api = CommittedBut500CrudApi('delete')..stored = [widgetOwned()];
    final c = AnswerCardController(api: api)
      ..bindSession(ownerId: 'owner', sessionIdentity: 'session');
    await t.pumpWidget(MaterialApp(home: AnswerCardsScreen(controller: c)));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Synthetic private card'));
    await t.tap(find.text('Synthetic private card'));
    await t.pumpAndSettle();
    await visibleTap(t, const ValueKey('card-private-delete'));
    await visibleTap(t, const ValueKey('card-delete-confirm'));
    expect(api.writes, 1);
    expect(api.stored, isEmpty);
    expect(c.status, 'result_unconfirmed');
    expect(c.cards.single.version, 1);
    final original = jsonEncode(api.requests.single);
    await c.loadCards();
    await t.pumpAndSettle();
    expect(c.cards.single.version, 1);
    expect(api.writes, 1);
    await visibleTap(t, const ValueKey('card-private-delete'));
    await visibleTap(t, const ValueKey('card-delete-confirm'));
    expect(api.writes, 2);
    expect(jsonEncode(api.requests.last), original);
    expect(c.cards, isEmpty);
    expect(find.text('Synthetic safe guidance.'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
