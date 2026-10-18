import 'dart:async';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scam_guest_test.dart' as fixtures;

Map<String, dynamic> record() => {
      'id': 'approved-adcc',
      'source_id': 'scam-phone-fraud',
      'source_content_hash': List.filled(64, 'a').join(),
      'record_version': List.filled(64, 'b').join(),
      'name': 'Approved channel',
      'phone': '18222',
      'source_url': 'https://www.police.gov.hk/ppp_tc/04_crime_matters/adcc/',
      'url':
          'https://www.police.gov.hk/ppp_en/04_crime_matters/adcc/index.html',
      'verified_at': DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String(),
      'expires_at':
          DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String(),
      'source_verified_at': '2026-09-20',
      'status': 'approved',
      'callable': true,
    };

class ApprovalApi extends fixtures.ScamApi {
  List<ScamContact> contacts = [ScamContact.fromJson(record())];
  Completer<List<ScamContact>>? waiting;
  bool failContacts = false;
  @override
  Future<List<ScamContact>> getScamContacts() async {
    if (failContacts) throw const ApiException('Approval unavailable');
    if (waiting != null) return await waiting!.future;
    return contacts;
  }
}

Finder callButton() => find.widgetWithIcon(FilledButton, Icons.call_rounded);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final opened = <String>[];
  setUp(() {
    opened.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
      if (call.method == 'launch') {
        opened.add((call.arguments as Map)['url'] as String);
      }
      return true;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'), null);
  });

  testWidgets('resource text contacts never construct dialing actions',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ScamResourceCard(
      resource: ScamResource(
          id: 'public',
          title: 'Guidance',
          excerpt: 'Public guidance',
          officialContacts: ['Unapproved hotline: 18222']),
    ))));
    expect(find.byType(ActionChip), findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('resource source field cannot smuggle a tel link',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ScamResourceCard(
      resource: ScamResource(
          id: 'public',
          title: 'Guidance',
          excerpt: 'Public guidance',
          sourceUrl: 'tel:18222'),
    ))));
    expect(find.byType(OutlinedButton), findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('legacy phone without approval cannot enable call',
      (tester) async {
    final api = ApprovalApi()
      ..contacts = [const ScamContact(name: 'Legacy', phone: '18222')];
    await fixtures.mount(tester, fixtures.makeController(api));
    final button = tester.widget<FilledButton>(callButton());
    expect(button.onPressed, isNull);
    expect(opened, isEmpty);
  });

  testWidgets(
      'revoked expired future malformed or foreign approval never enables call',
      (tester) async {
    for (final change in <Map<String, dynamic>>[
      {'status': 'revoked'},
      {'status': 'unknown'},
      {'callable': false},
      {'expires_at': '2000-01-01T00:00:00Z'},
      {'verified_at': '2999-01-01T00:00:00Z'},
      {'verified_at': '2026-10-15'},
      {'expires_at': null},
      {'id': ''},
      {'verified_at': '2026-09-31T00:00:00Z'},
      {'verified_at': '2026-10-01T00:00:00+00:99'},
      {'source_verified_at': null},
      {'source_verified_at': '2999-01-01'},
      {
        'source_verified_at': DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10)
      },
      {'expires_at': '2999-01-01T00:00:00Z'},
      {'source_content_hash': 'unknown'},
      {'record_version': ''},
      {'url': 'https://www.police.gov.hk.evil.invalid/'},
      {'url': 'javascript:alert(1)'},
      {'phone': '18222#123'},
    ]) {
      final api = ApprovalApi()
        ..contacts = [
          ScamContact.fromJson({...record(), ...change})
        ];
      await fixtures.mount(tester, fixtures.makeController(api));
      expect(tester.widget<FilledButton>(callButton()).onPressed, isNull,
          reason: change.toString());
      expect(opened, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  for (final scenario in ['revoked', 'removed', 'version_changed', 'failed']) {
    testWidgets('tap rechecks approval and blocks $scenario record',
        (tester) async {
      final api = ApprovalApi();
      final original = record();
      api.contacts = [ScamContact.fromJson(original)];
      await fixtures.mount(tester, fixtures.makeController(api));
      expect(opened, isEmpty);
      if (scenario == 'removed') {
        api.contacts = [];
      } else if (scenario == 'failed') {
        api.failContacts = true;
      } else {
        api.contacts = [
          ScamContact.fromJson({
            ...original,
            if (scenario == 'revoked') 'status': 'revoked',
            if (scenario == 'version_changed')
              'record_version': List.filled(64, 'c').join(),
          })
        ];
      }
      await tester.tap(callButton());
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'current approved call is user initiated and opens only checked tel',
      (tester) async {
    final api = ApprovalApi();
    final original = record();
    api.contacts = [ScamContact.fromJson(original)];
    await fixtures.mount(tester, fixtures.makeController(api));
    expect(opened, isEmpty);
    await tester.tap(callButton());
    await tester.pumpAndSettle();
    expect(opened, ['tel:18222']);
  });

  testWidgets('approval fallback remains readable at 320px and 2x text',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = ApprovalApi()
      ..contacts = [
        ScamContact.fromJson({...record(), 'status': 'revoked'})
      ];
    await fixtures.mount(tester, fixtures.makeController(api));
    await tester.binding.setSurfaceSize(const Size(320, 900));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(opened, isEmpty);
  });

  testWidgets('logout during call approval never opens phone', (tester) async {
    final api = ApprovalApi();
    final controller = fixtures.makeController(api, signedIn: true);
    await fixtures.mount(tester, controller);
    final pending = Completer<List<ScamContact>>();
    final original = api.contacts;
    api.waiting = pending;
    await tester.tap(callButton());
    await tester.pump();
    await controller.logout();
    pending.complete(original);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('official fallback opens only after explicit user action',
      (tester) async {
    final api = ApprovalApi()
      ..contacts = [
        ScamContact.fromJson({...record(), 'status': 'revoked'})
      ];
    await fixtures.mount(tester, fixtures.makeController(api));
    expect(opened, isEmpty);
    await tester
        .tap(find.widgetWithIcon(TextButton, Icons.open_in_new_rounded));
    await tester.pumpAndSettle();
    expect(opened,
        ['https://www.police.gov.hk/ppp_en/04_crime_matters/adcc/index.html']);
  });

  test('old approved packet cannot replace newer revocation', () async {
    final api = ApprovalApi();
    final controller = fixtures.makeController(api);
    final old = Completer<List<ScamContact>>();
    api.waiting = old;
    final pending = controller.refreshScamContacts();
    api.waiting = null;
    api.contacts = [
      ScamContact.fromJson(
          {...record(), 'status': 'revoked', 'phone': '', 'callable': false})
    ];
    await controller.refreshScamContacts();
    old.complete([ScamContact.fromJson(record())]);
    await pending;
    expect(controller.scamContacts.single.phone, isEmpty);
  });

  testWidgets('leaving while approval is being rechecked never opens phone',
      (tester) async {
    final api = ApprovalApi();
    final controller = fixtures.makeController(api);
    await fixtures.mount(tester, controller);
    final pending = Completer<List<ScamContact>>();
    api.waiting = pending;
    await tester.tap(callButton());
    await tester.pump();
    await tester.pageBack();
    pending.complete(api.contacts);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
