import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_sharing_controller.dart';
import 'package:anxin_companion/src/answer_card_sharing_screen.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'answer_card_share_widget_fixtures.dart';

AnswerCardSharingController sharingController(SharingWidgetApi api, {bool recipient = false}) {
  final controller = AnswerCardSharingController(api: api);
  controller.bindSession(ownerId: recipient ? 'synthetic-recipient-a' : 'synthetic-sender',
    sessionIdentity: 'synthetic-session', role: recipient ? UserRole.caregiver : UserRole.elder);
  controller.bindFamilyAuthorization(generation: 1,
    links: [sharingFirstRecipient, sharingSecondRecipient], accessUncertain: false);
  return controller;
}
Future<void> mountSharing(WidgetTester tester, Widget screen,
    {Locale locale = englishLocale, double scale = 1}) async {
  await tester.pumpWidget(MaterialApp(locale: locale,
    localizationsDelegates: appLocalizationsDelegates, supportedLocales: appSupportedLocales,
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: screen));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('share preview shows only public card plus exact recipient and unchecked review', (tester) async {
    final api = SharingWidgetApi();
    final controller = sharingController(api);
    expect(controller.prepareShare(sharingWidgetCard, sharingFirstRecipient), isTrue);
    await mountSharing(tester, AnswerCardSharePreviewScreen(controller: controller));
    expect(find.text('first@example.test'), findsOneWidget);
    expect(find.text('Same name'), findsOneWidget);
    expect(find.text('Selected public guidance.'), findsOneWidget);
    expect(find.text('Synthetic official term'), findsOneWidget);
    expect(find.text('Confirm availability'), findsOneWidget);
    expect(find.text('Ask the agency'), findsOneWidget);
    expect(find.textContaining('AI answer'), findsWidgets);
    expect(find.textContaining('private-source-id'), findsNothing);
    expect(find.textContaining(sharingWidgetHash), findsNothing);
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('card-share-review'))).value, isFalse);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('card-share-send'))).onPressed, isNull);
    expect(api.shares, 0);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('recipient picker distinguishes duplicate names by exact email without auto selection', (tester) async {
    final api = SharingWidgetApi(); final controller = sharingController(api);
    await mountSharing(tester, AnswerCardRecipientScreen(controller: controller,
      card: sharingWidgetCard, recipients: [sharingFirstRecipient, sharingSecondRecipient]));
    expect(controller.preview, isNull);
    expect(find.text('first@example.test'), findsOneWidget);
    expect(find.text('second@example.test'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-recipient-1')));
    await tester.tap(find.byKey(const ValueKey('card-share-recipient-1')));
    await tester.pumpAndSettle();
    expect(controller.preview!.recipientId, 'synthetic-recipient-b');
    expect(find.text('second@example.test'), findsOneWidget);
    expect(find.text('first@example.test'), findsNothing);
    expect(api.shares, 0);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('explicit acknowledged send captures version hash link epoch without recipient email in payload', (tester) async {
    final api = SharingWidgetApi(); final controller = sharingController(api);
    controller.prepareShare(sharingWidgetCard, sharingFirstRecipient);
    await mountSharing(tester, AnswerCardSharePreviewScreen(controller: controller));
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-review')));
    await tester.tap(find.byKey(const ValueKey('card-share-review')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-send')));
    await tester.tap(find.byKey(const ValueKey('card-share-send')));
    await tester.pumpAndSettle();
    expect(api.shares, 1);
    expect(api.requests.single['expected_version'], 2);
    expect(api.requests.single['previewed_payload_hash'], sharingWidgetHash);
    expect(api.requests.single['expected_link_epoch'], 3);
    expect(api.requests.single['personal_review_ack'], true);
    expect(api.requests.single.toString(), isNot(contains('first@example.test')));
    expect(api.requests.single.toString(), isNot(contains('Selected public guidance.')));
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('cancel clears preview and makes no share write', (tester) async {
    final api = SharingWidgetApi(); final controller = sharingController(api);
    controller.prepareShare(sharingWidgetCard, sharingFirstRecipient);
    await mountSharing(tester, AnswerCardSharePreviewScreen(controller: controller));
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-cancel')));
    await tester.tap(find.byKey(const ValueKey('card-share-cancel')));
    await tester.pumpAndSettle();
    expect(controller.preview, isNull);
    expect(find.text('Selected public guidance.'), findsNothing);
    expect(api.shares, 0);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('unknown share retains checked review and retries the identical key', (tester) async {
    final api = SharingWidgetApi()..shareError = TimeoutException('synthetic');
    final controller = sharingController(api);
    controller.prepareShare(sharingWidgetCard, sharingFirstRecipient);
    await mountSharing(tester, AnswerCardSharePreviewScreen(controller: controller));
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-review')));
    await tester.tap(find.byKey(const ValueKey('card-share-review'))); await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-send')));
    await tester.tap(find.byKey(const ValueKey('card-share-send'))); await tester.pumpAndSettle();
    expect(find.textContaining('unconfirmed'), findsWidgets);
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('card-share-review'))).onChanged, isNull);
    api.shareError = null;
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-send')));
    await tester.tap(find.byKey(const ValueKey('card-share-send'))); await tester.pumpAndSettle();
    expect(api.requests.length, 2); expect(api.requests[0], api.requests[1]);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('conflict never sends again or displays raw error text', (tester) async {
    final api = SharingWidgetApi()..shareError = const ApiException('synthetic private error body', statusCode: 409);
    final controller = sharingController(api);
    controller.prepareShare(sharingWidgetCard, sharingFirstRecipient);
    await mountSharing(tester, AnswerCardSharePreviewScreen(controller: controller));
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-review')));
    await tester.tap(find.byKey(const ValueKey('card-share-review'))); await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-send')));
    await tester.tap(find.byKey(const ValueKey('card-share-send'))); await tester.pumpAndSettle();
    expect(api.shares, 1);
    expect(find.textContaining('synthetic private error body'), findsNothing);
    final send = find.byKey(const ValueKey('card-share-send'));
    if (send.evaluate().isNotEmpty) expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('late share after authorization changes cannot pop a newer route', (tester) async {
    final api = SharingWidgetApi()..delayedShare = Completer();
    final controller = sharingController(api);
    controller.prepareShare(sharingWidgetCard, sharingFirstRecipient);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, locale: englishLocale,
      localizationsDelegates: appLocalizationsDelegates, supportedLocales: appSupportedLocales,
      home: const Scaffold(body: Text('Home'))));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => AnswerCardSharePreviewScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-review')));
    await tester.tap(find.byKey(const ValueKey('card-share-review'))); await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-send')));
    await tester.tap(find.byKey(const ValueKey('card-share-send')));
    await tester.tap(find.byKey(const ValueKey('card-share-send')));
    expect(api.shares, 1);
    controller.bindFamilyAuthorization(generation: 2, links: [], accessUncertain: true);
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('New route'))));
    await tester.pumpAndSettle();
    api.delayedShare!.complete(sharingWidgetShare()); await tester.pumpAndSettle();
    expect(find.text('New route'), findsOneWidget);
    expect(find.text('Selected public guidance.'), findsNothing);
    expect(controller.preview, isNull);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('recipient inbox contains public snapshot and no private-card edit route', (tester) async {
    final api = SharingWidgetApi(); final controller = sharingController(api, recipient: true);
    await mountSharing(tester, AnswerCardSharingScreen(controller: controller, inbox: true));
    await tester.tap(find.text('Selected card 😀')); await tester.pumpAndSettle();
    expect(find.text('Selected public guidance.'), findsOneWidget);
    expect(find.textContaining('AI answer'), findsWidgets);
    expect(find.byKey(const ValueKey('card-private-edit')), findsNothing);
    expect(find.textContaining('private-source-id'), findsNothing);
    controller.bindFamilyAuthorization(generation: 2, links: [], accessUncertain: true);
    await tester.pumpAndSettle();
    expect(find.text('Selected public guidance.'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('sent withdrawal cancellation is zero writes and revoked history contains no old body', (tester) async {
    final api = SharingWidgetApi(); final controller = sharingController(api);
    await mountSharing(tester, AnswerCardSharingScreen(controller: controller));
    await tester.ensureVisible(find.byKey(const ValueKey('card-share-withdraw-0')));
    await tester.tap(find.byKey(const ValueKey('card-share-withdraw-0'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-share-withdraw-cancel'))); await tester.pumpAndSettle();
    expect(api.revokes, 0);
    await tester.tap(find.byKey(const ValueKey('card-share-withdraw-0'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-share-withdraw-confirm'))); await tester.pumpAndSettle();
    expect(api.revokes, 1);
    await tester.ensureVisible(find.byKey(const ValueKey('card-sharing-reload')));
    await tester.tap(find.byKey(const ValueKey('card-sharing-reload'))); await tester.pumpAndSettle();
    expect(find.text('Selected public guidance.'), findsNothing);
    expect(find.textContaining('Revoked'), findsWidgets);
    expect(find.byKey(const ValueKey('card-share-withdraw-0')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('stale withdrawal confirmation cannot pop a newer route or revoke a share', (tester) async {
    final api = SharingWidgetApi(); final controller = sharingController(api);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, locale: englishLocale,
      localizationsDelegates: appLocalizationsDelegates, supportedLocales: appSupportedLocales,
      home: AnswerCardSharingScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-share-withdraw-0'))); await tester.pumpAndSettle();
    final staleConfirm = tester.widget<FilledButton>(find.byKey(const ValueKey('card-share-withdraw-confirm'))).onPressed!;
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('New route'))));
    await tester.pumpAndSettle();
    staleConfirm(); await tester.pumpAndSettle();
    expect(find.text('New route'), findsOneWidget); expect(api.revokes, 0);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
  testWidgets('system back cancels only its share preview with zero writes', (tester) async {
    final api = SharingWidgetApi(); final controller = sharingController(api);
    controller.prepareShare(sharingWidgetCard, sharingFirstRecipient);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, locale: englishLocale,
      localizationsDelegates: appLocalizationsDelegates, supportedLocales: appSupportedLocales,
      home: const Scaffold(body: Text('Home'))));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => AnswerCardSharePreviewScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute(); await tester.pumpAndSettle();
    expect(controller.preview, isNull); expect(api.shares, 0);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Selected public guidance.'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });

  testWidgets('late inbox from an old account cannot expose a snapshot or pop the new route', (tester) async {
    final api = SharingWidgetApi()..delayedInbox = Completer();
    final controller = sharingController(api, recipient: true);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, locale: englishLocale,
      localizationsDelegates: appLocalizationsDelegates, supportedLocales: appSupportedLocales,
      home: const Scaffold(body: Text('Home'))));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => AnswerCardSharingScreen(controller: controller, inbox: true)));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    controller.bindSession(ownerId: 'new-synthetic-owner', sessionIdentity: 'new-session', role: UserRole.caregiver);
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('New account route'))));
    await tester.pumpAndSettle();
    api.delayedInbox!.complete([sharingWidgetShare()]); await tester.pumpAndSettle();
    expect(controller.inbox, isEmpty);
    expect(find.text('New account route'), findsOneWidget);
    expect(find.text('Selected public guidance.'), findsNothing);
    expect(find.text(sharingWidgetCard.publicPayload.title), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
  for (final state in ['missing', 'active', 'unrelated terminal']) {
    testWidgets('unconfirmed withdrawal remains explicitly retryable when history is $state', (tester) async {
      final api = SharingWidgetApi()..revokeError = TimeoutException('synthetic lost acknowledgement');
      final controller = sharingController(api);
      expect(await controller.revokeShare(sharingWidgetSent()), isFalse);
      api.sent = switch (state) {
        'missing' => [],
        'active' => [sharingWidgetSent()],
        _ => [sharingWidgetSent(revoked: true, id: 'other-share', cardId: 'other-card')],
      };
      await mountSharing(tester, AnswerCardSharingScreen(controller: controller));
      final retry = find.byKey(const ValueKey('card-share-withdraw-retry'));
      expect(retry, findsOneWidget);
      expect(find.text('Retry the same withdrawal'), findsOneWidget);
      expect(api.revokes, 1, reason: 'History reload must not resend a withdrawal automatically');
      api.revokeError = null;
      await tester.ensureVisible(retry); await tester.tap(retry); await tester.pumpAndSettle();
      expect(api.revokedIds, ['synthetic-share', 'synthetic-share']);
      expect(find.byKey(const ValueKey('card-share-withdraw-retry')), findsNothing);
      expect(api.shares, 0);
      await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
    });
  }
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets('320px 2x ${locale.languageCode} full card and share review actions are reachable', (tester) async {
      tester.view.physicalSize = const Size(320, 640); tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
      final api = SharingWidgetApi()..expectedCard = sharingLongCard;
      final controller = sharingController(api);
      controller.prepareShare(sharingLongCard, sharingFirstRecipient);
      await mountSharing(tester, AnswerCardSharePreviewScreen(controller: controller), locale: locale, scale: 2);
      final url = find.text(sharingLongCard.publicPayload.publicSources.single.url);
      await tester.ensureVisible(url); expect(url, findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('card-share-review')));
      await tester.tap(find.byKey(const ValueKey('card-share-review'))); await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('card-share-send')));
      expect(find.byKey(const ValueKey('card-share-send')).hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('card-share-cancel')));
      expect(find.byKey(const ValueKey('card-share-cancel')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('card-share-cancel'))); await tester.pumpAndSettle();
      expect(api.shares, 0);
      await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
    });
  }
}
