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
  testWidgets(
      'elder navigation keeps the five product areas and chat is reachable from Home',
      (tester) async {
    final fakeApi = FakeApi(role: UserRole.elder);
    final controller = AppController(
        api: fakeApi, sessionStore: SessionStore(MemoryLocalStore()));
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

    expect(find.text('首頁'), findsOneWidget);
    expect(find.text('家庭'), findsOneWidget);
    expect(find.text('社區'), findsOneWidget);
    expect(find.text('幫助'), findsOneWidget);
    expect(find.text('設定'), findsOneWidget);
    await tester.tap(find.text('開始聊天'));
    await tester.pumpAndSettle();
    expect(find.text('我的對話'), findsOneWidget);
  });

  testWidgets('caregiver shell has shared tasks and no private chat tab',
      (tester) async {
    final fakeApi = FakeApi(role: UserRole.caregiver);
    final controller = AppController(
        api: fakeApi, sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'caregiver@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();

    expect(find.text('照顧概覽'), findsOneWidget);
    expect(find.text('共享任務'), findsOneWidget);
    expect(find.text('我的對話'), findsNothing);
    expect(find.text('長者私密對話'), findsNothing);
  });

  testWidgets('login error stays visible and does not create a fake session',
      (tester) async {
    final controller = AppController(
        api: _FailingLoginApi(),
        sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'elder@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();

    expect(find.text('服務暫時未能連接。'), findsOneWidget);
    expect(find.text('登入安心伴'), findsOneWidget);
  });

  testWidgets('elder opens memory management from home without auto saving',
      (tester) async {
    final fakeApi = FakeApi(role: UserRole.elder);
    final controller = AppController(
        api: fakeApi, sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'elder@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('我的記憶'), 300);
    expect(find.text('我的記憶'), findsOneWidget);
    expect(fakeApi.fakeMemories, isEmpty);
    await tester.tap(find.text('我的記憶'));
    await tester.pumpAndSettle();
    expect(find.text('由你管理記憶'), findsOneWidget);
    expect(find.textContaining('記憶預設關閉'), findsOneWidget);
    expect(find.textContaining('目前沒有記憶'), findsOneWidget);
  });

  testWidgets(
      'memory library marks agent-auto preference with provenance and controls',
      (tester) async {
    final controller = AppController(
        api: FakeApi(), sessionStore: SessionStore(MemoryLocalStore()))
      ..session = const AuthSession(
        accessToken: 'test',
        user: AppUser(
          id: 'elder-1',
          displayName: 'Senior',
          email: 'elder@example.com',
          role: UserRole.elder,
        ),
      )
      ..memoryConsentEnabled = true;
    final memory = const MemoryRecord(
      id: 'memory-1',
      content: '我以前喜歡粵劇',
      kind: 'preference',
      status: 'confirmed',
      sourceMessageId: 'source-1',
      captureMethod: 'agent_auto',
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: MemoryCard(
            memory: memory,
            onEdit: (_) async {},
            onDelete: (_) async {},
            onSuppress: (_) async {},
          ),
        ),
      ),
    ));

    expect(find.text('Saved automatically'), findsOneWidget);
    expect(
        find.textContaining('saved automatically from chat'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('community memory offer is dismissible and Yes does not fetch',
      (tester) async {
    final controller = AppController(
        api: FakeApi(), sessionStore: SessionStore(MemoryLocalStore()))
      ..session = const AuthSession(
        accessToken: 'test',
        user: AppUser(
          id: 'elder-1',
          displayName: 'Senior',
          email: 'elder@example.com',
          role: UserRole.elder,
        ),
      )
      ..memoryConsentEnabled = true;
    bool? answer;
    final message = ChatMessage(
      id: 'assistant-1',
      conversationId: 'conversation-1',
      body: '好呀。',
      isFromUser: false,
      createdAt: null,
      metadata: const {
        'community_memory_prompt': {
          'memory_id': 'memory-1',
          'memory_content': '我以前喜歡粵劇',
          'topic': '粵劇',
          'prompt_zh': '你之前提過「粵劇」；想唔想看看有沒有相關活動？',
          'prompt_en':
              'You previously mentioned “粵劇”. Would you like to see if there are related activities?',
        },
      },
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => MessageBubble(
              message: message,
              communityPromptAnswer: answer,
              onCommunityPromptAnswered: (value) =>
                  setState(() => answer = value),
            ),
          ),
        ),
      ),
    ));
    expect(find.text('Based on a saved memory'), findsOneWidget);
    expect(find.text('Yes, interested'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);

    await tester.tap(find.text('Yes, interested'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
    expect(
        find.textContaining('nothing was searched or shown'), findsOneWidget);
  });

  testWidgets(
      'family message requires scope and an explicit preview confirmation',
      (tester) async {
    final fakeApi = FakeApi(role: UserRole.elder)
      ..fakeLinks.add(
        const FamilyInvitation(
          id: 'link-1',
          email: 'caregiver@example.com',
          name: '照顧者',
          status: InvitationStatus.accepted,
          scopes: ['care_tasks', 'family_messages'],
          elderId: 'elder-1',
          caregiverId: 'caregiver-1',
        ),
      );
    final controller = AppController(
        api: fakeApi, sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'elder@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('家庭訊息'), 300);
    await tester.tap(find.text('家庭訊息'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '記得飲水');
    await tester.tap(find.text('檢視並確認發送'));
    await tester.pumpAndSettle();
    expect(find.text('請確認後才會發送'), findsOneWidget);
    expect(find.text('收件人：照顧者'), findsOneWidget);
    expect(fakeApi.fakeFamilyMessages, isEmpty);
    await tester.tap(find.text('確認發送'));
    await tester.pumpAndSettle();
    expect(fakeApi.fakeFamilyMessages, hasLength(1));
    expect(find.text('記得飲水'), findsOneWidget);
  });

  testWidgets('family invitation permission is opt in and unchecked by default',
      (tester) async {
    final fakeApi = FakeApi(role: UserRole.elder);
    final controller = AppController(
        api: fakeApi, sessionStore: SessionStore(MemoryLocalStore()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const AnxinApp(),
      ),
    );
    await tester.pump();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'elder@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登入安心伴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    final permission =
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(permission.value, isFalse);
  });
}

class _FailingLoginApi extends FakeApi {
  _FailingLoginApi();

  @override
  Future<AuthSession> login(
      {required String email, required String password}) async {
    throw const ApiException('服務暫時未能連接。');
  }
}
