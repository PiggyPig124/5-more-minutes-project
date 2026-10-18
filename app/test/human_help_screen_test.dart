import 'dart:async';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/human_help_screen.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const officialUrl =
    'https://www.swd.gov.hk/en/pubsvc/elderly/cat_careersupp/carersuppo/index.html';
ResourceItem channel(
        {String id = 'swd-carer-support-hotline',
        String? url = officialUrl,
        bool verified = true,
        List<String> nextSteps = const [
          'Ask the social worker about referral steps.'
        ]}) =>
    ResourceItem(
        id: id,
        title: 'Reviewed carer support',
        excerpt: '182 183: social workers provide support 24 hours a day.',
        url: url,
        verifiedAt: verified ? DateTime(2026, 9, 20) : null,
        conditions: const ['Confirm service arrangements with the provider.'],
        nextSteps: nextSteps);

class PublicApi implements GuestResourceApi {
  final queries = <String>[];
  List<ResourceItem> items = [channel()];
  bool fail = false;
  @override
  Future<ResourceSearchResult> searchGuestResources(
      {required String query, int? limit}) async {
    queries.add(query);
    if (fail) throw StateError('Synthetic lookup failure');
    return ResourceSearchResult(items: items);
  }
}

Future<void> mount(WidgetTester tester,
    {GuestResourceApi? api,
    HumanHelpResourceLoader? loader,
    HumanHelpUrlLauncher? launcher,
    VoidCallback? family,
    Locale locale = englishLocale,
    double textScale = 1,
    Size size = const Size(1000, 2200)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: HumanHelpScreen(
          api: api,
          resourceLoader: loader,
          urlLauncher: launcher,
          onOpenFamily: family)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('guest sees verified public help without launching or signing in',
      (tester) async {
    final api = PublicApi();
    final launches = <Uri>[];
    await mount(tester, api: api, launcher: (uri) async {
      launches.add(uri);
      return true;
    });
    expect(find.text('Ask a person'), findsOneWidget);
    expect(
        api.queries, ['carer support', 'home care services', 'elderly centre']);
    expect(find.text('Reviewed carer support'), findsOneWidget);
    expect(find.textContaining('182 183'), findsOneWidget);
    expect(find.text('Verified: 2026-09-20'), findsOneWidget);
    expect(find.text('Source: www.swd.gov.hk'), findsOneWidget);
    expect(find.text('Ask the social worker about referral steps.'),
        findsOneWidget);
    expect(find.text('Confirm service arrangements with the provider.'),
        findsOneWidget);
    expect(find.textContaining('Nothing is sent or registered automatically'),
        findsOneWidget);
    expect(find.textContaining('Sign in and use Family'), findsOneWidget);
    expect(find.textContaining('local emergency services'), findsOneWidget);
    expect(launches, isEmpty);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Open official website'));
    await tester.pumpAndSettle();
    expect(launches, [Uri.parse(officialUrl)]);
    expect(api.queries.length, 3);
  });
  testWidgets('Family opens only after the manual button click',
      (tester) async {
    var opens = 0;
    await mount(tester, api: PublicApi(), family: () => opens++);
    expect(opens, 0);
    expect(find.textContaining('Review the recipient and message'),
        findsOneWidget);
    await tester.tap(find.text('Open Family messages'));
    await tester.pump();
    expect(opens, 1);
  });
  final unsafe = <String, ResourceItem>{
    'unknown ID': channel(id: 'suggested-by-model'),
    'missing date': channel(verified: false),
    'missing URL': channel(url: null),
    'HTTP': channel(url: officialUrl.replaceFirst('https:', 'http:')),
    'host suffix': channel(url: 'https://www.swd.gov.hk.evil.test/help'),
    'userinfo':
        channel(url: officialUrl.replaceFirst('https://', 'https://x@')),
    'nonstandard port':
        channel(url: officialUrl.replaceFirst('.hk/', '.hk:8443/')),
    'unexpected path': channel(url: 'https://www.swd.gov.hk/unreviewed'),
    'query': channel(url: '$officialUrl?private=anything'),
    'fragment': channel(url: '$officialUrl#unreviewed'),
    'missing next steps': channel(nextSteps: const [])
  };
  for (final entry in unsafe.entries) {
    testWidgets('${entry.key} fails closed with empty state and Retry',
        (tester) async {
      var launches = 0;
      await mount(tester, api: PublicApi()..items = [entry.value],
          launcher: (_) async {
        launches++;
        return true;
      });
      expect(find.text('No verified public channel is available right now.'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Open official website'), findsNothing);
      expect(find.textContaining('182 183'), findsNothing);
      expect(launches, 0);
    });
  }
  testWidgets('failed lookup retries generic queries and recovers',
      (tester) async {
    final api = PublicApi()..fail = true;
    await mount(tester, api: api);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open official website'), findsNothing);
    api.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Reviewed carer support'), findsOneWidget);
    expect(api.queries, [
      'carer support',
      'home care services',
      'elderly centre',
      'carer support',
      'home care services',
      'elderly centre'
    ]);
  });
  testWidgets('missing API stays guest accessible with Retry', (tester) async {
    await mount(tester);
    expect(find.text('Ask a person'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open official website'), findsNothing);
  });
  testWidgets(
      'verified emergency instructions survive failed lookup without launch',
      (tester) async {
    var launches = 0;
    await mount(tester, api: PublicApi()..fail = true, launcher: (_) async {
      launches++;
      return true;
    });
    expect(find.textContaining('In Hong Kong, call 999 for immediate danger'),
        findsOneWidget);
    expect(
        find.textContaining('outside Hong Kong use local emergency services'),
        findsOneWidget);
    expect(
        find.textContaining(
            'does not replace emergency services or a personal emergency alarm service'),
        findsOneWidget);
    expect(find.text('Source: Hong Kong Police Force'), findsOneWidget);
    expect(
        find.text(
            'https://www.police.gov.hk/ppp_en/contact_us.html?st=headingOne'),
        findsOneWidget);
    expect(find.text('Checked: 2026-10-15'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(launches, 0);
  });
  testWidgets('failed launch is honest and manually retryable', (tester) async {
    var launches = 0;
    await mount(tester, api: PublicApi(), launcher: (_) async {
      launches++;
      throw StateError('Synthetic launch failure');
    });
    await tester.tap(find.text('Open official website'));
    await tester.pumpAndSettle();
    expect(find.text('Could not open the website. Please try again.'),
        findsOneWidget);
    expect(launches, 1);
    await tester.tap(find.text('Open official website'));
    await tester.pumpAndSettle();
    expect(launches, 2);
  });
  testWidgets('replacement loader clears stale actionable cards during loading',
      (tester) async {
    await mount(tester, api: PublicApi());
    expect(find.text('Open official website'), findsOneWidget);
    final pending = Completer<ResourceSearchResult>();
    await tester.pumpWidget(MaterialApp(
        home: HumanHelpScreen(
            resourceLoader: ({required query, limit}) => pending.future)));
    await tester.pump();
    expect(find.text('Open official website'), findsNothing);
    pending.complete(const ResourceSearchResult());
    await tester.pumpAndSettle();
    expect(find.text('Open official website'), findsNothing);
  });
  testWidgets('late lookup after disposal has no state update', (tester) async {
    final pending = Completer<ResourceSearchResult>();
    await tester.pumpWidget(MaterialApp(
        home: HumanHelpScreen(
            resourceLoader: ({required query, limit}) => pending.future)));
    await tester.pumpWidget(const SizedBox());
    pending.complete(ResourceSearchResult(items: [channel()]));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    testWidgets('${locale.languageCode} controls fit 320px at 200 percent',
        (tester) async {
      var launches = 0;
      var family = 0;
      await mount(tester,
          api: PublicApi(),
          locale: locale,
          size: const Size(320, 640),
          textScale: 2,
          family: () => family++,
          launcher: (_) async {
            launches++;
            return true;
          });
      final familyButton = find.text(
          locale.languageCode == 'en' ? 'Open Family messages' : '開啟家人訊息');
      await tester.scrollUntilVisible(familyButton, 240,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(familyButton.hitTestable(), findsOneWidget);
      await tester.tap(familyButton);
      await tester.pumpAndSettle();
      expect(family, 1);
      final websiteButton = find.text(
          locale.languageCode == 'en' ? 'Open official website' : '開啟官方網站');
      await tester.scrollUntilVisible(websiteButton, 240,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(websiteButton.hitTestable(), findsOneWidget);
      await tester.tap(websiteButton);
      await tester.pumpAndSettle();
      expect(launches, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
