import 'dart:async';
import 'dart:convert';

import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response activities(List<Map<String, Object?>> rows) =>
    http.Response(jsonEncode({'activities': rows, 'count': rows.length}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, Object?> activity(String id, String title,
        {String district = 'Elsewhere', List<String> tags = const []}) =>
    {
      'id': id,
      'title': title,
      'description': 'Class',
      'organizer': 'Centre',
      'district': district,
      'interest_tags': tags,
      'verified': true,
      'available': true,
      'availability_status': 'date_unknown'
    };

Future<AppController> mountCatalog(WidgetTester tester,
    Future<http.Response> Function(http.Request) handle) async {
  await tester.binding.setSurfaceSize(const Size(1000, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = RestApiClient(client: MockClient((request) async {
    if (request.url.path == '/community/catalog/activities') {
      return handle(request);
    }
    if (request.url.path == '/community/catalog/interests') {
      return http.Response('{"interests":[]}', 200);
    }
    if (request.url.path == '/community/catalog/recommendations') {
      return http.Response('{"recommendations":[]}', 200);
    }
    throw StateError('Unexpected route ${request.url.path}');
  }));
  final controller =
      AppController(api: api, sessionStore: SessionStore(MemoryLocalStore()))
        ..session = AuthSession(
            accessToken: 'test-token',
            user: const AppUser(
                id: 'elder',
                displayName: 'Senior',
                email: 'senior@example.test',
                role: UserRole.elder));
  await tester.pumpWidget(ProviderScope(
    overrides: [appControllerProvider.overrideWith((ref) => controller)],
    child: MaterialApp(
        locale: englishLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const ActivityCatalogScreen()),
  ));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets(
      'server filters find a matching row beyond the default twenty and survive refresh',
      (tester) async {
    final requests = <Uri>[];
    await mountCatalog(tester, (request) async {
      requests.add(request.url);
      final district = request.url.queryParameters['district'];
      final interest = request.url.queryParameters['interest'];
      if (district != null) {
        return activities([
          activity('row-21', 'Matching twenty first row',
              district: district, tags: interest == null ? [] : [interest])
        ]);
      }
      return activities(
          [for (var i = 0; i < 20; i++) activity('row-$i', 'Other row $i')]);
    });
    final dropdown = tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
    final expectedDistrict = dropdown.items!
        .firstWhere((item) =>
            item.child is Text && (item.child as Text).data == 'Sham Shui Po')
        .value!;
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sham Shui Po').last);
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['district'], expectedDistrict);
    expect(find.text('Matching twenty first row'), findsOneWidget);
    await tester.tap(find.text('Calligraphy'));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['district'], expectedDistrict);
    final expectedInterest = requests.last.queryParameters['interest'];
    expect(expectedInterest, isNotNull);
    expect(expectedInterest, isNotEmpty);
    expect(expectedInterest, isNot('Calligraphy'));
    expect(find.text('Matching twenty first row'), findsOneWidget);
    final count = requests.length;
    final refresh =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await refresh.onRefresh();
    await tester.pumpAndSettle();
    expect(requests.length, count + 1);
    expect(requests.last.queryParameters['district'], expectedDistrict);
    expect(requests.last.queryParameters['interest'], expectedInterest);
    expect(find.text('Matching twenty first row'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a slow earlier server filter cannot replace a newer filter result',
      (tester) async {
    final pending = <Completer<http.Response>>[];
    final interests = <String>[];
    final controller = await mountCatalog(tester, (request) async {
      final interest = request.url.queryParameters['interest'];
      if (interest == null) return activities([]);
      interests.add(interest);
      final response = Completer<http.Response>();
      pending.add(response);
      return response.future;
    });
    await tester.tap(find.text('Calligraphy'));
    await tester.pump();
    expect(pending.length, 1,
        reason: 'selecting a filter must query the server');
    await tester.tap(find.text('Gardening'));
    await tester.pump();
    expect(pending.length, 2);
    expect(interests[0], isNot(interests[1]));
    pending[1].complete(activities([
      activity('new', 'New filter result', tags: [interests[1]])
    ]));
    await tester.pumpAndSettle();
    expect(find.text('New filter result'), findsOneWidget);
    pending[0].complete(activities([
      activity('old', 'Late old filter result', tags: [interests[0]])
    ]));
    await tester.pumpAndSettle();
    expect(controller.catalogActivities.map((row) => row.id), ['new']);
    expect(find.text('New filter result'), findsOneWidget);
    expect(find.text('Late old filter result'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
