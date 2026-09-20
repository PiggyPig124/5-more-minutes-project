import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/app_controller.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:anxin_companion/src/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('elder can sign in and sees private chat navigation', (tester) async {
    final fakeApi = FakeApi(role: UserRole.elder);
    final controller = AppController(api: fakeApi, sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    expect(find.text('登入安心伴'), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'elder@example.com');
    await tester.enterText(fields.at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();
    expect(find.text('我的對話'), findsOneWidget);
    expect(find.text('安心伴 · 長者'), findsOneWidget);
    expect(find.text('安心伴 · 長者'), findsOneWidget);
  });

  testWidgets('caregiver shell has shared tasks and no private chat tab', (tester) async {
    final fakeApi = FakeApi(role: UserRole.caregiver);
    final controller = AppController(api: fakeApi, sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).at(0), 'caregiver@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();

    expect(find.text('照顧概覽'), findsOneWidget);
    expect(find.text('共享任務'), findsOneWidget);
    expect(find.text('我的對話'), findsNothing);
    expect(find.text('長者私密對話'), findsNothing);
  });

  testWidgets('login error stays visible and does not create a fake session', (tester) async {
    final controller = AppController(api: _FailingLoginApi(), sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).at(0), 'elder@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();

    expect(find.text('服務暫時未能連接。'), findsOneWidget);
    expect(find.text('登入安心伴'), findsOneWidget);
  });
}

class _FailingLoginApi extends FakeApi {
  _FailingLoginApi();

  @override
  Future<AuthSession> login({required String email, required String password}) async {
    throw const ApiException('服務暫時未能連接。');
  }
}
