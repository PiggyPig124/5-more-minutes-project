import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_controller.dart';
import 'package:anxin_companion/src/answer_card_editor.dart';
import 'package:anxin_companion/src/answer_card_screen.dart';
import 'package:anxin_companion/src/localization.dart';
import 'answer_card_widget_fixtures.dart';

Future<void> mountEditor(WidgetTester tester, AnswerCardController controller,
    {Locale locale = englishLocale,
    double scale = 1,
    bool settle = true}) async {
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: appLocalizationsDelegates,
    builder: (context, child) => MediaQuery(
      data:
          MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: AnswerCardEditorScreen(controller: controller),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
  testWidgets('deleting an open card elsewhere retires its old detail body',
      (tester) async {
    final api = WidgetCardsApi()..stored = [widgetOwned()];
    final controller = AnswerCardController(api: api);
    controller.bindSession(ownerId: 'owner', sessionIdentity: 'session');
    await tester.pumpWidget(MaterialApp(
        locale: englishLocale,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        home: AnswerCardsScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Synthetic private card'));
    await tester.tap(find.text('Synthetic private card'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic safe guidance.'), findsOneWidget);
    await controller.deleteCard(controller.cards.single);
    await tester.pumpAndSettle();
    expect(find.text('Synthetic safe guidance.'), findsNothing);
    expect(find.byKey(const ValueKey('card-private-edit')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
      'guest preview with injected API never saves or transfers on login',
      (tester) async {
    final api = WidgetCardsApi();
    final controller = AnswerCardController(api: api);
    controller.prepareGuestAnswer('Synthetic guest guidance.');
    await mountEditor(tester, controller);
    await tester.tap(find.byKey(const ValueKey('card-section-0')));
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-save')), findsNothing);
    expect(find.textContaining('AI answer'), findsWidgets);
    expect(api.writes, 0);
    controller.bindSession(ownerId: 'owner', sessionIdentity: 'login');
    await tester.pumpAndSettle();
    expect(controller.draft, isNull);
    expect(controller.cards, isEmpty);
    expect(api.writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
      'template edited body loses reviewed status and preserves original dates',
      (tester) async {
    final controller = AnswerCardController();
    controller.startTemplate(widgetTemplate);
    await mountEditor(tester, controller);
    await tester.enterText(find.byKey(const ValueKey('card-edit-section-0')),
        'Edited public text');
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    expect(find.text('User edited; unverified'), findsOneWidget);
    expect(find.textContaining('2026-10-03'), findsOneWidget);
    expect(find.text('Edited public text'), findsOneWidget);
    expect(find.text('公共指引 😀'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
      '320px 2x full template long URL and keyboard actions remain reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AnswerCardController();
    controller.startTemplate(widgetTemplate);
    await mountEditor(tester, controller, scale: 2);
    await tester.ensureVisible(find.byKey(const ValueKey('card-title')));
    await tester.tap(find.byKey(const ValueKey('card-title')));
    await tester.showKeyboard(find.byKey(const ValueKey('card-title')));
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.text(widgetTemplate.publicPayload.publicSources.single.url));
    expect(find.text(widgetTemplate.publicPayload.publicSources.single.url),
        findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('card-edit-back')));
    expect(find.byKey(const ValueKey('card-edit-back')).hitTestable(),
        findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('card-cancel')));
    expect(find.byKey(const ValueKey('card-cancel')).hitTestable(),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
      'account switch clears all attached editing controller text immediately',
      (tester) async {
    final controller = AnswerCardController();
    controller.prepareGuestAnswer('Synthetic private body.');
    await mountEditor(tester, controller);
    await tester.tap(find.byKey(const ValueKey('card-section-0')));
    await tester.pumpAndSettle();
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller!)
        .toList();
    expect(fields.any((field) => field.text.contains('Synthetic private body')),
        isTrue);
    controller.bindSession(
        ownerId: 'new-owner', sessionIdentity: 'new-session');
    expect(fields.every((field) => field.text.isEmpty), isTrue);
    await tester.pumpAndSettle();
    expect(find.textContaining('Synthetic private body'), findsNothing);
    expect(controller.draft, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
      'back cancels pending preparation and late completion does not restore text',
      (tester) async {
    final api = WidgetCardsApi()..delayedPrepare = Completer();
    final controller = AnswerCardController(api: api);
    controller.bindSession(ownerId: 'owner', sessionIdentity: 'session');
    final preparing = controller.prepareFromMessage('synthetic-message');
    await mountEditor(tester, controller, settle: false);
    // Loading animates indefinitely; a bounded pump keeps the test responsive.
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    api.delayedPrepare!.complete(widgetSnapshot);
    await preparing;
    await tester.pumpAndSettle();
    expect(controller.draft, isNull);
    expect(find.text('Synthetic private diagnosis.'), findsNothing);
    expect(api.writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
      'private edit saves unchanged body at next version; delete cancel writes nothing',
      (tester) async {
    final api = WidgetCardsApi()..stored = [widgetOwned()];
    final controller = AnswerCardController(api: api);
    controller.bindSession(ownerId: 'owner', sessionIdentity: 'session');
    await tester.pumpWidget(MaterialApp(
        locale: englishLocale,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        home: AnswerCardsScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Synthetic private card'));
    await tester.tap(find.text('Synthetic private card'));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('card-private-delete')));
    await tester.tap(find.byKey(const ValueKey('card-private-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-delete-cancel')));
    await tester.pumpAndSettle();
    expect(api.writes, 0);
    await tester.ensureVisible(find.byKey(const ValueKey('card-private-edit')));
    await tester.tap(find.byKey(const ValueKey('card-private-edit')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('card-save')));
    await tester.tap(find.byKey(const ValueKey('card-save')));
    await tester.pumpAndSettle();
    expect(controller.cards.single.version, 2);
    expect(controller.cards.single.publicPayload.selectedSections,
        ['Synthetic safe guidance.']);
    expect(api.requests.single['expected_version'], 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('card-private-delete')));
    await tester.tap(find.byKey(const ValueKey('card-private-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-delete-confirm')));
    await tester.pumpAndSettle();
    expect(controller.cards, isEmpty);
    expect(api.stored, isEmpty);
    expect(api.writes, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
      'save repeated taps issue one write and late result cannot pop a new route',
      (tester) async {
    final api = WidgetCardsApi()..delayedSave = Completer();
    final controller = AnswerCardController(api: api);
    controller.bindSession(ownerId: 'owner', sessionIdentity: 'session');
    await controller.prepareFromMessage('synthetic-message');
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        locale: englishLocale,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        home: const Scaffold(body: Text('Home'))));
    navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => AnswerCardEditorScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-section-0')));
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('card-save')));
    await tester.tap(find.byKey(const ValueKey('card-save')));
    await tester.tap(find.byKey(const ValueKey('card-save')));
    expect(api.writes, 1);
    controller.bindSession(
        ownerId: 'new-owner', sessionIdentity: 'new-session');
    navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('New route'))));
    await tester.pumpAndSettle();
    api.delayedSave!.complete(widgetOwned(request: api.requests.single));
    await tester.pumpAndSettle();
    expect(find.text('New route'), findsOneWidget);
    expect(find.text('Synthetic private card'), findsNothing);
    expect(controller.cards, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('template preview retains terms, dates, scope and absent date',
      (tester) async {
    final controller = AnswerCardController();
    controller.startTemplate(widgetTemplate);
    await mountEditor(tester, controller);
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    expect(find.text('Official synthetic term'), findsOneWidget);
    expect(find.text('Confirm availability'), findsOneWidget);
    expect(find.text('Ask the agency'), findsOneWidget);
    expect(find.textContaining('2026-10-03'), findsOneWidget);
    expect(find.textContaining('Not provided'), findsWidgets);
    expect(find.textContaining('Chinese'), findsOneWidget);
    expect(find.text('Public guidance only'), findsWidgets);
    expect(find.textContaining('synthetic-source'), findsNothing);
    expect(find.textContaining('a' * 64), findsNothing);
    controller.dispose();
  });

  testWidgets('redacted paragraph is the only body in the final preview',
      (tester) async {
    final controller = AnswerCardController();
    controller.prepareGuestAnswer('Guidance with synthetic diagnosis.');
    await mountEditor(tester, controller);
    await tester.tap(find.byKey(const ValueKey('card-section-0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('card-edit-section-0')),
        'Public guidance only.');
    await tester.pump();
    expect(find.text('Guidance with synthetic diagnosis.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    expect(find.text('Public guidance only.'), findsOneWidget);
    expect(find.textContaining('synthetic diagnosis'), findsNothing);
    expect(find.textContaining('AI answer'), findsWidgets);
    controller.dispose();
  });
  testWidgets(
      'AI paragraphs start unchecked; preview includes only chosen text',
      (tester) async {
    final controller = AnswerCardController();
    controller.prepareGuestAnswer(
        'Useful public guidance.\n\nSynthetic private income.');
    await mountEditor(tester, controller);
    expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((tile) => tile.value == false),
        isTrue);
    await tester.tap(find.byKey(const ValueKey('card-section-0')));
    await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
    await tester.tap(find.byKey(const ValueKey('card-review')));
    await tester.pumpAndSettle();
    expect(find.text('Useful public guidance.'), findsOneWidget);
    expect(find.text('Synthetic private income.'), findsNothing);
    expect(find.byKey(const ValueKey('card-save')), findsNothing);
    expect(find.textContaining('select the content again'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('cancel removes the RAM draft and preview', (tester) async {
    final controller = AnswerCardController();
    controller.prepareGuestAnswer('Synthetic private body.');
    await mountEditor(tester, controller);
    await tester.ensureVisible(find.byKey(const ValueKey('card-cancel')));
    await tester.tap(find.byKey(const ValueKey('card-cancel')));
    await tester.pumpAndSettle();
    expect(controller.draft, isNull);
    expect(controller.preview, isNull);
    expect(find.text('Synthetic private body.'), findsNothing);
    controller.dispose();
  });

  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets(
        '320px 2x ${locale.languageCode} owner can focus and confirm selected-only save',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final api = WidgetCardsApi();
      final controller = AnswerCardController(api: api);
      controller.bindSession(ownerId: 'owner', sessionIdentity: 'session');
      await controller.prepareFromMessage('synthetic-message');
      await mountEditor(tester, controller, locale: locale, scale: 2);
      final title = find.byKey(const ValueKey('card-title'));
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.showKeyboard(title);
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('card-section-0')));
      await tester.tap(find.byKey(const ValueKey('card-section-0')));
      await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
      await tester.tap(find.byKey(const ValueKey('card-review')));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic private diagnosis.'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('card-save')));
      expect(find.byKey(const ValueKey('card-save')).hitTestable(),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('card-save')));
      await tester.pumpAndSettle();
      expect(controller.cards.single.version, 1);
      expect(controller.cards.single.publicPayload.selectedSections,
          ['Synthetic safe guidance.']);
      expect(api.writes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('320px 2x ${locale.languageCode} controls remain scrollable',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AnswerCardController();
      controller.prepareGuestAnswer('繁體中文 😀 ${'Long guidance. ' * 50}');
      await mountEditor(tester, controller, locale: locale, scale: 2);
      await tester.ensureVisible(find.byKey(const ValueKey('card-section-0')));
      await tester.tap(find.byKey(const ValueKey('card-section-0')));
      await tester.ensureVisible(find.byKey(const ValueKey('card-review')));
      await tester.tap(find.byKey(const ValueKey('card-review')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('card-cancel')));
      expect(find.byKey(const ValueKey('card-cancel')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('card-cancel')));
      await tester.pumpAndSettle();
      controller.dispose();
    });
  }
}
