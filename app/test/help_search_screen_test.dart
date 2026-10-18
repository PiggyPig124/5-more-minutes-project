import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'help_search_controller_test.dart'
    show ControlledHelpApi, helpResult, helpController, helpSession;

Future<AppController> mountHelp(WidgetTester tester, ControlledHelpApi api,
    {bool guest = true,
    bool routed = false,
    Locale locale = englishLocale}) async {
  final controller = helpController(api, guest: guest);
  await tester.pumpWidget(ProviderScope(
      overrides: [
        appControllerProvider.overrideWith((ref) => controller),
        localeStoreProvider.overrideWithValue(MemoryLocalStore()),
      ],
      child: MaterialApp(
          locale: locale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: routed
              ? Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) => const Scaffold(
                                      appBar: null, body: HelpScreen()))),
                          child: const Text('Open ordinary Help'))))
              : const Scaffold(body: HelpScreen()))));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

void main() {
  testWidgets(
      'logout and account switch clear the view and reject a late old response',
      (tester) async {
    final api = ControlledHelpApi();
    final controller = await mountHelp(tester, api, guest: false);
    await submit(tester, 'old owner query');
    await controller.logout();
    controller.session = helpSession('second-owner');
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await submit(tester, 'second owner query');
    api.pending.first.result.complete(helpResult('old-owner-result'));
    await tester.pump();
    expect(find.text('Searching practical information…'), findsOneWidget);
    expect(controller.guestHelpResources, isEmpty);
    api.pending.last.result.complete(helpResult('new-owner-result'));
    await tester.pumpAndSettle();
    expect(controller.guestHelpResources.single.id, 'new-owner-result');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'signing in from guest Help clears the old query without reissuing it',
      (tester) async {
    final api = ControlledHelpApi();
    final controller = await mountHelp(tester, api);
    await submit(tester, 'guest query');
    expect(
        await controller.login(
            email: 'synthetic@example.invalid', password: 'synthetic'),
        isTrue);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(api.pending.length, 1);
    api.pending.single.result
        .completeError(const ApiException('Old guest failure'));
    await tester.pumpAndSettle();
    expect(find.text('Retry search'), findsNothing);
    expect(find.text('Searching practical information…'), findsNothing);
    expect(controller.guestHelpResources, isEmpty);
    expect(tester.takeException(), isNull);
  });
  for (final guest in [true, false]) {
    testWidgets(
        '${guest ? 'guest' : 'signed-in'} shows waiting until an empty search completes',
        (tester) async {
      final api = ControlledHelpApi();
      await mountHelp(tester, api, guest: guest);
      await submit(tester, 'public query');
      expect(find.text('Searching practical information…'), findsOneWidget);
      expect(
          find.textContaining('No verified information matched'), findsNothing);
      api.pending.single.result.complete(const ResourceSearchResult(
          query: 'public query', retrievalMode: 'keyword'));
      await tester.pumpAndSettle();
      expect(find.text('Searching practical information…'), findsNothing);
      expect(find.textContaining('No verified information matched'),
          findsOneWidget);
    });
  }

  testWidgets('Retry repeats the failed submitted query after input is edited',
      (tester) async {
    final api = ControlledHelpApi();
    await mountHelp(tester, api);
    await submit(tester, 'failed query');
    api.pending.single.result
        .completeError(const ApiException('Synthetic search failure'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unsubmitted edit');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('Retry search'), findsOneWidget);
    await tester.ensureVisible(find.text('Retry search'));
    await tester.pumpAndSettle();
    expect(find.text('Retry search').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Retry search'));
    await tester.pump();
    expect(api.pending.last.query, 'failed query');
    api.pending.last.result.complete(helpResult('retried-result'));
    await tester.pumpAndSettle();
    expect(find.text('retried-result'), findsOneWidget);
    expect(find.text('Retry search'), findsNothing);
  });

  for (final fail in [false, true]) {
    testWidgets(
        'leave/reenter rejects delayed old ${fail ? 'failure' : 'success'}',
        (tester) async {
      final api = ControlledHelpApi();
      final controller = await mountHelp(tester, api, routed: true);
      await tester.tap(find.text('Open ordinary Help'));
      await tester.pumpAndSettle();
      await submit(tester, 'old route query');
      Navigator.of(tester.element(find.byType(HelpScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open ordinary Help'));
      await tester.pumpAndSettle();
      if (fail) {
        api.pending.single.result
            .completeError(const ApiException('Old route failure'));
      } else {
        api.pending.single.result.complete(helpResult('old-route-result'));
      }
      await tester.pumpAndSettle();
      expect(controller.guestHelpResources, isEmpty);
      expect(controller.errorMessage, isNull);
      expect(find.text('old-route-result'), findsNothing);
      expect(find.text('Old route failure'), findsNothing);
      expect(find.text('Retry search'), findsNothing);
      expect(find.text('Searching practical information…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final fail in [false, true]) {
    testWidgets(
        'an older ${fail ? 'failure' : 'success'} cannot end newer waiting state',
        (tester) async {
      final api = ControlledHelpApi();
      final controller = await mountHelp(tester, api);
      await submit(tester, 'old query');
      await submit(tester, 'new query');
      if (fail) {
        api.pending.first.result
            .completeError(const ApiException('Older failure'));
      } else {
        api.pending.first.result.complete(helpResult('older-result'));
      }
      await tester.pump();
      expect(controller.guestHelpResources, isEmpty);
      expect(controller.errorMessage, isNull);
      expect(find.text('Searching practical information…'), findsOneWidget);
      api.pending.last.result.complete(helpResult('newer-result'));
      await tester.pumpAndSettle();
      expect(controller.guestHelpResources.single.id, 'newer-result');
      expect(find.text('Searching practical information…'), findsNothing);
    });
  }

  testWidgets(
      'rapid exit/reentry cannot let the closing view cancel a newer request',
      (tester) async {
    final api = ControlledHelpApi();
    final controller = await mountHelp(tester, api, routed: true);
    await tester.tap(find.text('Open ordinary Help'));
    await tester.pumpAndSettle();
    await submit(tester, 'old route query');
    final navigator = Navigator.of(tester.element(find.byType(HelpScreen)));
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 50));
    navigator.push(MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: HelpScreen(key: Key('replacement-help')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final replacementField = find.descendant(
        of: find.byKey(const Key('replacement-help')),
        matching: find.byType(TextField));
    expect(replacementField, findsOneWidget);
    await tester.enterText(replacementField, 'new route query');
    final field = tester.widget<TextField>(replacementField);
    field.onSubmitted!('new route query');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(api.pending.length, 2);
    expect(
        find.descendant(
            of: find.byKey(const Key('replacement-help')),
            matching: find.text('Searching practical information…')),
        findsOneWidget);
    api.pending.last.result.complete(helpResult('new-route-result'));
    await tester.pumpAndSettle();
    api.pending.first.result.complete(helpResult('old-route-result'));
    await tester.pumpAndSettle();
    expect(controller.guestHelpResources.single.id, 'new-route-result');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'scrolling within Help preserves a pending query and its editable text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = ControlledHelpApi();
    final controller = await mountHelp(tester, api);
    await tester.scrollUntilVisible(find.byType(TextField), 250,
        scrollable: find.byType(Scrollable).first);
    await submit(tester, 'route-owned query');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump();
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump(const Duration(milliseconds: 400));
    api.pending.single.result.complete(helpResult('retained-result'));
    await tester.pumpAndSettle();
    expect(controller.guestHelpResources.map((item) => item.id),
        ['retained-result']);
    await tester.scrollUntilVisible(find.byType(TextField), 250,
        scrollable: find.byType(Scrollable).first);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'route-owned query');
    expect(tester.takeException(), isNull);
  });

  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets('ordinary Help can retry at 320px 200% ${locale.languageCode}',
        (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final api = ControlledHelpApi();
      await mountHelp(tester, api, locale: locale);
      await tester.scrollUntilVisible(find.byType(TextField), 250,
          scrollable: find.byType(Scrollable).first);
      await submit(tester, 'public query');
      api.pending.single.result
          .completeError(StateError('Synthetic unexpected failure'));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final retry =
          find.text(locale.languageCode == 'zh' ? '重試搜尋' : 'Retry search');
      await tester.scrollUntilVisible(retry, 250,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(retry.hitTestable(), findsOneWidget);
      await tester.tap(retry);
      await tester.pump();
      expect(api.pending.length, 2);
      api.pending.last.result.complete(helpResult('layout-result'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
