import 'dart:async';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';

FamilyConnectionRequest request(String id, String caregiver,
        {FamilyRequestStatus status = FamilyRequestStatus.pending,
        int? version = 1}) =>
    FamilyConnectionRequest(
        id: id,
        elderId: 'elder-1',
        caregiverId: caregiver,
        elderEmail: 'elder@example.test',
        requesterName: 'Same Name',
        requesterEmail: '$caregiver@example.test',
        status: status,
        version: version,
        expiresAt: DateTime.now().add(const Duration(days: 2)));

class ConnectionsFake extends FakeApi implements FamilyConnectionApi {
  final rows = <FamilyConnectionRequest>[];
  final blocks = <FamilyBlock>[];
  final sent = <FamilyMessage>[];
  String? approvedId, rejectedId, blockedId, unblockedId;
  bool failBlock = false;
  Completer<FamilyBlock>? blockPending;
  String? requestedEmail;
  final blockOperationKeys = <String>[];
  List<String>? approvedScopes;
  @override
  Future<List<FamilyConnectionRequest>> listConnectionRequests() async =>
      List.of(rows);
  @override
  Future<List<FamilyBlock>> listFamilyBlocks() async => List.of(blocks);
  @override
  Future<List<FamilyMessage>> listSentFamilyMessages() async => List.of(sent);
  @override
  Future<FamilyConnectionRequest> createConnectionRequest(
      {required String elderEmail, required String clientRequestId}) async {
    requestedEmail = elderEmail;
    return request('new', 'caregiver-1');
  }

  @override
  Future<FamilyInvitation> approveConnectionRequest(
      {required String requestId,
      required int expectedVersion,
      required List<String> scopes}) async {
    approvedId = requestId;
    approvedScopes = scopes;
    return FamilyInvitation(
        id: 'approved-link',
        email: 'a@example.test',
        status: InvitationStatus.accepted,
        elderId: 'elder-1',
        caregiverId: 'carer-a',
        scopes: scopes);
  }

  @override
  Future<FamilyConnectionRequest> rejectConnectionRequest(
      {required String requestId, required int expectedVersion}) async {
    rejectedId = requestId;
    return request(requestId, 'carer-a', status: FamilyRequestStatus.rejected);
  }

  @override
  Future<FamilyConnectionRequest> withdrawConnectionRequest(
          {required String requestId, required int expectedVersion}) async =>
      request(requestId, 'caregiver-1', status: FamilyRequestStatus.revoked);
  @override
  Future<FamilyBlock> blockFamilyPair(
      {required String caregiverId,
      String? requestId,
      String? linkId,
      required String clientOperationId}) async {
    blockedId = caregiverId;
    blockOperationKeys.add(clientOperationId);
    if (failBlock) {
      throw const ApiException('Synthetic timeout', statusCode: 503);
    }
    if (blockPending != null) return blockPending!.future;
    return FamilyBlock(
        elderId: 'elder-1', caregiverId: caregiverId, active: true, version: 1);
  }

  @override
  Future<FamilyBlock> unblockFamilyPair(
      {required String caregiverId,
      required int expectedVersion,
      required String clientOperationId}) async {
    unblockedId = caregiverId;
    return FamilyBlock(
        elderId: 'elder-1',
        caregiverId: caregiverId,
        active: false,
        version: 2);
  }
}

Future<AppController> mount(WidgetTester tester, ConnectionsFake api,
    {Locale locale = englishLocale,
    Size size = const Size(900, 1400),
    double scale = 1,
    double keyboard = 0,
    UserRole role = UserRole.elder,
    Widget? child}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final c =
      AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = AuthSession(
            accessToken: 'synthetic',
            user: AppUser(
                id: role == UserRole.elder ? 'elder-1' : 'caregiver-1',
                email: role == UserRole.elder
                    ? 'elder@example.test'
                    : 'caregiver@example.test',
                displayName: 'Synthetic User',
                role: role));

  await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: child!),
        home: Scaffold(body: child ?? const FamilyScreen()),
      )));
  await tester.pumpAndSettle();
  return c;
}

Future<void> tapVisible(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) {
    await t.scrollUntilVisible(f, 160,
        scrollable: find.byType(Scrollable).first);
  }
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('same-name family identity includes stable account and link IDs',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: InvitationTile(
      invitation: const FamilyInvitation(
          id: 'link-a',
          email: 'a@example.test',
          name: 'Same Name',
          caregiverId: 'caregiver-a',
          elderId: 'elder-1',
          status: InvitationStatus.accepted),
      onRevoke: () {},
    ))));
    expect(find.textContaining('caregiver-a'), findsOneWidget);
    expect(find.textContaining('link-a'), findsOneWidget);
  });
  testWidgets(
      'received requests distinguish same names by email and captured IDs',
      (t) async {
    final api = ConnectionsFake()
      ..rows.addAll(
          [request('request-a', 'carer-a'), request('request-b', 'carer-b')]);
    await mount(t, api);
    expect(find.textContaining('carer-a@example.test'), findsOneWidget);
    expect(find.textContaining('Request ID: request-b'), findsOneWidget);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Approve').first);
    expect(find.textContaining('Request ID: request-a'), findsNWidgets(2));
    final confirm =
        t.widget<FilledButton>(find.byKey(const ValueKey('family-confirm')));
    expect(confirm.onPressed, isNull);
    expect(
        t
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((tile) => tile.value == false),
        isTrue);
    await t.tap(find.byType(CheckboxListTile).first);
    await t.pumpAndSettle();
    await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
    expect(api.approvedId, 'request-a');
    expect(api.approvedScopes, ['care_tasks']);
  });
  testWidgets('reject has separate impact and never calls block', (t) async {
    final api = ConnectionsFake()..rows.add(request('request-a', 'carer-a'));
    await mount(t, api);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Reject'));
    expect(find.text('Reject ends this request. They may send a new request.'),
        findsOneWidget);
    await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
    expect(api.rejectedId, 'request-a');
    expect(api.blockedId, isNull);
  });
  testWidgets('block confirms exact captured pair and its full impact',
      (t) async {
    final api = ConnectionsFake()..rows.add(request('request-a', 'carer-a'));
    await mount(t, api);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Block'));
    expect(
        find.text(
            'Block removes this family connection and stops sending and viewing shared content through it.'),
        findsOneWidget);
    expect(api.blockedId, isNull);
    await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
    expect(api.blockedId, 'carer-a');
    expect(api.rejectedId, isNull);
  });
  testWidgets('unblock explicitly confirms no restoration', (t) async {
    final api = ConnectionsFake()
      ..blocks.add(const FamilyBlock(
          elderId: 'elder-1',
          caregiverId: 'carer-a',
          active: true,
          version: 1));
    final c = await mount(t, api);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Unblock'));
    expect(
        find.text(
            'Unblocking does not restore the connection or previous shares. Reconnecting needs a new invitation and approval.'),
        findsOneWidget);
    await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
    expect(api.unblockedId, 'carer-a');
    expect(c.links, isEmpty);
  });
  testWidgets('unknown request actions are visibly disabled', (t) async {
    final api = ConnectionsFake()
      ..rows.add(request('request-a', 'carer-a',
          status: FamilyRequestStatus.unknown, version: null));
    await mount(t, api);
    for (final name in ['Approve', 'Reject', 'Block']) {
      expect(
          t
              .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, name))
              .onPressed,
          isNull);
    }
    expect(find.textContaining('Incomplete data'), findsOneWidget);
  });
  testWidgets('changed controller generation disables a captured approval',
      (t) async {
    final api = ConnectionsFake()..rows.add(request('request-a', 'carer-a'));
    final c = await mount(t, api);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Approve'));
    await t.tap(find.byType(CheckboxListTile).first);
    await t.pumpAndSettle();
    // A real mutation invalidates the captured dialog generation.
    await c.rejectFamilyConnection(api.rows.first);
    await t.pumpAndSettle();
    expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('family-confirm')))
            .onPressed,
        isNull);
    expect(api.approvedId, isNull);
  });
  testWidgets(
      'sender history preserves own withdrawn body without a resend action',
      (t) async {
    final api = ConnectionsFake()
      ..sent.add(FamilyMessage(
          id: 'sent-a',
          senderId: 'elder-1',
          recipientId: 'carer-a',
          content: 'My original sent text',
          accessRevokedAt: DateTime.now(),
          accessRevocationReason: 'pair_blocked'));
    await mount(t, api);
    await t.ensureVisible(find.text('My original sent text'));
    await t.pumpAndSettle();
    expect(find.text('Access withdrawn'), findsOneWidget);
    expect(find.text('Resend'), findsNothing);
  });
  testWidgets(
      'explicit failed-block retry retains source and operation key after refresh replacement',
      (t) async {
    final api = ConnectionsFake()
      ..failBlock = true
      ..rows.add(request('request-a', 'carer-a'));
    final c = await mount(t, api);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Block'));
    await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
    expect(api.blockOperationKeys.length, 1);
    expect(find.text('Synthetic timeout'), findsOneWidget);
    expect(c.links, isEmpty);
    // A same-name refresh cannot replace the already confirmed retry target.
    api.rows.clear();
    api.rows.add(request('request-other', 'carer-other'));
    api.failBlock = false;
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Retry'));
    expect(api.blockedId, 'carer-a');
    expect(api.blockOperationKeys.length, 2);
    expect(api.blockOperationKeys[1], api.blockOperationKeys[0]);
  });
  testWidgets('family busy disables list actions and captured confirmation',
      (t) async {
    final api = ConnectionsFake()..rows.add(request('request-a', 'carer-a'));
    final c = await mount(t, api);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Approve'));
    await t.tap(find.byType(CheckboxListTile).first);
    await t.pumpAndSettle();
    api.blockPending = Completer<FamilyBlock>();
    final pending = c.blockFamilyConnection(request: api.rows.first);
    await t.pump();
    expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('family-confirm')))
            .onPressed,
        isNull);
    expect(api.approvedId, isNull);
    expect(
        t
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Block'))
            .onPressed,
        isNull);
    api.blockPending!.complete(const FamilyBlock(
        elderId: 'elder-1', caregiverId: 'carer-a', active: true, version: 1));
    await pending;
    await t.pumpAndSettle();
  });
  testWidgets(
      'caregiver request confirms no grant before sending registered elder email',
      (t) async {
    final api = ConnectionsFake();
    await mount(t, api, role: UserRole.caregiver);
    await t.enterText(
        find.byKey(const ValueKey('family-elder-email')), 'ELDER@example.test');
    await tapVisible(
        t, find.widgetWithText(OutlinedButton, 'Request connection'));
    expect(api.requestedEmail, isNull);
    expect(
        find.text(
            'A request grants no access. The registered senior must explicitly approve it.'),
        findsOneWidget);
    await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
    expect(api.requestedEmail, 'elder@example.test');
  });
  testWidgets('legacy invitation and message routes remain available',
      (t) async {
    final api = ConnectionsFake();
    await mount(t, api);
    await tapVisible(
        t, find.widgetWithText(OutlinedButton, 'Invitations and codes'));
    expect(find.byType(LegacyFamilyInvitesScreen), findsOneWidget);
    expect(find.text('Caregiver email'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Family messages'));
    expect(find.byType(FamilyMessagesScreen), findsOneWidget);
  });
  testWidgets(
      'historical revoked link can be blocked with its exact stable source',
      (t) async {
    final api = ConnectionsFake()
      ..fakeLinks.add(const FamilyInvitation(
          id: 'historical-link',
          email: 'old@example.test',
          status: InvitationStatus.revoked,
          elderId: 'elder-1',
          caregiverId: 'carer-old',
          authorizationEpoch: 2,
          caregiverName: 'Same Name',
          caregiverEmail: 'old@example.test'));
    await mount(t, api);
    expect(
        t
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Remove'))
            .onPressed,
        isNull);
    expect(
        t
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Block'))
            .onPressed,
        isNotNull);
    await tapVisible(t, find.widgetWithText(OutlinedButton, 'Block'));
    expect(find.textContaining('Link ID: historical-link'), findsNWidgets(2));
    await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
    expect(api.blockedId, 'carer-old');
  });
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    for (final action in ['Reject', 'Block', 'Unblock']) {
      testWidgets(
          '320px 2x keyboard $action and cancel reachable ${locale.languageCode}',
          (t) async {
        final api = ConnectionsFake();
        if (action == 'Unblock') {
          api.blocks.add(const FamilyBlock(
              elderId: 'elder-1',
              caregiverId: 'carer-a',
              active: true,
              version: 1,
              caregiverName: 'Same Name',
              caregiverEmail: 'carer-a@example.test'));
        } else {
          api.rows.add(request('request-a', 'carer-a'));
        }
        await mount(t, api,
            locale: locale,
            size: const Size(320, 800),
            scale: 2,
            keyboard: 240);
        final labels = {'Reject': '拒絕', 'Block': '封鎖', 'Unblock': '解除封鎖'};
        final label = locale.languageCode == 'en' ? action : labels[action]!;
        await tapVisible(t, find.widgetWithText(OutlinedButton, label));
        expect(t.takeException(), isNull);
        if (locale.languageCode == 'zh') {
          final impacts = {
            'Reject': '拒絕只結束這次申請，對方仍可提出新的申請。',
            'Block': '封鎖會移除這個家庭連接，並停止雙方透過該連接傳送及查看已分享內容。',
            'Unblock': '解除封鎖不會恢復連接或之前的分享。重新連接需要新的邀請及批准。',
          };
          expect(find.text(impacts[action]!), findsOneWidget);
        }
        final cancel = find.widgetWithText(
            OutlinedButton, locale.languageCode == 'en' ? 'Cancel' : '取消');
        await tapVisible(t, cancel);
        expect(api.blockedId, isNull);
        expect(api.rejectedId, isNull);
        expect(api.unblockedId, isNull);
        await tapVisible(t, find.widgetWithText(OutlinedButton, label));
        await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
        if (action == 'Reject') expect(api.rejectedId, 'request-a');
        if (action == 'Block') expect(api.blockedId, 'carer-a');
        if (action == 'Unblock') expect(api.unblockedId, 'carer-a');
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets(
        '320px 2x keyboard approval is scrollable ${locale.languageCode}',
        (t) async {
      final api = ConnectionsFake()..rows.add(request('request-a', 'carer-a'));
      await mount(t, api,
          locale: locale, size: const Size(320, 800), scale: 2, keyboard: 240);
      await tapVisible(
          t,
          find.widgetWithText(
              OutlinedButton, locale.languageCode == 'en' ? 'Approve' : '批准'));
      expect(t.takeException(), isNull);
      await tapVisible(t, find.byType(CheckboxListTile).first);
      await tapVisible(t, find.byKey(const ValueKey('family-confirm')));
      expect(api.approvedId, 'request-a');
      expect(t.takeException(), isNull);
    });
  }
}
