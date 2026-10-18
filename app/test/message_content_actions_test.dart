import 'dart:async';
import 'package:anxin_companion/src/message_content_actions.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const original =
    'Original warning: check the official source. No booking or availability is confirmed.';
Widget frame(Object identity,
        {ReadOnlySimplifier? simplify,
        String text = original,
        bool english = true,
        bool large = false}) =>
    MaterialApp(
        locale: english ? englishLocale : traditionalChineseLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
            child: child!),
        home: Scaffold(
            body: SingleChildScrollView(
                child: Column(children: [
          Text(text),
          MessageContentActions(
              key: const ValueKey('actions'),
              original: text,
              sessionIdentity: identity,
              simplify: simplify)
        ]))));
void main() {
  testWidgets('production absence is honest and Repeat is keyboard operable',
      (t) async {
    await t.pumpWidget(frame(Object()));
    final simplify = t
        .widget<OutlinedButton>(find.byKey(const ValueKey('message-simplify')));
    expect(simplify.onPressed, isNull);
    expect(find.textContaining('not available here yet'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-original-copy')), findsOneWidget);
    expect(find.text(original), findsNWidgets(2));
  });
  testWidgets(
      'read-only callback is explicit and original warnings stay visible',
      (t) async {
    int calls = 0;
    final result = Completer<String>();
    final identity = Object();
    Future<String> simplify(String text) {
      expect(text, original);
      calls++;
      return result.future;
    }

    await t.pumpWidget(frame(identity, simplify: simplify));
    expect(calls, 0);
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pump();
    await t
        .ensureVisible(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.pump();
    expect(calls, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(original), findsOneWidget);
    result.complete('Synthetic shorter wording.');
    await t.pumpAndSettle();
    expect(find.text('Synthetic shorter wording.'), findsOneWidget);
    expect(find.text(original), findsNWidgets(2));
    expect(find.textContaining('not independently checked'), findsOneWidget);
  });
  testWidgets('cancel and an older error cannot overwrite a new request',
      (t) async {
    final pending = [Completer<String>(), Completer<String>()];
    int calls = 0;
    final identity = Object();
    Future<String> simplify(String _) => pending[calls++].future;
    await t.pumpWidget(frame(identity, simplify: simplify));
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pump();
    await t
        .ensureVisible(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('message-simplify-cancel')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pump();
    await t
        .ensureVisible(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.pump();
    pending[0].completeError(StateError('old synthetic failure'));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('could not be obtained'), findsNothing);
    pending[1].complete('Current synthetic wording');
    await t.pumpAndSettle();
    expect(find.text('Current synthetic wording'), findsOneWidget);
  });
  testWidgets('session change ignores a late simplification', (t) async {
    final pending = Completer<String>();
    Future<String> simplify(String _) => pending.future;
    await t.pumpWidget(frame(Object(), simplify: simplify));
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pump();
    await t
        .ensureVisible(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.pump();
    await t.pumpWidget(
        frame(Object(), simplify: simplify, text: 'New session original'));
    pending.complete('OLD_PRIVATE_RESULT');
    await t.pumpAndSettle();
    expect(find.text('OLD_PRIVATE_RESULT'), findsNothing);
    expect(find.text(original), findsNothing);
    expect(find.text('New session original'), findsOneWidget);
  });
  testWidgets('empty result fails honestly; disposal suppresses a late error',
      (t) async {
    final identity = Object();
    Future<String> empty(String _) async => '';
    await t.pumpWidget(frame(identity, simplify: empty));
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pump();
    await t
        .ensureVisible(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.pumpAndSettle();
    expect(find.textContaining('could not be obtained'), findsOneWidget);
    expect(find.text(original), findsOneWidget);
    final pending = Completer<String>();
    Future<String> late(String _) => pending.future;
    await t.pumpWidget(frame(identity, simplify: late));
    await t.tap(find.byKey(const ValueKey('message-simplify')));
    await t.pump();
    await t
        .ensureVisible(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.tap(find.byKey(const ValueKey('simplify-consent-confirm')));
    await t.pump();
    await t.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('late'));
    await t.pump();
    expect(t.takeException(), isNull);
  });
  for (final english in [true, false]) {
    testWidgets(
        'content controls wrap at 320px 200 percent ${english ? "en" : "zh"}',
        (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(frame(Object(), english: english, large: true));
      await t.tap(find.byKey(const ValueKey('message-repeat')));
      await t.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('message-original-copy')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
