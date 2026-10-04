import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'app_controller.dart';
import 'models.dart';
import 'memory_controls_panel.dart';
import 'care_controls_screen.dart';
import 'reminders.dart';
import 'reminder_settings_screen.dart';
import 'safety.dart';
import 'speech_input.dart';
import 'storage.dart';
import 'localization.dart';
import 'settings_screen.dart';
import 'group_chat.dart';
import 'task_sharing_screen.dart';
import 'task_access_refresh.dart';
import 'task_details_screen.dart';
import 'family_connections_screen.dart';
import 'answer_card_controller.dart';
import 'answer_card_screen.dart';
import 'answer_card_editor.dart';
import 'answer_card_sharing_controller.dart';
import 'answer_card_sharing_screen.dart';

final apiProvider = Provider<AnxinApi>((ref) => RestApiClient());
final localStoreProvider = Provider<LocalStore>((ref) => SecureLocalStore());
final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SessionStore(ref.watch(localStoreProvider)),
);
final appControllerProvider = ChangeNotifierProvider<AppController>(
  (ref) => AppController(
    api: ref.watch(apiProvider),
    sessionStore: ref.watch(sessionStoreProvider),
    reminderScheduler: ref.watch(reminderSchedulerProvider),
  ),
);

// Card RAM follows the identity of the active authentication/guest session.
// Ordinary chat notifications preserve an unchanged draft.
final answerCardControllerProvider = ChangeNotifierProvider<AnswerCardController>((ref) {
  final source = ref.watch(appControllerProvider.notifier);
  final cards = AnswerCardController(
      api: source.api is AnswerCardApi ? source.api as AnswerCardApi : null);
  void syncSession() => cards.bindSession(
      ownerId: source.session?.user.id,
      sessionIdentity: source.session,
      guestIdentity: source.guestSession?.id);
  syncSession();
  source.addListener(syncSession);
  ref.onDispose(() => source.removeListener(syncSession));
  return cards;
});

final answerCardSharingControllerProvider = ChangeNotifierProvider<AnswerCardSharingController>((ref) {
  final source = ref.watch(appControllerProvider.notifier);
  final cards = ref.watch(answerCardControllerProvider.notifier);
  final sharing = AnswerCardSharingController(
    api: source.api is AnswerCardSharingApi ? source.api as AnswerCardSharingApi : null);
  void sync() {
    sharing.bindSession(ownerId: source.session?.user.id,
      sessionIdentity: source.session, role: source.session?.user.role);
    sharing.bindFamilyAuthorization(generation: source.familyConnectionGeneration,
      links: source.links, accessUncertain: source.familyAuthorizationUncertain);
  }
  void syncCard() {
    final p = sharing.preview;
    if (p == null) return;
    final card = cards.cards.where((x) => x.id == p.cardId).firstOrNull;
    if (cards.busy || cards.draft?.owned?.id == p.cardId || card == null ||
        card.version != p.cardVersion || card.publicPayloadHash != p.publicPayloadHash) {
      sharing.invalidateCard(p.cardId);
    }
  }
  sync(); source.addListener(sync); cards.addListener(syncCard);
  ref.onDispose(() { source.removeListener(sync); cards.removeListener(syncCard); });
  return sharing;
});

void _openAnswerCards(BuildContext context, WidgetRef ref) {
  final cards = ref.read(answerCardControllerProvider);
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AnswerCardsScreen(controller: cards,
        exportApi: ref.read(appControllerProvider).api is AnswerCardExportApi
            ? ref.read(appControllerProvider).api as AnswerCardExportApi : null,
        openInbox: ref.read(appControllerProvider).isSignedIn && ref.read(appControllerProvider).api is AnswerCardSharingApi ? () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AnswerCardSharingScreen(
            controller: ref.read(answerCardSharingControllerProvider), inbox: true))) : null,
        openSent: ref.read(appControllerProvider).isElder && ref.read(appControllerProvider).api is AnswerCardSharingApi ? () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AnswerCardSharingScreen(
            controller: ref.read(answerCardSharingControllerProvider)))) : null,
        onShare: ref.read(appControllerProvider).isElder && ref.read(appControllerProvider).api is AnswerCardSharingApi ? (shareContext, card) {
          final source = ref.read(appControllerProvider);
          Navigator.of(shareContext).push(MaterialPageRoute<void>(builder: (_) =>
            AnswerCardRecipientScreen(controller: ref.read(answerCardSharingControllerProvider),
              card: card, recipients: source.familyMessageLinks)));
        } : null)));
}

void _openAnswerCardDraft(BuildContext context, WidgetRef ref, ChatMessage message) {
  if (message.isFromUser || message.pending || message.body.trim().isEmpty) return;
  final source = ref.read(appControllerProvider);
  final cards = ref.read(answerCardControllerProvider);
  if (cards.busy) return;
  if (source.session != null && message.conversationId != 'guest') {
    unawaited(cards.prepareFromMessage(message.id));
  } else if (source.session == null && source.guestSession != null) {
    cards.prepareGuestAnswer(message.body);
  } else {
    return;
  }
  // Open immediately: Back can retire a still-running prepare operation.
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AnswerCardEditorScreen(controller: cards)));
}

class _AnswerCardsFeature extends ConsumerWidget {
  const _AnswerCardsFeature();
  @override
  Widget build(BuildContext context, WidgetRef ref) => FeatureCard(
      icon: Icons.description_outlined,
      title: tr(context, '答案卡', 'Answer cards'),
      description: tr(context, '查看公共指引，或管理你明確保存的單張答案。',
          'View public guidance and manage answers you explicitly save.'),
      onTap: () => _openAnswerCards(context, ref));
}

final voiceInputProvider = ChangeNotifierProvider<VoiceInputController>(
  (ref) => VoiceInputController(),
);

class AnxinApp extends ConsumerWidget {
  const AnxinApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Anxin Companion',
      locale: ref.watch(localeControllerProvider).locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      builder: (context, child) => ColoredBox(
        color: const Color(0xFFEAF0ED),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: child!,
          ),
        ),
      ),
      home: const RootView(),
    );
  }
}

ThemeData _buildTheme() {
  const teal = Color(0xFF116466);
  const cream = Color(0xFFFFF8EF);
  final scheme = ColorScheme.fromSeed(
    seedColor: teal,
    brightness: Brightness.light,
    surface: cream,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: cream,
    visualDensity: VisualDensity.standard,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: cream,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      toolbarHeight: 68,
      titleTextStyle: TextStyle(
          color: Color(0xFF183D3C), fontSize: 22, fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    textTheme: base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall!
          .copyWith(fontSize: 34, fontWeight: FontWeight.w700),
      headlineSmall: base.textTheme.headlineSmall!
          .copyWith(fontSize: 28, fontWeight: FontWeight.w700),
      titleLarge: base.textTheme.titleLarge!
          .copyWith(fontSize: 24, fontWeight: FontWeight.w700),
      titleMedium: base.textTheme.titleMedium!
          .copyWith(fontSize: 20, fontWeight: FontWeight.w700),
      bodyLarge: base.textTheme.bodyLarge!.copyWith(fontSize: 19, height: 1.45),
      bodyMedium:
          base.textTheme.bodyMedium!.copyWith(fontSize: 17, height: 1.4),
      labelLarge: base.textTheme.labelLarge!
          .copyWith(fontSize: 17, fontWeight: FontWeight.w700),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: teal.withValues(alpha: .28)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: teal.withValues(alpha: .28)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: teal, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
      labelStyle: const TextStyle(fontSize: 17),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      height: 76,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 15)),
    ),
  );
}

class RootView extends ConsumerStatefulWidget {
  const RootView({super.key});

  @override
  ConsumerState<RootView> createState() => _RootViewState();
}

class _RootViewState extends ConsumerState<RootView> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => ref.read(appControllerProvider).initialize());
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    if (!controller.initialized) return const _LoadingView();
    if (controller.guestSession != null) return const GuestShell();
    if (!controller.isSignedIn) return const LoginScreen();
    return ShellScreen(key: ValueKey(controller.user!.id));
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Semantics(
          label: tr(context, '正在連接安心伴服務', 'Connecting to Anxin Companion'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.favorite_rounded,
                  size: 68, color: Color(0xFF116466)),
              const SizedBox(height: 18),
              Text(tr(context, '安心伴', 'Anxin Companion'),
                  style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 18),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  bool _register = false;
  UserRole _role = UserRole.elder;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final controller = ref.read(appControllerProvider);
    if (_register) {
      await controller.register(
        email: _emailController.text,
        password: _passwordController.text,
        displayName: _nameController.text,
        role: _role,
      );
    } else {
      await controller.login(
        email: _emailController.text,
        password: _passwordController.text,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final error = controller.errorMessage;
    return Scaffold(
      appBar: AppBar(actions: [
        TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const SettingsScreen())),
            icon: const Icon(Icons.settings_outlined),
            label: Text(tr(context, '設定', 'Settings')))
      ]),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 30, 24, 36),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.favorite_rounded,
                        size: 72, color: Color(0xFF116466)),
                    const SizedBox(height: 12),
                    Text(tr(context, '安心伴', 'Anxin Companion'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.displaySmall),
                    const SizedBox(height: 8),
                    Text(
                      _register
                          ? tr(
                              context, '建立你的安心伴帳戶', 'Create your Anxin account')
                          : tr(context, '陪你一步一步處理生活大小事',
                              'Support for everyday life, one step at a time'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 30),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                            value: false,
                            label: Text(tr(context, '登入', 'Sign in')),
                            icon: Icon(Icons.login_rounded)),
                        ButtonSegment(
                            value: true,
                            label: Text(tr(context, '註冊', 'Register')),
                            icon: Icon(Icons.person_add_alt_1_rounded)),
                      ],
                      selected: {_register},
                      onSelectionChanged: (values) =>
                          setState(() => _register = values.first),
                    ),
                    const SizedBox(height: 22),
                    if (_register) ...[
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                            labelText: tr(
                                context, '稱呼你甚麼？', 'What should we call you?'),
                            prefixIcon: Icon(Icons.person_outline_rounded)),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                                ? tr(context, '請輸入稱呼', 'Please enter your name')
                                : null,
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(tr(context, '你是', 'I am a'),
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<UserRole>(
                        segments: [
                          ButtonSegment(
                              value: UserRole.elder,
                              label: Text(tr(context, '長者', 'Senior')),
                              icon: Icon(Icons.elderly_rounded)),
                          ButtonSegment(
                              value: UserRole.caregiver,
                              label: Text(tr(context, '照顧者', 'Caregiver')),
                              icon: Icon(Icons.diversity_1_rounded)),
                        ],
                        selected: {_role},
                        onSelectionChanged: (values) =>
                            setState(() => _role = values.first),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(
                          labelText: tr(context, '電郵地址', 'Email address'),
                          prefixIcon: Icon(Icons.email_outlined)),
                      validator: (value) =>
                          value == null || !value.contains('@')
                              ? tr(context, '請輸入有效電郵地址',
                                  'Please enter a valid email address')
                              : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                          labelText: tr(context, '密碼', 'Password'),
                          prefixIcon: Icon(Icons.lock_outline_rounded)),
                      validator: (value) => value == null || value.length < 8
                          ? tr(context, '密碼最少需要 8 個字元',
                              'Use at least 8 characters')
                          : null,
                    ),
                    const SizedBox(height: 18),
                    if (error != null) ErrorBanner(message: error),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: controller.loading ? null : _submit,
                      icon: controller.loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(_register
                              ? Icons.person_add_alt_1_rounded
                              : Icons.login_rounded),
                      label: Text(_register
                          ? tr(context, '建立帳戶', 'Create account')
                          : tr(context, '登入安心伴', 'Sign in')),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56)),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: controller.loading
                          ? null
                          : () async {
                              if (await controller.startGuestSession() &&
                                  context.mounted) {
                                // RootView switches to the session-only guest screen.
                              }
                            },
                      icon: const Icon(Icons.chat_bubble_outline_rounded),
                      label:
                          Text(tr(context, '以訪客身份開始', 'Continue as a guest')),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(54)),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      tr(context, '你的對話只會由伺服器按授權保存和處理。長者私密對話不會因家庭連結而共享。',
                          'Your conversations are stored and processed with your permission. Linking a family member does not share private conversations.'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GuestConversationScreen extends ConsumerStatefulWidget {
  const GuestConversationScreen({super.key});
  @override
  ConsumerState<GuestConversationScreen> createState() =>
      _GuestConversationScreenState();
}

class GuestShell extends ConsumerStatefulWidget {
  const GuestShell({super.key});
  @override
  ConsumerState<GuestShell> createState() => _GuestShellState();
}

class _GuestShellState extends ConsumerState<GuestShell> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '安心伴 · 訪客', 'Anxin · Guest'))),
      body: SafeArea(
          child: [
        ListView(padding: const EdgeInsets.all(20), children: [
          Text(tr(context, '你好，歡迎使用安心伴', 'Welcome to Anxin'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
              tr(context, '你可以先直接問生活問題。訪客對話不會建立長期記憶。',
                  'Ask a practical question right away. Guest chats do not create long-term memories.'),
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 18),
          Card(
              color: const Color(0xFFDDEDEA),
              child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.chat_rounded,
                            size: 34, color: Color(0xFF116466)),
                        const SizedBox(height: 10),
                        Text(tr(context, '生活對話', 'Everyday conversation'),
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 6),
                        Text(tr(context, '用文字慢慢說，安心伴會盡量清楚回答。',
                            'Type at your own pace and Anxin will answer as clearly as possible.')),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) =>
                                        const GuestConversationScreen())),
                            icon: const Icon(Icons.edit_note_rounded),
                            label: Text(tr(context, '開始對話', 'Start chatting'))),
                      ]))),
          const SizedBox(height: 12),
          if (controller.api is AnswerCardApi) ...[
            const _AnswerCardsFeature(),
            const SizedBox(height: 12),
          ],
          FeatureCard(
              icon: Icons.help_outline_rounded,
              title: tr(context, '幫助與生活資訊', 'Help and practical information'),
              description: tr(context, '搜尋有來源和核實日期的資訊。',
                  'Search information with sources and checked dates.'),
              onTap: () => setState(() => _index = 2)),
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(message: controller.errorMessage!)
          ],
        ]),
        const CommunityScreen(),
        const HelpScreen(),
      ][_index]),
      bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (index) => setState(() => _index = index),
          destinations: [
            NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                selectedIcon: const Icon(Icons.home_rounded),
                label: tr(context, '首頁', 'Home')),
            NavigationDestination(
                icon: const Icon(Icons.groups_outlined),
                selectedIcon: const Icon(Icons.groups_rounded),
                label: tr(context, '社區', 'Community')),
            NavigationDestination(
                icon: const Icon(Icons.help_outline_rounded),
                selectedIcon: const Icon(Icons.help_rounded),
                label: tr(context, '幫助', 'Help')),
          ]),
    );
  }
}

class _GuestConversationScreenState
    extends ConsumerState<GuestConversationScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    _text.clear();
    await ref.read(appControllerProvider).sendGuestMessage(value);
    if (mounted && _scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(
          title: Text(tr(context, '訪客對話', 'Guest conversation')),
          actions: [
            TextButton(
                onPressed: controller.loading
                    ? null
                    : () => controller.endGuestSession(),
                child: Text(tr(context, '結束對話', 'End session'))),
          ]),
      body: SafeArea(
          child: Column(children: [
        Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            color: const Color(0xFFDDEDEA),
            child: Text(tr(
                context,
                '訪客對話只在本次工作階段使用，不會保存到記憶庫。結束後，這台裝置上的對話紀錄會清除。',
                'Guest chats are for this session only and are not saved to a memory library. Ending the session clears the conversation from this device.'))),
        Expanded(
          child: controller.guestMessages.isEmpty
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                          tr(context, '你可以直接提出生活上的問題，無需註冊。',
                              'Ask an everyday question without creating an account.'),
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center)))
              : ListView(
                  padding: const EdgeInsets.all(18),
                  controller: _scroll,
                  children: [
                      for (final entry in controller.guestMessages.indexed)
                        MessageBubble(
                            message: ChatMessage(
                                id: 'guest-${entry.$1}',
                                conversationId: 'guest',
                                body: entry.$2.$1,
                                isFromUser: entry.$2.$2,
                                createdAt: null,
                                metadata:
                                    controller.guestMessageMetadata[entry.$1] ??
                                        const {}))
                    ]),
        ),
        if (controller.errorMessage != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ErrorBanner(message: controller.errorMessage!)),
        Material(
            color: Colors.white,
            elevation: 5,
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                      child: TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 4,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                              hintText:
                                  tr(context, '輸入你的問題…', 'Type your question…'),
                              prefixIcon:
                                  const Icon(Icons.edit_note_rounded)))),
                  const SizedBox(width: 8),
                  IconButton.filled(
                      onPressed: controller.loading ? null : _send,
                      tooltip: tr(context, '傳送', 'Send'),
                      icon: controller.loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded)),
                ]))),
      ])),
    );
  }
}

class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({super.key});
  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  final _area = TextEditingController();
  String _topic = '';

  @override
  void dispose() {
    _area.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
        () => ref.read(appControllerProvider).refreshCommunity());
  }

  Future<void> _decide(SkillSuggestion suggestion, String decision) async {
    String? text;
    if (decision == 'edit') {
      final editor = TextEditingController(text: suggestion.suggestion);
      text = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text(tr(context, '修改技能描述', 'Edit skill description')),
                content: TextField(
                    controller: editor,
                    autofocus: true,
                    decoration:
                        InputDecoration(labelText: tr(context, '技能', 'Skill'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(tr(context, '取消', 'Cancel'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, editor.text),
                      child: Text(tr(context, '保存', 'Save')))
                ],
              ));
      editor.dispose();
      if (text == null || text.trim().isEmpty || !mounted) return;
    }
    await ref
        .read(appControllerProvider)
        .decideSkill(suggestion, decision: decision, skill: text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final canPersonalize =
        controller.isElder && controller.memoryConsentEnabled;
    return RefreshIndicator(
        onRefresh: () => controller.refreshCommunity(),
        child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
            children: [
              OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const ActivityCatalogScreen())),
                  icon: const Icon(Icons.event_available),
                  label: Text(tr(context, '活動目錄及感興趣清單',
                      'Activity catalog and interests'))),
              Text(tr(context, '社區', 'Community'),
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                  tr(context, '搜尋社區機構公開的活動和服務。搜尋只會傳送一般主題與地區；報名前請向主辦機構確認。',
                      'Search public pages from community providers. Only a general topic and area are searched; confirm details with the organizer before attending.'),
                  style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 18),
              SectionTitle(title: tr(context, '發揮所長', 'Share your skills')),
              const SizedBox(height: 9),
              if (!controller.isElder)
                EmptyCard(
                    icon: Icons.lock_outline_rounded,
                    message: tr(context, '個人化技能功能只供長者帳戶使用。',
                        'Personal skill features are available to senior accounts.'))
              else if (!controller.memoryConsentEnabled)
                EmptyCard(
                    icon: Icons.lock_outline_rounded,
                    message: tr(context, '開啟記憶功能後，才能根據你確認保存的記憶建議技能。',
                        'Turn on Memory to get skill suggestions based on memories you chose to save.'))
              else if (controller.skillSuggestions.isEmpty)
                EmptyCard(
                    icon: Icons.lightbulb_outline_rounded,
                    message: tr(context, '目前沒有技能建議。你可以先在首頁聊天並確認保存相關經驗。',
                        'No skill suggestions yet. Share an experience in Home chat and confirm it as a memory first.'))
              else
                ...controller.skillSuggestions.map((skill) => Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(skill.suggestion,
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              if (skill.reason.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(skill.reason)
                              ],
                              const SizedBox(height: 10),
                              if (skill.status == 'suggested')
                                Wrap(spacing: 8, children: [
                                  FilledButton.tonal(
                                      onPressed: () =>
                                          _decide(skill, 'confirm'),
                                      child:
                                          Text(tr(context, '確認', 'Confirm'))),
                                  OutlinedButton(
                                      onPressed: () => _decide(skill, 'edit'),
                                      child: Text(tr(context, '修改', 'Edit'))),
                                  TextButton(
                                      onPressed: () => _decide(skill, 'reject'),
                                      child: Text(tr(context, '拒絕', 'Reject'))),
                                ])
                              else
                                Text(skill.status == 'confirmed'
                                    ? tr(context, '已確認，可查看相關機會。',
                                        'Confirmed. Matching opportunities are shown below.')
                                    : tr(context, '已拒絕', 'Rejected')),
                            ])))),
              if (controller.opportunities.isNotEmpty) ...[
                const SizedBox(height: 8),
                SectionTitle(
                    title: tr(context, '相關機會', 'Related opportunities')),
                const SizedBox(height: 8),
                ...controller.opportunities.map((item) => CommunityListingCard(
                    title: item.title,
                    summary: item.summary,
                    organization: item.organization,
                    area: item.area,
                    sourceName: item.sourceName,
                    lastCheckedAt: item.lastCheckedAt,
                    sourceUrl: item.sourceUrl,
                    kind: item.kind,
                    eventStartAt: item.eventStartAt,
                    eventEndAt: item.eventEndAt,
                    dateText: item.dateText,
                    eligibility: item.eligibility,
                    registrationUrl: item.registrationUrl,
                    availabilityNote: item.availabilityNote)),
              ] else if (canPersonalize &&
                  controller.skillSuggestions
                      .any((item) => item.status == 'confirmed'))
                EmptyCard(
                    icon: Icons.search_off_rounded,
                    message: tr(context, '目前沒有找到相關機會。稍後可以重新搜尋。',
                        'No matching opportunities were found. You can search again later.')),
              const SizedBox(height: 22),
              SectionTitle(
                  title:
                      tr(context, '搜尋社區機會', 'Search community opportunities')),
              const SizedBox(height: 9),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: _topic,
                              decoration: InputDecoration(
                                  labelText: tr(context, '活動主題', 'Topic')),
                              items: [
                                DropdownMenuItem(
                                    value: '',
                                    child: Text(
                                        tr(context, '所有主題', 'All topics'))),
                                DropdownMenuItem(
                                    value: 'tailoring',
                                    child:
                                        Text(tr(context, '縫紉', 'Tailoring'))),
                                DropdownMenuItem(
                                    value: 'cooking',
                                    child: Text(tr(context, '烹飪', 'Cooking'))),
                                DropdownMenuItem(
                                    value: 'gardening',
                                    child:
                                        Text(tr(context, '園藝', 'Gardening'))),
                                DropdownMenuItem(
                                    value: 'teaching',
                                    child: Text(tr(context, '教學', 'Teaching'))),
                                DropdownMenuItem(
                                    value: 'knitting',
                                    child: Text(tr(context, '編織', 'Knitting'))),
                                DropdownMenuItem(
                                    value: 'woodworking',
                                    child:
                                        Text(tr(context, '木工', 'Woodworking'))),
                              ],
                              onChanged: (value) =>
                                  setState(() => _topic = value ?? ''),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _area,
                              textInputAction: TextInputAction.search,
                              maxLength: 50,
                              decoration: InputDecoration(
                                  labelText: tr(context, '香港地區（可留空）',
                                      'Hong Kong area (optional)'),
                                  hintText: tr(context, '例如：深水埗',
                                      'For example: Sham Shui Po')),
                              onSubmitted: (_) => controller.searchCommunity(
                                  topic: _topic, area: _area.text),
                            ),
                            const SizedBox(height: 10),
                            FilledButton.icon(
                                onPressed: controller.communitySearchLoading
                                    ? null
                                    : () => controller.searchCommunity(
                                        topic: _topic, area: _area.text),
                                icon: const Icon(Icons.search_rounded),
                                label: Text(tr(context, '搜尋官方及社區來源',
                                    'Search provider sources'))),
                            if (controller.communitySearchLoading) ...[
                              const SizedBox(height: 12),
                              const LinearProgressIndicator(),
                              const SizedBox(height: 6),
                              Text(tr(context, '正在搜尋公開來源…',
                                  'Searching public sources…')),
                            ],
                          ]))),
              if (controller.communitySearchMessage.isNotEmpty) ...[
                const SizedBox(height: 10),
                EmptyCard(
                    icon: controller.communitySearchState == 'unavailable'
                        ? Icons.cloud_off_rounded
                        : Icons.info_outline_rounded,
                    message: controller.communitySearchMessage),
              ],
              if (controller.communityCheckedAt != null ||
                  controller.communitySearchState != 'unavailable') ...[
                const SizedBox(height: 8),
                Text(
                    tr(
                        context,
                        '搜尋狀態：${controller.communitySearchState == 'live' ? '即時搜尋' : controller.communitySearchState == 'cache' ? '快取結果' : '來源無法連線'}${controller.communityCheckedAt == null ? '' : ' · ${_dateLabel(context, controller.communityCheckedAt)}'}',
                        'Search: ${controller.communitySearchState == 'live' ? 'live' : controller.communitySearchState == 'cache' ? 'cached' : 'sources unavailable'}${controller.communityCheckedAt == null ? '' : ' · ${_dateLabel(context, controller.communityCheckedAt)}'}'),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              if (controller.communitySources.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                    tr(
                        context,
                        '已查來源：${controller.communitySources.map((s) => '${s.name}（${s.state == 'live' ? '即時' : s.state == 'cache' ? '快取' : '無法連線'}）').join('、')}',
                        'Sources checked: ${controller.communitySources.map((s) => '${s.name} (${s.state})').join(', ')}'),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 9),
              if (controller.communityActivities.isEmpty &&
                  !controller.communitySearchLoading)
                EmptyCard(
                    icon: Icons.event_busy_rounded,
                    message: controller.communitySearchState == 'unavailable'
                        ? tr(context, '目前無法連接搜尋來源。請檢查網絡後重試。',
                            'Search sources are unavailable. Check your connection and retry.')
                        : tr(context, '這次搜尋沒有找到符合條件的活動。可更改主題或地區再搜尋。',
                            'No matching activities were found. Try another topic or area.'))
              else
                ...controller.communityActivities.map((item) =>
                    CommunityListingCard(
                        title: item.title,
                        summary: item.summary,
                        organization: item.organization,
                        area: item.area,
                        sourceName: item.sourceName,
                        lastCheckedAt: item.lastCheckedAt,
                        sourceUrl: item.sourceUrl,
                        kind: item.kind,
                        eventStartAt: item.eventStartAt,
                        eventEndAt: item.eventEndAt,
                        dateText: item.dateText,
                        eligibility: item.eligibility,
                        registrationUrl: item.registrationUrl,
                        availabilityNote: item.availabilityNote)),
              if (controller.errorMessage != null) ...[
                const SizedBox(height: 12),
                ErrorBanner(
                    message: controller.errorMessage!,
                    onRetry: () => controller.refreshCommunity())
              ],
            ]));
  }
}

class CommunityListingCard extends StatelessWidget {
  const CommunityListingCard(
      {required this.title,
      required this.summary,
      required this.organization,
      required this.area,
      required this.sourceName,
      required this.lastCheckedAt,
      required this.sourceUrl,
      this.eventStartAt,
      this.eventEndAt,
      this.dateText = '',
      this.eligibility = '',
      this.registrationUrl,
      this.availabilityNote = '',
      this.kind = '',
      super.key});
  final String title, summary, organization, area, sourceName;
  final DateTime? lastCheckedAt;
  final String? sourceUrl;
  final DateTime? eventStartAt, eventEndAt;
  final String dateText;
  final String eligibility;
  final String? registrationUrl;
  final String availabilityNote;
  final String kind;
  @override
  Widget build(BuildContext context) => Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (kind.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(kind.replaceAll('_', ' '),
                  style: Theme.of(context).textTheme.labelMedium),
            ],
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(summary)
            ],
            if (organization.isNotEmpty || area.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text([organization, area].where((v) => v.isNotEmpty).join(' · '))
            ],
            if (eventStartAt != null || dateText.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(eventStartAt != null
                  ? tr(
                      context,
                      '時間：${_dateLabel(context, eventStartAt)}${eventEndAt == null ? '' : ' 至 ${_dateLabel(context, eventEndAt)}'}',
                      'When: ${_dateLabel(context, eventStartAt)}${eventEndAt == null ? '' : ' – ${_dateLabel(context, eventEndAt)}'}')
                  : tr(context, '來源日期：$dateText', 'Source date: $dateText'))
            ],
            if (eligibility.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                  tr(context, '參加資格：$eligibility', 'Eligibility: $eligibility'))
            ],
            const SizedBox(height: 6),
            Text(
                availabilityNote.isNotEmpty
                    ? availabilityNote
                    : tr(context, '資料來自公開網頁，名額和最新安排請向主辦機構確認。',
                        'Details come from a public page. Confirm places and current arrangements with the organizer.'),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
                tr(
                    context,
                    '資料來源：$sourceName${lastCheckedAt == null ? '' : ' · 擷取日期 ${_dateLabel(context, lastCheckedAt)}'}',
                    'Source: $sourceName${lastCheckedAt == null ? '' : ' · Retrieved ${_dateLabel(context, lastCheckedAt)}'}'),
                style: Theme.of(context).textTheme.bodySmall),
            if (sourceUrl != null)
              TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(sourceUrl!),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(tr(context, '查看來源', 'View source'))),
            if (registrationUrl != null)
              FilledButton.tonalIcon(
                  onPressed: () => launchUrl(Uri.parse(registrationUrl!),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.event_available_rounded),
                  label: Text(tr(context, '查看報名方式', 'Registration details'))),
          ])));
}

class HelpScreen extends ConsumerStatefulWidget {
  const HelpScreen({super.key});
  @override
  ConsumerState<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends ConsumerState<HelpScreen> {
  final _query = TextEditingController();
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    return ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const ScamSafetyScreen())),
              icon: const Icon(Icons.shield_outlined),
              label: Text(tr(context, '防騙指引', 'Scam safety'))),
          Text(tr(context, '幫助', 'Help'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
              tr(context, '安心伴會用簡單語言解釋生活資訊，並在有核實來源時提供官方下一步。它不會代替醫護、政府服務或緊急支援。',
                  'Anxin explains practical information in plain language and points to official next steps when verified sources are available. It does not replace health professionals, government services or emergency support.'),
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 16),
          FeatureCard(
              icon: Icons.forum_outlined,
              title: tr(context, '詢問生活問題', 'Ask a practical question'),
              description: tr(context, '從首頁開始對話；也可以不登入以訪客身份使用。',
                  'Start a chat from Home, or use guest access without signing in.'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const ElderChatScreen()))),
          const SizedBox(height: 10),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                            tr(context, '搜尋生活資訊',
                                'Search practical information'),
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 10),
                        TextField(
                            controller: _query,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) =>
                                controller.searchHelp(_query.text),
                            decoration: InputDecoration(
                                labelText: tr(context, '你想了解甚麼？',
                                    'What would you like to know?'),
                                suffixIcon: IconButton(
                                    onPressed: () =>
                                        controller.searchHelp(_query.text),
                                    icon: const Icon(Icons.search_rounded)))),
                      ]))),
          if (controller.guestHelpResources.isNotEmpty) ...[
            const SizedBox(height: 14),
            ...controller.guestHelpResources.map((item) => Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.title,
                              style: Theme.of(context).textTheme.titleMedium),
                          if (item.excerpt.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(item.excerpt)
                          ],
                          if (item.verifiedAt != null) ...[
                            const SizedBox(height: 8),
                            Text(
                                tr(
                                    context,
                                    '核實日期：${_dateLabel(context, item.verifiedAt)}',
                                    'Verified: ${_dateLabel(context, item.verifiedAt)}'),
                                style: Theme.of(context).textTheme.bodySmall)
                          ],
                          if (item.nextSteps.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(tr(context, '下一步', 'Next steps'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            ...item.nextSteps.map((step) => Text('• $step'))
                          ],
                          if (item.url != null)
                            TextButton.icon(
                                onPressed: () => launchUrl(Uri.parse(item.url!),
                                    mode: LaunchMode.externalApplication),
                                icon: const Icon(Icons.open_in_new_rounded),
                                label: Text(tr(context, '開啟官方來源',
                                    'Open official source'))),
                        ])))),
          ] else if (_query.text.trim().isNotEmpty &&
              controller.errorMessage == null)
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: EmptyCard(
                    icon: Icons.search_off_rounded,
                    message: tr(context, '暫時找不到合適的已核實資料。請稍後再試，或直接查詢相關官方服務。',
                        'No verified information matched. Try later or contact the relevant official service.'))),
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(message: controller.errorMessage!)
          ],
        ]);
  }
}

class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  int _index = 0;

  void _goTo(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final elder = controller.isElder;
    final destinations = elder
        ? [
            NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: tr(context, '首頁', 'Home')),
            NavigationDestination(
                icon: Icon(Icons.people_outline_rounded),
                selectedIcon: Icon(Icons.people_rounded),
                label: tr(context, '家庭', 'Family')),
            NavigationDestination(
                icon: Icon(Icons.groups_outlined),
                selectedIcon: Icon(Icons.groups_rounded),
                label: tr(context, '社區', 'Community')),
            NavigationDestination(
                icon: Icon(Icons.help_outline_rounded),
                selectedIcon: Icon(Icons.help_rounded),
                label: tr(context, '幫助', 'Help')),
            NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: tr(context, '設定', 'Settings')),
          ]
        : [
            NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard_rounded),
                label: tr(context, '概覽', 'Overview')),
            NavigationDestination(
                icon: Icon(Icons.checklist_outlined),
                selectedIcon: Icon(Icons.checklist_rounded),
                label: tr(context, '共享任務', 'Shared tasks')),
            NavigationDestination(
                icon: Icon(Icons.people_outline_rounded),
                selectedIcon: Icon(Icons.people_rounded),
                label: tr(context, '家庭連結', 'Family links')),
          ];
    final body = elder
        ? [
            ElderHome(
                onChat: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const ElderChatScreen()))),
            const FamilyScreen(),
            const CommunityScreen(),
            const HelpScreen(),
            const SettingsScreen(),
          ][_index]
        : [
            const CaregiverHome(),
            const TasksScreen(),
            const FamilyScreen(),
          ][_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(elder
            ? tr(context, '安心伴 · 長者', 'Anxin · Senior')
            : tr(context, '安心伴 · 照顧者', 'Anxin · Caregiver')),
        actions: [
          if (controller.session?.demoMode == true)
            const Padding(
                padding: EdgeInsets.only(right: 8),
                child: DemoModeLabel(compact: true)),
          IconButton(
            tooltip: tr(context, '收件匣及關懷設定', 'Inbox and care settings'),
            icon: const Icon(Icons.inbox_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => CareControlsScreen(controller: controller))),
          ),
          IconButton(
            tooltip: tr(context, '帳戶設定及登出', 'Account and settings'),
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              useSafeArea: true,
              builder: (_) => AccountSheet(user: controller.user!),
            ),
          ),
        ],
      ),
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: destinations,
        onDestinationSelected: _goTo,
      ),
    );
  }
}

class AccountSheet extends ConsumerWidget {
  const AccountSheet({required this.user, super.key});

  final AppUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                user.displayName.isEmpty
                    ? _roleLabel(context, user.role)
                    : user.displayName,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            Text('${user.email} · ${_roleLabel(context, user.role)}',
                style: Theme.of(context).textTheme.bodyMedium),
            if (controller.session?.demoMode == true) ...[
              const SizedBox(height: 16),
              Text(tr(context, '目前使用示範回覆，尚未連接 AI 模型。你仍可試用記憶、資源和家庭功能。',
                  'Demo replies are enabled; no AI model is connected. You can still try memories, resources and family features.')),
            ],
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => CareControlsScreen(
                          controller: ref.read(appControllerProvider)))),
              icon: const Icon(Icons.health_and_safety_outlined),
              label: Text(tr(context, '關懷及安全', 'Care and safety')),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => ReminderSettingsScreen(
                          controller: ref.read(appControllerProvider),
                          scheduler: ref.read(reminderSchedulerProvider)))),
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(tr(context, '本機提醒', 'Device reminders')),
            ),
            OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen())),
                icon: const Icon(Icons.settings_outlined),
                label: Text(tr(context, '設定', 'Settings'))),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: controller.loading
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await controller.logout();
                    },
              icon: const Icon(Icons.logout_rounded),
              label: Text(tr(context, '登出這個帳戶', 'Sign out')),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
            ),
          ],
        ),
      ),
    );
  }
}

class ElderHome extends ConsumerWidget {
  const ElderHome({required this.onChat, super.key});

  final VoidCallback onChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final user = controller.user;
    return RefreshIndicator(
      onRefresh: () => controller.refreshHome(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text(
              "${tr(context, '你好，', 'Hello, ')}${user?.displayName.isNotEmpty == true ? user!.displayName : tr(context, '朋友', 'friend')}",
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
              tr(context, '今天想找人傾吓偈，或者一起整理一件小事嗎？',
                  'Would you like a chat, or help with something today?'),
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 20),
          Card(
            color: const Color(0xFFDDEDEA),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.wb_sunny_rounded,
                      color: Color(0xFF116466), size: 34),
                  const SizedBox(height: 12),
                  Text(tr(context, '今日陪伴', 'Here for you today'),
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(tr(context, '你可以和安心伴分享心情，也可以說說今天想完成的事情。',
                      'Share how you feel, or tell Anxin Companion what you would like to do today.')),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                      onPressed: onChat,
                      icon: const Icon(Icons.chat_rounded),
                      label: Text(tr(context, '開始聊天', 'Start chatting')),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          SectionTitle(
              title: tr(context, '今日任務', 'Tasks today'),
              action: controller.tasks.isEmpty
                  ? null
                  : tr(context, '${controller.tasks.length} 項',
                      '${controller.tasks.length} items')),
          const SizedBox(height: 10),
          if (controller.tasks.isEmpty)
            EmptyCard(
                icon: Icons.check_circle_outline_rounded,
                message: tr(context, '暫時沒有共享任務。聊天時有需要，安心伴會先讓你確認。',
                    'No shared tasks yet. Anxin will ask for your confirmation before creating one.'))
          else
            ...controller.tasks.take(3).map((task) => TaskTile(task: task)),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.checklist_rounded,
            title: tr(context, '查看所有任務', 'View all tasks'),
            description: tr(context, '查看並更新你已確認的照顧事項。',
                'Review and update care tasks you confirmed.'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TasksScreen())),
          ),
          const SizedBox(height: 22),
          SectionTitle(title: tr(context, '我的資料', 'My space')),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.bookmark_outline_rounded,
            title: tr(context, '我的記憶', 'My memories'),
            description: tr(context, '查看和管理你明確保存的生活記憶。',
                'Review and manage memories you choose to save.'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MemoriesScreen()),
            ),
          ),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.auto_stories_outlined,
            title: tr(context, '故事卡', 'Story cards'),
            description: tr(context, '把幾段記憶整理成自己的故事。',
                'Turn your memories into your own stories.'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const StoriesScreen()),
            ),
          ),
          const SizedBox(height: 10),
          if (controller.api is AnswerCardApi) ...[
            const _AnswerCardsFeature(),
            const SizedBox(height: 10),
          ],
          FeatureCard(
            icon: Icons.local_library_outlined,
            title: tr(context, '生活資源', 'Resources'),
            description: tr(context, '查找有來源和日期的社區資料。',
                'Find community information with sources and dates.'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ResourcesScreen()),
            ),
          ),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.forum_outlined,
            title: tr(context, '家庭訊息', 'Family messages'),
            description: tr(context, '只與你主動授權的家庭成員聯絡。',
                'Connect with family members you have authorized.'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => const FamilyMessagesScreen()),
            ),
          ),
          if (controller.api is HumanGroupApi) ...[
            const SizedBox(height: 10),
            FeatureCard(
              icon: Icons.groups_outlined,
              title: tr(context, '人與人群聊', 'Human group chats'),
              description: tr(context, '查看邀請及與社區成員聊天；AI 不參與。',
                  'Accept invitations and chat with community members. No AI participates.'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text(tr(context, '群聊', 'Groups'))),
                  body: GroupLobbyScreen(
                    api: controller.api as HumanGroupApi,
                    accountId: controller.user!.id,
                  ),
                ),
              )),
            ),
          ],
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 18),
            ErrorBanner(
                message: controller.errorMessage!,
                onRetry: () => controller.refreshHome()),
          ],
        ],
      ),
    );
  }
}

class CaregiverHome extends ConsumerWidget {
  const CaregiverHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final active = controller.tasks
        .where((task) =>
            task.status != TaskStatus.completed &&
            task.status != TaskStatus.dismissed)
        .length;
    return TaskAccessRefresh(
      controller: controller,
      child: RefreshIndicator(
        onRefresh: () => controller.refreshHome(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Text(tr(context, '照顧概覽', 'Care overview'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 7),
            Text(tr(context, '你可更新自己的任務，並唯讀查看長者逐項確認分享的任務。私人對話不會分享。',
                'Manage your own tasks and read tasks the senior explicitly shares. Private conversations stay private.')),
            const SizedBox(height: 20),
            Card(
              color: const Color(0xFFF5E5D6),
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Row(
                  children: [
                    const Icon(Icons.volunteer_activism_rounded,
                        color: Color(0xFF8B4E2D), size: 38),
                    const SizedBox(width: 16),
                    Expanded(
                        child: Text(
                            tr(context, '$active 項未完成任務',
                                '$active unfinished tasks'),
                            style: Theme.of(context).textTheme.titleLarge)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SectionTitle(
                title: tr(context, '最近任務', 'Recent tasks'),
                action: controller.tasks.isEmpty
                    ? null
                    : tr(context, '${controller.tasks.length} 項',
                        '${controller.tasks.length} items')),
            const SizedBox(height: 10),
            if (controller.tasks.isEmpty)
              EmptyCard(
                  icon: Icons.inbox_outlined,
                  message: tr(context, '長者確認共享事項後，任務會在這裡出現。',
                      'Tasks appear here after the senior confirms sharing them.'))
            else
              ...controller.tasks
                  .take(5)
                  .map((task) => TaskTile(task: task, interactive: true)),
            const SizedBox(height: 22),
            SectionTitle(title: tr(context, '需要時可以使用', 'More support')),
            const SizedBox(height: 10),
            if (controller.api is AnswerCardApi) ...[
              const _AnswerCardsFeature(),
              const SizedBox(height: 10),
            ],
            FeatureCard(
              icon: Icons.local_library_outlined,
              title: tr(context, '生活資源', 'Resources'),
              description: tr(context, '查看有來源、有日期的照顧資料。',
                  'Find care information with sources and dates.'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const ResourcesScreen()),
              ),
            ),
            const SizedBox(height: 10),
            FeatureCard(
              icon: Icons.forum_outlined,
              title: tr(context, '家庭訊息', 'Family messages'),
              description: tr(context, '只與有明確訊息授權的家庭成員聯絡。',
                  'Message family members who have granted permission.'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const FamilyMessagesScreen()),
              ),
            ),
            if (controller.api is HumanGroupApi) ...[
              const SizedBox(height: 10),
              FeatureCard(
                icon: Icons.groups_outlined,
                title: tr(context, '人與人群聊', 'Human group chats'),
                description: tr(context, '查看社區群聊邀請；AI 不參與。',
                    'See community group invitations. No AI participates.'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(tr(context, '群聊', 'Groups'))),
                    body: GroupLobbyScreen(
                      api: controller.api as HumanGroupApi,
                      accountId: controller.user!.id,
                    ),
                  ),
                )),
              ),
            ],
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 18),
              ErrorBanner(
                  message: controller.errorMessage!,
                  onRetry: () => controller.refreshHome()),
            ],
          ],
        ),
      ),
    );
  }
}

class ElderChatScreen extends ConsumerWidget {
  const ElderChatScreen({super.key});

  Future<void> _newConversation(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(appControllerProvider);
    final conversation = await controller.startConversation();
    if (conversation != null && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChatDetailScreen(conversation: conversation)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '聊天', 'Chat'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Row(
              children: [
                Expanded(
                    child: Text(tr(context, '我的對話', 'My chats'),
                        style: Theme.of(context).textTheme.headlineSmall)),
                if (controller.api is HumanGroupApi) ...[
                  IconButton(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar:
                            AppBar(title: Text(tr(context, '群聊', 'Groups'))),
                        body: GroupLobbyScreen(
                          api: controller.api as HumanGroupApi,
                          accountId: controller.user!.id,
                        ),
                      ),
                    )),
                    icon: const Icon(Icons.groups_outlined),
                    tooltip: tr(context, '人與人群聊', 'Human group chats'),
                  ),
                  const SizedBox(width: 8),
                ],
                FilledButton.icon(
                    onPressed: () => _newConversation(context, ref),
                    icon: const Icon(Icons.add_comment_rounded),
                    label: Text(tr(context, '新對話', 'New chat'))),
              ],
            ),
          ),
          Expanded(
            child: controller.conversations.isEmpty
                ? ListView(padding: const EdgeInsets.all(20), children: [
                    EmptyCard(
                        icon: Icons.forum_outlined,
                        message: tr(context, '還未有對話。按「新對話」就可以開始。',
                            'No conversations yet. Select New chat to begin.'))
                  ])
                : RefreshIndicator(
                    onRefresh: () => controller.refreshHome(),
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                      itemCount: controller.conversations.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final conversation = controller.conversations[index];
                        return Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 8),
                            leading: const CircleAvatar(
                                child: Icon(Icons.chat_bubble_outline_rounded)),
                            title: Text(conversation.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 18)),
                            subtitle: Text(conversation.preview ??
                                tr(context, '按一下繼續這段對話。',
                                    'Tap to continue this conversation.')),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) => ChatDetailScreen(
                                        conversation: conversation))),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class ChatDetailScreen extends ConsumerStatefulWidget {
  const ChatDetailScreen({required this.conversation, super.key});

  final Conversation conversation;

  @override
  ConsumerState<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends ConsumerState<ChatDetailScreen> {
  final _draftController = TextEditingController();
  final _scrollController = ScrollController();
  bool _loadedDraft = false;
  late final VoiceInputController _voiceInput;
  bool _voiceDisclosureAccepted = false;
  bool _showSafetySupport = false;
  final Set<String> _dismissedMemorySuggestions = <String>{};
  final Map<String, bool> _communityPromptAnswers = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _voiceInput = ref.read(voiceInputProvider);
    final controller = ref.read(appControllerProvider);
    Future<void>(() async {
      await controller.loadMessages(widget.conversation.id);
      final draft = await controller.readDraft(widget.conversation.id);
      if (mounted && !_loadedDraft && draft != null) {
        _draftController.text = draft;
        _loadedDraft = true;
      }
    });
  }

  @override
  void dispose() {
    _voiceInput.detach();
    _draftController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _draftController.text;
    if (text.trim().isEmpty) return;
    if (detectsUrgentRisk(text)) setState(() => _showSafetySupport = true);
    final sent = await ref
        .read(appControllerProvider)
        .sendMessage(conversationId: widget.conversation.id, content: text);
    if (sent && mounted) {
      _draftController.clear();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
      }
    }
  }

  Future<void> _toggleVoiceInput() async {
    if (!_voiceDisclosureAccepted) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(context, '廣東話語音輸入', 'Cantonese voice input')),
          content: Text(tr(
            context,
            '語音辨識由你的裝置或瀏覽器提供。咪高峰音訊會交由該語音服務處理，其資料政策由服務供應者決定；安心伴只會收到辨識文字。傳送前你可以檢查和修改文字。',
            "Speech recognition is provided by your device or browser. Microphone audio is processed by that speech service under its provider's data policy; Anxin receives only the recognized text. Review and edit the transcript before sending.",
          )),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(context, '取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(context, '繼續', 'Continue')),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      _voiceDisclosureAccepted = true;
    }
    final initialDraft = _draftController.text.trim();
    await _voiceInput.toggle(
      onTranscript: (transcript) {
        final updated =
            initialDraft.isEmpty ? transcript : '$initialDraft $transcript';
        _draftController.value = TextEditingValue(
          text: updated,
          selection: TextSelection.collapsed(offset: updated.length),
        );
        ref
            .read(appControllerProvider)
            .saveDraft(widget.conversation.id, updated);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final voice = ref.watch(voiceInputProvider);
    final messages = controller.messagesFor(widget.conversation.id);
    final actions = controller.pendingActions
        .where((action) =>
            action.conversationId == null ||
            action.conversationId == widget.conversation.id)
        .toList();
    final busy =
        controller.sendingConversationIds.contains(widget.conversation.id);
    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.title)),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.session?.demoMode == true)
              const Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: DemoModeLabel()),
            if (controller.errorMessage != null)
              Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: ErrorBanner(message: controller.errorMessage!)),
            if (voice.notice != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(voice.notice!, key: const Key('voice-notice'))),
            Expanded(
              child: messages.isEmpty && actions.isEmpty && !_showSafetySupport
                  ? ListView(padding: const EdgeInsets.all(24), children: [
                      EmptyCard(
                          icon: Icons.chat_rounded,
                          message: tr(context, '你可以慢慢說。我會先聽清楚，再問你要不要一起安排下一步。',
                              'Take your time. I will listen first, then ask whether you would like help with a next step.'))
                    ])
                  : ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      children: [
                        ...messages.map((message) => MessageBubble(
                              message: message,
                              suggestionDismissed: _dismissedMemorySuggestions
                                  .contains(message.id),
                              onSuggestionDismissed: () => setState(() =>
                                  _dismissedMemorySuggestions.add(message.id)),
                              communityPromptAnswer:
                                  _communityPromptAnswers[message.id],
                              onCommunityPromptAnswered: (interested) =>
                                  setState(() =>
                                      _communityPromptAnswers[message.id] =
                                          interested),
                            )),
                        ...actions.map((action) => ActionCard(action: action)),
                        if (_showSafetySupport)
                          SafetySupportCard(
                              links: controller.familyMessageLinks),
                      ],
                    ),
            ),
            Material(
              color: Colors.white,
              elevation: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _draftController,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.newline,
                        onChanged: (value) => ref
                            .read(appControllerProvider)
                            .saveDraft(widget.conversation.id, value),
                        decoration: InputDecoration(
                            hintText: tr(context, '寫下你想分享的事…',
                                'What would you like to share?'),
                            prefixIcon: Icon(Icons.edit_note_rounded)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filledTonal(
                      key: const Key('cantonese-voice-input'),
                      tooltip: voice.isListening
                          ? tr(context, '停止廣東話語音輸入',
                              'Stop Cantonese voice input')
                          : tr(context, '廣東話語音輸入', 'Cantonese voice input'),
                      onPressed: busy ? null : _toggleVoiceInput,
                      icon: Icon(voice.isListening
                          ? Icons.stop_circle_rounded
                          : Icons.mic_none_rounded),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(54, 54),
                        backgroundColor:
                            voice.isListening ? const Color(0xFFF4D8D5) : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filled(
                      tooltip: tr(context, '傳送訊息', 'Send message'),
                      onPressed: busy ? null : _send,
                      icon: busy
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded),
                      style:
                          IconButton.styleFrom(minimumSize: const Size(54, 54)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends ConsumerWidget {
  const MessageBubble(
      {required this.message,
      this.suggestionDismissed = false,
      this.onSuggestionDismissed,
      this.communityPromptAnswer,
      this.onCommunityPromptAnswered,
      super.key});

  final ChatMessage message;
  final bool suggestionDismissed;
  final VoidCallback? onSuggestionDismissed;
  final bool? communityPromptAnswer;
  final ValueChanged<bool>? onCommunityPromptAnswered;

  Future<void> _saveSuggestion(BuildContext context, WidgetRef ref) async {
    final suggestion = message.memorySuggestion;
    if (suggestion == null) return;
    final editor = TextEditingController(text: suggestion.content);
    final content = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, '保存這項記憶？', 'Save this memory?')),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(context, '這份手動草稿在你按保存前不會寫入記憶。你可以先修改內容。',
                  'This manual draft is not saved to Memory until you choose Save. You can edit it first.')),
              const SizedBox(height: 12),
              TextField(
                  controller: editor,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                      labelText: tr(context, '記憶內容', 'Memory text'))),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(context, '取消', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, editor.text),
              child: Text(tr(context, '確認保存', 'Save'))),
        ],
      ),
    );
    editor.dispose();
    if (content == null || content.trim().isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final successMessage = tr(context, '記憶已保存。你可以在首頁的「我的記憶」管理。',
        'Memory saved. Manage it from My memories on Home.');
    if (await ref
        .read(appControllerProvider)
        .saveSuggestedMemory(message, editedContent: content)) {
      onSuggestionDismissed?.call();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final mine = message.isFromUser;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF116466) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(mine ? 20 : 5),
            bottomRight: Radius.circular(mine ? 5 : 20),
          ),
          border: mine ? null : Border.all(color: Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message.body,
                style: TextStyle(
                    color: mine ? Colors.white : Colors.black87,
                    fontSize: 18,
                    height: 1.45)),
            if (!mine && !message.pending && message.body.trim().isNotEmpty &&
                controller.api is AnswerCardApi &&
                (controller.session != null || controller.guestSession != null) &&
                message.metadata['mode'] != 'error' &&
                !const ['pending', 'processing', 'error', 'failed'].contains(message.metadata['status'])) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                  key: ValueKey('answer-card-action-${message.id}'),
                  onPressed: () => _openAnswerCardDraft(context, ref, message),
                  icon: const Icon(Icons.description_outlined),
                  label: Text(tr(context, '整理為答案卡', 'Make answer card'))),
            ],
            if (!mine && message.retrievalMode != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFDDEDEA),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  tr(
                      context,
                      '取用資料：${_retrievalLabel(context, message.retrievalMode)}',
                      'Sources: ${_retrievalLabel(context, message.retrievalMode)}'),
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF116466),
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
            if (!mine &&
                controller.isElder &&
                controller.memoryConsentEnabled &&
                message.autoSavedMemory != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFFE9F3EF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.bookmark_added_outlined,
                        color: Color(0xFF116466), size: 19),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(tr(
                        context,
                        '記憶已開啟：我自動保存了這個普通偏好。可在「我的記憶」查看、修改、暫停或刪除。',
                        'Memory is on: I saved this ordinary preference automatically. View, edit, pause or delete it in My memories.',
                      )),
                    ),
                  ],
                ),
              ),
            ],
            if (!mine &&
                controller.isElder &&
                controller.memoryConsentEnabled &&
                message.communityMemoryPrompt != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1EDF8),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, '根據已保存的記憶', 'Based on a saved memory'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 5),
                    Text(message.communityMemoryPrompt!.memoryContent),
                    const SizedBox(height: 7),
                    Text(tr(
                      context,
                      message.communityMemoryPrompt!.promptZh,
                      message.communityMemoryPrompt!.promptEn,
                    )),
                    if (communityPromptAnswer == null) ...[
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        FilledButton.tonal(
                          onPressed: () =>
                              onCommunityPromptAnswered?.call(true),
                          child: Text(tr(context, '有興趣', 'Yes, interested')),
                        ),
                        TextButton(
                          onPressed: () =>
                              onCommunityPromptAnswered?.call(false),
                          child: Text(tr(context, '暫時不用', 'Not now')),
                        ),
                      ]),
                    ] else ...[
                      const SizedBox(height: 8),
                      Text(communityPromptAnswer!
                          ? tr(
                              context,
                              '知道了。目前尚未接入核實的活動搜尋來源，所以這次沒有搜尋或顯示活動。',
                              'Understood. Verified activity search is not connected yet, so nothing was searched or shown.',
                            )
                          : tr(context, '好，這次先略過。',
                              'Okay, we can leave it for now.')),
                    ],
                  ],
                ),
              ),
            ],
            if (!mine && message.memorySources.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(tr(context, '相關記憶', 'Related memories'),
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              ...message.memorySources.map(
                (source) => Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5EDE3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.format_quote_rounded,
                            size: 18, color: Color(0xFF8B4E2D)),
                        const SizedBox(width: 6),
                        Expanded(
                            child: Text(source.content,
                                style: const TextStyle(
                                    fontSize: 14, height: 1.35))),
                        const SizedBox(width: 4),
                        Text(
                            source.captureMethod == 'agent_auto'
                                ? tr(context, '自動保存', 'Auto-saved')
                                : tr(context, '你保存的來源', 'Saved by you'),
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF116466))),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            if (!mine && message.communitySources.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                  tr(
                      context,
                      '社區搜尋來源 · ${message.communitySearchState ?? '狀態不詳'}',
                      'Community search sources · ${message.communitySearchState ?? 'status unknown'}'),
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ...message.communitySources.map((source) => Row(
                    children: [
                      Expanded(
                          child: TextButton.icon(
                              onPressed: source.url.startsWith('https://') ||
                                      source.url.startsWith('http://')
                                  ? () => launchUrl(Uri.parse(source.url),
                                      mode: LaunchMode.externalApplication)
                                  : null,
                              icon: const Icon(Icons.open_in_new_rounded,
                                  size: 16),
                              label: Text('${source.name} · ${source.state}'))),
                      if (source.checkedAt != null)
                        Text(_dateLabel(context, source.checkedAt),
                            style: Theme.of(context).textTheme.labelSmall),
                    ],
                  )),
              Text(
                  tr(context, '公開網頁內容可能變更，參加前請向主辦機構確認。',
                      'Public pages can change. Confirm details with the organizer before attending.'),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if (!mine &&
                controller.isElder &&
                message.memorySuggestion != null &&
                !suggestionDismissed &&
                !controller.savedMemorySuggestionIds.contains(message.id) &&
                controller.memoryConsentEnabled) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                    color: const Color(0xFFFFF3D9),
                    borderRadius: BorderRadius.circular(14)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          tr(context, '記憶建議 · 尚未保存',
                              'Memory suggestion · not saved'),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Text(message.memorySuggestion!.content),
                      if (message.memorySuggestion!.sensitivity ==
                              'sensitive' ||
                          message.memorySuggestion!.sensitivity ==
                              'uncertain') ...[
                        const SizedBox(height: 6),
                        Text(tr(
                          context,
                          '這項內容可能較敏感或不確定。只有在你逐項確認並按下「修改並保存」後，才會加入記憶。',
                          'This may be sensitive or uncertain. It will enter Memory only if you review this item and choose Edit and save.',
                        )),
                      ],
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        FilledButton.tonal(
                            onPressed: controller.savingMemorySuggestionIds
                                    .contains(message.id)
                                ? null
                                : () => _saveSuggestion(context, ref),
                            child: controller.savingMemorySuggestionIds
                                    .contains(message.id)
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : Text(tr(context, '修改並保存', 'Edit and save'))),
                        TextButton(
                            onPressed: onSuggestionDismissed,
                            child: Text(tr(context, '不要保存', 'Do not save'))),
                      ]),
                    ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ActionCard extends ConsumerWidget {
  const ActionCard({required this.action, super.key});

  final ActionProposal action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final busy = controller.updatingActionIds.contains(action.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: const Color(0xFFFFF0D7),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.pending_actions_rounded,
                  color: Color(0xFF8B4E2D)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(tr(context, '請你確認', 'Please confirm'),
                      style: Theme.of(context).textTheme.titleMedium))
            ]),
            const SizedBox(height: 10),
            Text(action.title, style: Theme.of(context).textTheme.titleMedium),
            if (action.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(action.description)
            ],
            if (action.recipientLabel != null) ...[
              const SizedBox(height: 6),
              Text(tr(context, '對象：${action.recipientLabel}',
                  'For: ${action.recipientLabel}'))
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                    child: FilledButton(
                        onPressed: busy
                            ? null
                            : () => ref
                                .read(appControllerProvider)
                                .confirmAction(action),
                        child: busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Text(tr(context, '確認建立', 'Confirm')))),
                const SizedBox(width: 10),
                Expanded(
                    child: OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => ref
                                .read(appControllerProvider)
                                .dismissAction(action),
                        child: Text(tr(context, '先略過', 'Skip for now')))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final elder = controller.isElder;
    return TaskAccessRefresh(
      controller: controller,
      child: RefreshIndicator(
        onRefresh: () => controller.refreshHome(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Text(
                elder
                    ? tr(context, '我的任務', 'My tasks')
                    : tr(context, '我的與共享任務', 'My and shared tasks'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 7),
            Text(
                elder
                    ? tr(context, '確認後建立的照顧事項會在這裡追蹤。',
                        'Track care tasks you have confirmed here.')
                    : tr(context, '你可更新自己的任務；長者分享的任務只供閱讀。',
                        'Manage your own tasks. Tasks the senior shares are read-only.'),
                style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 18),
            if (controller.tasks.isEmpty)
              EmptyCard(
                  icon: Icons.checklist_rounded,
                  message: tr(context, '目前沒有任務。', 'No tasks yet.'))
            else
              ...controller.tasks
                  .map((task) => TaskTile(task: task, interactive: true)),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 18),
              ErrorBanner(
                  message: controller.errorMessage!,
                  onRetry: () => controller.refreshHome())
            ],
          ],
        ),
      ),
    );
  }
}

class TaskTile extends ConsumerWidget {
  const TaskTile({required this.task, this.interactive = false, super.key});

  final CareTask task;
  final bool interactive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final updating = controller.updatingTaskIds.contains(task.id);
    final complete = task.status == TaskStatus.completed;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              backgroundColor:
                  complete ? const Color(0xFFDDEDEA) : const Color(0xFFFFE5C1),
              child: Icon(
                  complete ? Icons.check_rounded : Icons.schedule_rounded,
                  color: const Color(0xFF116466)),
            ),
            const SizedBox(width: 12),
            Expanded(
                child: Text(task.title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700))),
          ]),
          if (task.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(task.description,
                maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 8),
          Text(_taskStatusLabel(context, task.status)),
          if (task.isReadOnly)
            Text(tr(context, '家屬共享 · 只供閱讀', 'Shared with you · Read-only')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (interactive && !complete && controller.canUpdateTask(task))
              TextButton(
                onPressed: updating
                    ? null
                    : () =>
                        controller.updateTaskStatus(task, TaskStatus.completed),
                child: updating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(tr(context, '完成', 'Complete')),
              ),
            if (controller.api is TaskSharingApi)
              TextButton(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => TaskDetailsScreen(
                        controller: controller, taskId: task.id),
                  ));
                  if (context.mounted && controller.isCaregiver) {
                    await controller.refreshTasks();
                  }
                },
                child: Text(tr(context, '查看完整任務', 'View full task')),
              ),
            if (controller.canShareTask(task))
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => TaskSharingScreen(
                      controller: controller, taskId: task.id),
                )),
                icon: const Icon(Icons.share_outlined),
                label: Text(tr(context, '分享／管理分享', 'Share / Manage sharing')),
              ),
          ]),
        ]),
      ),
    );
  }
}

class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(appControllerProvider).supportsFamilyConnections
          ? const FamilyConnectionsScreen()
          : const LegacyFamilyInvitesScreen();
}

class LegacyFamilyInvitesScreen extends ConsumerStatefulWidget {
  const LegacyFamilyInvitesScreen({this.showLinks = true, super.key});
  final bool showLinks;

  @override
  ConsumerState<LegacyFamilyInvitesScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends ConsumerState<LegacyFamilyInvitesScreen> {
  final _emailController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _includeFamilyMessages = false;

  @override
  void dispose() {
    _emailController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    if (_emailController.text.trim().isEmpty) return;
    final ok = await ref.read(appControllerProvider).createInvitation(
          _emailController.text,
          includeFamilyMessages: _includeFamilyMessages,
        );
    if (ok && mounted) {
      _emailController.clear();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '邀請已由伺服器建立。請把一次性邀請碼交給照顧者。',
              'Invitation created. Give the one-time code to your caregiver.'))));
    }
  }

  Future<void> _accept(FamilyInvitation invitation) async {
    final ok = await ref
        .read(appControllerProvider)
        .acceptInvitation(invitation, token: _tokenController.text);
    if (ok && mounted) {
      _tokenController.clear();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(tr(context, '家庭連結已由伺服器確認。', 'Family link confirmed.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final elder = controller.isElder;
    return RefreshIndicator(
      onRefresh: () => controller.refreshHome(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text(
              elder
                  ? tr(context, '家庭連結', 'Family links')
                  : tr(context, '家庭連結', 'Family links'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          Text(
              elder
                  ? tr(context, '你決定誰可以看到共享照顧事項。私密聊天一直只屬於你。',
                      'You decide who can see shared care tasks. Private chats stay private.')
                  : tr(context, '接受長者邀請後，你只會看到已授權的共享照顧事項。',
                      'Accept a senior\'s invitation to see care tasks they authorize you to access.'),
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 20),
          if (elder) ...[
            Text(tr(context, '邀請照顧者', 'Invite a caregiver'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 9),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                          labelText: tr(context, '照顧者電郵', 'Caregiver email')))),
              const SizedBox(width: 10),
              IconButton.filled(
                  tooltip: tr(context, '發出邀請', 'Send invitation'),
                  onPressed: controller.loading ? null : _invite,
                  icon: const Icon(Icons.send_rounded),
                  style: IconButton.styleFrom(minimumSize: const Size(54, 54)))
            ]),
            const SizedBox(height: 8),
            Card(
              color: const Color(0xFFF5EDE3),
              child: CheckboxListTile(
                value: _includeFamilyMessages,
                onChanged: (value) =>
                    setState(() => _includeFamilyMessages = value ?? false),
                title: Text(tr(context, '允許家庭訊息', 'Allow family messages'),
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(tr(context, '只在你主動勾選後，對方才可以和你互傳家庭訊息。預設不開啟。',
                    'Select this to allow messages between you and this family member. It is off by default.')),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ),
            const SizedBox(height: 20),
            if (controller.invitations.isNotEmpty) ...[
              Text(tr(context, '已發出的邀請', 'Sent invitations'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 9),
              ...controller.invitations.map((inv) => InvitationTile(
                  invitation: inv,
                  onRevoke: () => controller.revokeInvitation(inv)))
            ],
          ] else ...[
            Text(tr(context, '接受邀請', 'Accept invitation'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 9),
            TextField(
                controller: _tokenController,
                decoration: InputDecoration(
                    labelText:
                        tr(context, '一次性邀請碼', 'One-time invitation code'),
                    prefixIcon: Icon(Icons.key_rounded))),
            const SizedBox(height: 12),
            if (controller.invitations.isEmpty)
              EmptyCard(
                  icon: Icons.mail_outline_rounded,
                  message: tr(context, '收到長者邀請後，把邀請碼貼在上面。',
                      'Paste the code above when you receive an invitation.'))
            else
              ...controller.invitations.map((inv) => InvitationTile(
                  invitation: inv, onAccept: () => _accept(inv))),
          ],
          const SizedBox(height: 22),
          if (widget.showLinks && controller.links.isNotEmpty) ...[
            Text(tr(context, '目前連結', 'Current links'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 9),
            ...controller.links.map((link) => InvitationTile(
                invitation: link,
                onRevoke: () => controller.revokeInvitation(link))),
          ],
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 18),
            ErrorBanner(
                message: controller.errorMessage!,
                onRetry: () => controller.refreshHome())
          ],
        ],
      ),
    );
  }
}

class InvitationTile extends StatelessWidget {
  const InvitationTile({required this.invitation, this.onAccept, this.onRevoke, super.key});
  final FamilyInvitation invitation;
  final VoidCallback? onAccept;
  final VoidCallback? onRevoke;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(invitation.name?.isNotEmpty == true ? invitation.name! : invitation.email,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text(invitation.email),
        Text('ID: ${invitation.id}'),
        if (invitation.elderId != null) Text('Elder ID: ${invitation.elderId}'),
        if (invitation.caregiverId != null) Text('Caregiver ID: ${invitation.caregiverId}'),
        Text(_invitationStatusLabel(context, invitation.status)),
        if (invitation.allowsFamilyMessages) Text(tr(context, '允許家庭訊息', 'Family messages allowed')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (onAccept != null && invitation.status == InvitationStatus.pending)
            TextButton(onPressed: onAccept, child: Text(tr(context, '接受', 'Accept'))),
          if (onRevoke != null && (invitation.status == InvitationStatus.pending || invitation.status == InvitationStatus.accepted))
            TextButton(onPressed: onRevoke, child: Text(tr(context, '撤回', 'Revoke'))),
        ]),
      ],
    )),
  );
}

class FeatureCard extends StatelessWidget {
  const FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: const Color(0xFFDDEDEA),
                child: Icon(icon, color: const Color(0xFF116466)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(description,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class MemoriesScreen extends ConsumerStatefulWidget {
  const MemoriesScreen({super.key});

  @override
  ConsumerState<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends ConsumerState<MemoriesScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _savedKey = GlobalKey();
  final _selectedRows = <String, MemoryRecord>{};
  bool _viewSavedOnly = false;

  Future<void> _refresh() async {
    final controller = ref.read(appControllerProvider);
    await controller.refreshMemoryControlState();
    await controller.refreshMemories(silent: true);
  }

  void _viewSaved() {
    setState(() => _viewSavedOnly = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _savedKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 250));
      }
    });
  }

  void _deleted() {
    if (mounted) setState(_selectedRows.clear);
  }

  void _select(MemoryRecord memory, bool value) {
    setState(() {
      if (value) { _selectedRows[memory.id] = memory; }
      else { _selectedRows.remove(memory.id); }
    });
  }

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_refresh);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _edit(MemoryRecord memory) async {
    final editor = TextEditingController(text: memory.content);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, '修改記憶', 'Edit memory')),
        content: TextField(
          controller: editor,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration:
              InputDecoration(labelText: tr(context, '記憶內容', 'Memory content')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, '返回', 'Back'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, editor.text),
              child: Text(tr(context, '保存修改', 'Save changes'))),
        ],
      ),
    );
    editor.dispose();
    if (!mounted || value == null || value.trim().isEmpty) return;
    final ok = await ref.read(appControllerProvider).editMemory(memory, value);
    if (mounted && ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '記憶已更新。相關故事卡會先撤回，避免保留舊內容。',
              'Memory updated. Related story cards are withdrawn to avoid retaining outdated content.'))));
    }
  }

  Future<void> _delete(MemoryRecord memory) async {
    final deleted = await reviewMemoryDeletion(context,
        ref.read(appControllerProvider), mode: 'selected', memoryIds: [memory.id]);
    if (deleted) _deleted();
  }

  Future<void> _suppress(MemoryRecord memory) async {
    if (memory.suppressed) {
      await ref.read(appControllerProvider).restoreMemory(memory);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, '暫停使用這項記憶？', 'Pause this memory?')),
        content: Text(tr(context, '安心伴不會再用它作為回答參考；你仍可在此恢復或刪除。',
            'Anxin will stop using this memory in replies. You can restore or delete it here.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, '返回', 'Back'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, '暫停使用', 'Pause'))),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await ref.read(appControllerProvider).suppressMemory(memory);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final results = controller.memorySearchResults;
    final memories = controller.memories;
    final currentRows = {for (final m in [...memories, ...results]) m.id: m};
    // Selection belongs to the exact rows the user reviewed. A consent or
    // remote revision change requires selecting again, not silent rebasing.
    if (_selectedRows.values.any((selected) {
      final current = currentRows[selected.id];
      return selected.revision != controller.memoryRevision ||
          current == null ||
          current.revision != selected.revision ||
          current.content != selected.content ||
          current.kind != selected.kind ||
          current.status != selected.status ||
          current.suppressed != selected.suppressed ||
          current.sourceMessageId != selected.sourceMessageId;
    })) {
      _selectedRows.clear();
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '我的記憶', 'My memories'))),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            MemoryControlsPanel(controller: controller,
              selectedIds: _selectedRows.keys.where((id) => memories.any((m) => m.id == id) || results.any((m) => m.id == id)).toList(),
              onView: _viewSaved, onDeleted: _deleted),
            const SizedBox(height: 18),
            if (!_viewSavedOnly) ...[
            Text(tr(context, '由你管理記憶', 'Your memory, under your control'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 7),
            Text(tr(
                context,
                 '記憶預設關閉。你開啟後，清楚的普通偏好可自動保存，無需逐項按保存。敏感、不確定及其他內容須你逐項確認。你可查看、修改、暫停或刪除記憶。關閉記憶會停止收集和使用。分享給家人仍須你明確確認。自動保存須有已設定的 AI 模型；示範模式不會自動保存。情緒不會自動保存。',
                'Memory is off by default. After you turn it on, clear, ordinary preferences may be saved automatically without saving each one. Sensitive, uncertain and other details need your confirmation for each item. You can view, edit, pause or delete memories. Turning Memory off stops collection and use. Sharing with family still needs your explicit confirmation. Automatic saving requires a configured AI model; demo mode does not auto-save. Emotions are never auto-saved.')),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onSubmitted: (_) =>
                        controller.searchMemories(_searchController.text),
                    decoration: InputDecoration(
                        labelText: tr(context, '搜尋我的記憶', 'Search my memories'),
                        prefixIcon: Icon(Icons.search_rounded)),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: tr(context, '搜尋記憶', 'Search memories'),
                  onPressed: () =>
                      controller.searchMemories(_searchController.text),
                  icon: const Icon(Icons.search_rounded),
                  style: IconButton.styleFrom(minimumSize: const Size(54, 54)),
                ),
              ],
            ),
            if (controller.memoryRetrievalMode != null &&
                results.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                  tr(
                      context,
                      '搜尋方式：${_retrievalLabel(context, controller.memoryRetrievalMode)}',
                      'Search: ${_retrievalLabel(context, controller.memoryRetrievalMode)}'),
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (results.isNotEmpty) ...[
              const SizedBox(height: 16),
              SectionTitle(title: tr(context, '搜尋結果', 'Search results')),
              const SizedBox(height: 9),
              ...results.map((memory) => MemoryCard(
                  memory: memory,
                  onEdit: _edit,
                  onDelete: _delete,
                  onSuppress: _suppress,
                  selected: _selectedRows.containsKey(memory.id),
                  onSelected: (value) => _select(memory, value))),
            ],
            ],
            const SizedBox(height: 18),
            SectionTitle(
                key: _savedKey,
                title: tr(context, '已保存及候選', 'Saved and candidates'),
                action: memories.isEmpty
                    ? null
                    : tr(context, '${memories.length} 項',
                        '${memories.length} items')),
            const SizedBox(height: 9),
            if (memories.isEmpty)
              EmptyCard(
                  icon: Icons.bookmark_border_rounded,
                  message: tr(
                      context,
                      '目前沒有記憶。開啟記憶且已設定的 AI 模型可用時，普通興趣可能自動保存；示範模式不會自動保存。其他記憶建議需逐項確認。',
                      'No memories yet. Ordinary interests may be saved automatically when Memory is on and a configured AI model is available; demo mode does not auto-save. Review each other memory suggestion before saving.'))
            else
              ...memories.map((memory) => MemoryCard(
                  memory: memory,
                  onEdit: _edit,
                  onDelete: _delete,
                  onSuppress: _suppress,
                  selected: _selectedRows.containsKey(memory.id),
                  onSelected: (value) => _select(memory, value))),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 14),
              ErrorBanner(
                  message: controller.errorMessage!,
                  onRetry: () => controller.refreshMemories()),
            ],
          ],
        ),
      ),
    );
  }
}

class MemoryCard extends ConsumerWidget {
  const MemoryCard(
      {required this.memory,
      required this.onEdit,
      required this.onDelete,
      required this.onSuppress,
      this.selected = false,
      this.onSelected,
      super.key});

  final MemoryRecord memory;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Future<void> Function(MemoryRecord) onEdit;
  final Future<void> Function(MemoryRecord) onDelete;
  final Future<void> Function(MemoryRecord) onSuppress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final busy = controller.updatingMemoryIds.contains(memory.id) ||
        controller.memoryDeletionBusy ||
        controller.pendingMemoryDeletion != null;
    final canDelete = controller.supportsMemoryControls && !busy;
    final status = memory.suppressed
        ? tr(context, '已暫停使用', 'Paused')
        : (memory.isCandidate
            ? tr(context, '候選，等待你確認', 'Candidate, awaiting confirmation')
            : memory.captureMethod == 'agent_auto'
                ? tr(context, '已自動保存（待覆核）',
                    'Saved automatically (review pending)')
                : tr(context, '已確認', 'Confirmed'));
    final captureLabel = switch (memory.captureMethod) {
      'agent_auto' => tr(context, '來源：你開啟記憶後，安心伴從對話自動保存',
          'Source: saved automatically from chat after you enabled Memory'),
      'user_saved' =>
        tr(context, '來源：你在對話中選擇保存', 'Source: you chose to save it from chat'),
      'manual' => tr(context, '來源：你手動加入', 'Source: added by you'),
      _ => tr(context, '來源：你加入的記憶', 'Source: your memory'),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (onSelected != null)
              CheckboxListTile(
                key: ValueKey('select-memory-${memory.id}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: selected,
                onChanged:
                    canDelete ? (value) => onSelected!(value ?? false) : null,
                title: Text(tr(context, '選擇此記憶', 'Select this memory')),
              ),
            Wrap(spacing: 12, runSpacing: 6, children: [
              Text(status,
                  style: const TextStyle(
                      color: Color(0xFF116466), fontWeight: FontWeight.w700)),
              Text(_memoryKindLabel(context, memory.kind),
                  style: Theme.of(context).textTheme.bodyMedium),
            ]),
            const SizedBox(height: 8),
            Text(memory.content, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 6),
            Text(captureLabel, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (memory.isCandidate && !memory.suppressed)
                  FilledButton.tonal(
                      onPressed:
                          busy ? null : () => controller.confirmMemory(memory),
                      child: Text(tr(context, '確認保存', 'Confirm and save'))),
                if (controller.isElder &&
                    memory.isConfirmed &&
                    !memory.suppressed)
                  OutlinedButton(
                      key: ValueKey('create-private-card-${memory.id}'),
                      onPressed: busy || controller.loading
                          ? null
                          : () async {
                              final draft =
                                  controller.prepareMemoryCardDraft(memory);
                              if (draft == null) {
                                await controller.refreshMemoryControlState();
                                return;
                              }
                              if (!context.mounted) return;
                              await showDialog<void>(
                                  context: context,
                                  builder: (_) => StoryComposerDialog(
                                      memories: [memory],
                                      controller: controller,
                                      cardDraft: draft));
                            },
                      child:
                          Text(tr(context, '建立私人卡片', 'Create private card'))),
                OutlinedButton(
                    onPressed: busy ? null : () => onEdit(memory),
                    child: Text(tr(context, '修改', 'Edit'))),
                TextButton(
                    onPressed: busy ? null : () => onSuppress(memory),
                    child: Text(memory.suppressed
                        ? tr(context, '恢復使用', 'Restore')
                        : tr(context, '暫停使用', 'Pause'))),
                TextButton(
                    onPressed: canDelete ? () => onDelete(memory) : null,
                    child: Text(tr(context, '刪除', 'Delete'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class StoriesScreen extends ConsumerStatefulWidget {
  const StoriesScreen({super.key});

  @override
  ConsumerState<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends ConsumerState<StoriesScreen> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_refresh);
  }

  Future<void> _refresh() async {
    final controller = ref.read(appControllerProvider);
    await controller.refreshMemoryControlState();
    await controller.refreshMemories(silent: true);
    await controller.refreshStories(silent: true);
  }

  Future<void> _create() async {
    final controller = ref.read(appControllerProvider);
    final draft = controller.prepareStoryCreateDraft();
    if (draft == null) {
      await controller.refreshMemoryControlState();
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => StoryComposerDialog(
        memories: controller.memories
            .where((memory) => memory.isConfirmed && !memory.suppressed)
            .toList(),
        controller: controller, cardDraft: draft, selectSources: true,
      ),
    );
  }

  Future<void> _delete(StoryRecord story) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, '刪除故事卡？', 'Delete this story card?')),
        content: Text(tr(context, '這張故事卡及透過它分享的家庭訊息內容會撤回。對方已另行保存的副本無法撤回。',
            'This story card and family messages shared from it will be withdrawn. Copies saved separately by recipients cannot be withdrawn.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, '返回', 'Back'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, '確認刪除', 'Delete'))),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await ref.read(appControllerProvider).deleteStory(story);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    if (!controller.isElder) {
      return Scaffold(
          body: Center(
              child: Text(tr(context, '私人卡片只供本人查看。',
                  'Private cards are visible only to their owner.'))));
    }
    final missingMemoryState =
        controller.supportsMemoryControls && controller.memoryRevision == null;
    final canCreate = !controller.loading &&
        !missingMemoryState &&
        !controller.memoryDeletionBusy &&
        controller.pendingMemoryDeletion == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, '故事卡', 'Story cards')),
        actions: [
          IconButton(
              tooltip: tr(context, '建立故事卡', 'Create story card'),
              onPressed: canCreate ? _create : null,
              icon: const Icon(Icons.add_rounded))
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Text(tr(context, '把記憶整理成自己的故事', 'Tell your story'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 7),
            Text(tr(context, '故事由你寫、由你刪除。分享前一定會顯示收件人和完整內容讓你確認。',
                'You write and delete your stories. Before sharing, review the recipient and full content.')),
            const SizedBox(height: 18),
            if (missingMemoryState) ...[
              Text(tr(context, '請先重新載入記憶，再建立故事卡。',
                  'Refresh your memories before creating a story card.')),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('refresh-story-memories'),
                onPressed: controller.loading || controller.memoryDeletionBusy
                    ? null
                    : _refresh,
                child: Text(tr(context, '重新載入記憶', 'Refresh memories'),
                    textAlign: TextAlign.center),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
                onPressed: canCreate ? _create : null,
                icon: const Icon(Icons.add_rounded),
                label: Text(tr(context, '建立故事卡', 'Create story card')),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52))),
            const SizedBox(height: 16),
            if (controller.stories.isEmpty)
              EmptyCard(
                  icon: Icons.auto_stories_outlined,
                  message: tr(context, '目前沒有故事卡。你可以從幾段記憶開始整理。',
                      'No story cards yet. Start with a few memories.'))
            else
              ...controller.stories
                  .map((story) => StoryCard(story: story, onDelete: _delete)),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 14),
              ErrorBanner(
                  message: controller.errorMessage!,
                  onRetry: () => controller.refreshStories()),
            ],
          ],
        ),
      ),
    );
  }
}

class StoryDraft {
  const StoryDraft(
      {required this.title, required this.content, required this.memoryIds});

  final String title;
  final String content;
  final List<String> memoryIds;
}

class StoryComposerDialog extends StatefulWidget {
  const StoryComposerDialog(
      {required this.memories, this.controller, this.cardDraft, this.selectSources = false, super.key});

  final AppController? controller;
  final MemoryCardDraft? cardDraft;
  final bool selectSources;

  final List<MemoryRecord> memories;

  @override
  State<StoryComposerDialog> createState() => _StoryComposerDialogState();
}

class _StoryComposerDialogState extends State<StoryComposerDialog> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  final Set<String> _selected = <String>{};
  MemoryCardDraft? _activeDraft;
  bool _saving = false;
  bool _closing = false;
  String? _validation;

  @override
  void initState() {
    super.initState();
    _activeDraft = widget.cardDraft;
    _title = TextEditingController(text: widget.cardDraft?.title ?? '');
    _content = TextEditingController(text: widget.cardDraft?.content ?? '');
    widget.controller?.addListener(_changed);
  }

  void _changed() {
    final draft = _activeDraft;
    if (!mounted || _closing || draft == null) return;
    if (!widget.controller!.isMemoryCardDraftCurrent(draft)) {
      _closing = true;
      // Drop RAM text immediately; never attach it to another session.
      _title.clear();
      _content.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final content = _content.text.trim();
    if (title.isEmpty ||
        content.isEmpty ||
        title.runes.length > 240 ||
        content.runes.length > 30000) {
      setState(() => _validation = tr(context, '請填寫標題（最多240字）及內容（最多30,000字）。',
          'Enter a title (up to 240 characters) and content (up to 30,000 characters).'));
      return;
    }
    if (_activeDraft == null) {
      Navigator.pop(
          context,
          StoryDraft(
              title: title, content: content, memoryIds: _selected.toList()));
      return;
    }
    if (_saving) return;
    if (!widget.controller!.isMemoryCardDraftCurrent(_activeDraft!)) {
      _changed();
      return;
    }
    if (widget.selectSources) {
      final selectedDraft = widget.controller!.prepareStoryCreateDraft(
        memoryIds: _selected.toList());
      if (selectedDraft == null || selectedDraft.revision != _activeDraft!.revision) {
        _changed();
        return;
      }
      _activeDraft = selectedDraft;
    }
    setState(() {
      _saving = true;
      _validation = null;
    });
    final ok = await widget.controller!
        .saveMemoryCardDraft(_activeDraft!, title: title, content: content);
    if (!mounted || _closing) return;
    if (ok) {
      _closing = true;
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
      _changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _activeDraft;
    final editing = draft?.storyId != null;
    final busy = _saving || (widget.controller?.loading ?? false);
    return AlertDialog(
      insetPadding: const EdgeInsets.all(12),
      scrollable: true,
      title: Text(editing
          ? tr(context, '編輯私人卡片', 'Edit private card')
          : draft != null
              ? tr(context, '建立私人卡片', 'Create private card')
              : tr(context, '建立故事卡', 'Create story card')),
      content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr(context, '私人：儲存不會分享給家人。',
                  'Private: saving does not share with family.')),
              if (editing) ...[
                const SizedBox(height: 12),
                Text(tr(
                    context,
                    '儲存編輯後，舊的站內分享內容會撤回。新內容須重新預覽、選擇收件人並確認傳送；不會自動重發。',
                    'Saving edits withdraws old in-app shared content. Sharing the new content requires a new preview, recipient selection and confirmation; it will not be resent automatically.')),
              ],
              const SizedBox(height: 12),
              TextField(
                  key: const ValueKey('private-card-title'),
                  controller: _title,
                  readOnly: busy,
                  decoration: InputDecoration(
                      labelText: tr(context, '故事標題', 'Story title'))),
              const SizedBox(height: 12),
              TextField(
                  key: const ValueKey('private-card-content'),
                  controller: _content,
                  readOnly: busy,
                  minLines: 4,
                  maxLines: 8,
                  decoration: InputDecoration(
                      labelText: tr(context, '故事內容', 'Story content'))),
              if (draft != null && !widget.selectSources) ...[
                const SizedBox(height: 16),
                Text(tr(context, '來源（唯讀）', 'Sources (read-only)'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                for (final id in draft.memoryIds) ...[
                  const SizedBox(height: 8),
                  Text(tr(context, '來源：$id', 'Source: $id')),
                  for (final memory in widget.memories.where((m) => m.id == id))
                    Text(memory.content),
                ],
              ] else if (widget.memories.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                    tr(context, '想引用哪些記憶？',
                        'Which memories would you like to reference?'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                ...widget.memories.map((memory) => CheckboxListTile(
                    dense: true,
                    value: _selected.contains(memory.id),
                    onChanged: busy ? null : (value) => setState(() => value == true
                        ? _selected.add(memory.id)
                        : _selected.remove(memory.id)),
                    title: Text(memory.content),
                    controlAffinity: ListTileControlAffinity.leading)),
              ],
              if (_validation != null) ...[
                const SizedBox(height: 12),
                Text(_validation!)
              ],
              if (widget.controller?.errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(widget.controller!.errorMessage!)
              ],
              const SizedBox(height: 16),
              OutlinedButton(
                  key: const ValueKey('cancel-private-card'),
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: Text(tr(context, '返回', 'Back'),
                      textAlign: TextAlign.center)),
              const SizedBox(height: 8),
              FilledButton(
                  key: const ValueKey('save-private-card'),
                  onPressed: busy ? null : _save,
                  child: Text(
                      draft == null
                          ? tr(context, '建立', 'Create')
                          : tr(context, '儲存', 'Save'),
                      textAlign: TextAlign.center)),
            ],
          )),
    );
  }
}

class StoryCard extends ConsumerWidget {
  const StoryCard({required this.story, required this.onDelete, super.key});

  final StoryRecord story;
  final Future<void> Function(StoryRecord) onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    if (!controller.isElder) return const SizedBox.shrink();
    final tooLongToShare =
        '${story.title}\n${story.content}'.runes.length > 10000;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(context, '私人卡片', 'Private card')),
          const SizedBox(height: 8),
          Text(story.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(story.content, style: Theme.of(context).textTheme.bodyLarge),
          if (story.memoryIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
                tr(context, '引用 ${story.memoryIds.length} 項記憶',
                    '${story.memoryIds.length} memories referenced'),
                style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: 9),
          if (tooLongToShare)
            Text(tr(context, '全文超過10,000字，無法分享；請先編輯卡片。',
                'The full card exceeds 10,000 characters and cannot be shared. Edit the card first.')),
          Wrap(spacing: 8, children: [
            if (controller.isElder)
              OutlinedButton(
                  key: ValueKey('edit-private-card-${story.id}'),
                  onPressed: controller.loading
                      ? null
                      : () async {
                          final draft = controller.prepareStoryEditDraft(story);
                          if (draft == null) {
                            await controller.refreshMemoryControlState();
                            return;
                          }
                          if (!context.mounted) return;
                          await showDialog<void>(
                              context: context,
                              builder: (_) => StoryComposerDialog(
                                  memories: controller.memories,
                                  controller: controller,
                                  cardDraft: draft));
                        },
                  child: Text(tr(context, '編輯卡片', 'Edit card'))),
            if (controller.familyMessageLinks.isNotEmpty)
              FilledButton.tonal(
                onPressed: tooLongToShare
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) =>
                            FamilyMessagesScreen(initialStory: story))),
                child: Text(tr(context, '分享給家庭成員', 'Share with family')),
              ),
            TextButton(
                onPressed: controller.updatingStoryIds.contains(story.id)
                    ? null
                    : () => onDelete(story),
                child: Text(tr(context, '刪除', 'Delete'))),
          ]),
        ]),
      ),
    );
  }
}

class ResourcesScreen extends ConsumerStatefulWidget {
  const ResourcesScreen({super.key});

  @override
  ConsumerState<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends ConsumerState<ResourcesScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_query.text.trim().isEmpty) return;
    await ref.read(appControllerProvider).searchResources(_query.text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '生活資源', 'Resources'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text(tr(context, '找有來源的資料', 'Find trusted information'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          Text(tr(context, '資料會顯示查找方式、核實日期、適用條件和下一步。遇到資料差異時，請先查看提示。',
              'Results show sources, verification dates, conditions and next steps. Review any notices about conflicting information.')),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _query,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                    labelText:
                        tr(context, '例如：醫療費用減免', 'Example: medical fee waiver'),
                    prefixIcon: Icon(Icons.search_rounded)),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
                tooltip: tr(context, '搜尋資源', 'Search resources'),
                onPressed: _search,
                icon: const Icon(Icons.search_rounded),
                style: IconButton.styleFrom(minimumSize: const Size(54, 54))),
          ]),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              tr(context, '醫療費用減免', 'Medical fee waiver'),
              tr(context, '照顧者支援', 'Caregiver support'),
              tr(context, '日間暫託', 'Day respite')
            ]
                .map((query) => ActionChip(
                      label: Text(query),
                      onPressed: () {
                        _query.text = query;
                        _search();
                      },
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                    ))
                .toList(),
          ),
          if (controller.resourceRetrievalMode != null) ...[
            const SizedBox(height: 12),
            Text(
                tr(
                    context,
                    '查找方式：${_retrievalLabel(context, controller.resourceRetrievalMode)}',
                    'Search: ${_retrievalLabel(context, controller.resourceRetrievalMode)}'),
                style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (controller.resourceConflicts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
                color: const Color(0xFFFFF0D7),
                child: Padding(
                    padding: const EdgeInsets.all(15),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr(context, '資料之間有差異', 'Sources differ'),
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 7),
                          ...controller.resourceConflicts.map((conflict) =>
                              Text(conflict.title.isEmpty
                                  ? conflict.summary
                                  : '${conflict.title}：${conflict.summary}'))
                        ]))),
          ],
          const SizedBox(height: 16),
          if (controller.resourceItems.isEmpty)
            EmptyCard(
                icon: Icons.local_library_outlined,
                message: controller.resourceRetrievalMode == null
                    ? tr(context, '輸入你需要的支援，或點選上面的常用搜尋。',
                        'Enter the support you need, or choose a suggested search above.')
                    : tr(context, '暫時找不到相符資料。試試較簡單的字詞，例如「照顧者支援」。',
                        'No matching information found. Try simpler words, such as caregiver support.'))
          else
            ...controller.resourceItems.map((item) => ResourceCard(item: item)),
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 14),
            ErrorBanner(message: controller.errorMessage!, onRetry: _search),
          ],
        ],
      ),
    );
  }
}

class ResourceCard extends StatelessWidget {
  const ResourceCard({required this.item, super.key});

  final ResourceItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 16, 17, 15),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          if (item.verifiedAt != null)
            Text(
                tr(context, '資料核實：${_dateLabel(context, item.verifiedAt)}',
                    'Verified: ${_dateLabel(context, item.verifiedAt)}'),
                style: const TextStyle(fontSize: 15, color: Color(0xFF526663))),
          const SizedBox(height: 12),
          Text(tr(context, '先了解，再申請；實際資格由服務機構評估。',
              'Check the details before applying. The service provider determines eligibility.')),
          if (item.url != null && item.url!.isNotEmpty) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final uri = Uri.tryParse(item.url!);
                if (uri == null ||
                    !await launchUrl(uri,
                        mode: LaunchMode.externalApplication)) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(tr(context, '暫時未能開啟來源連結。',
                            'Unable to open the source link right now.'))));
                  }
                }
              },
              icon: const Icon(Icons.open_in_new_rounded, size: 20),
              label: Text(tr(context, '開啟來源', 'Open source')),
            ),
          ],
          if (item.nextSteps.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(tr(context, '你可以這樣做', 'Your next steps'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...item.nextSteps.asMap().entries.map((step) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                              color: Color(0xFFDDEDEA), shape: BoxShape.circle),
                          child: Text('${step.key + 1}',
                              style: const TextStyle(
                                  color: Color(0xFF116466),
                                  fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(step.value)),
                      ]),
                )),
          ],
          const Divider(height: 24),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 16),
            title: Text(
                tr(context, '了解服務及適用條件', 'Service details and eligibility')),
            children: [
              Align(alignment: Alignment.centerLeft, child: Text(item.excerpt)),
              if (item.effectiveDate != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(tr(
                        context,
                        '生效日期：${_dateLabel(context, item.effectiveDate)}',
                        'Effective: ${_dateLabel(context, item.effectiveDate)}'))),
              ...item.conditions.map((text) => _ResourceDetail(text: text)),
            ],
          ),
          if (item.missingInformation.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 16),
              title: Text(tr(context, '申請前還需確認甚麼？',
                  'What should I check before applying?')),
              children: item.missingInformation
                  .map((text) => _ResourceDetail(text: text))
                  .toList(),
            ),
        ]),
      ),
    );
  }
}

class _ResourceDetail extends StatelessWidget {
  const _ResourceDetail({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('•  ', style: TextStyle(color: Color(0xFF116466))),
          Expanded(child: Text(text)),
        ]),
      );
}

class FamilyMessagesScreen extends ConsumerStatefulWidget {
  const FamilyMessagesScreen({this.initialStory, super.key});

  final StoryRecord? initialStory;

  @override
  ConsumerState<FamilyMessagesScreen> createState() =>
      _FamilyMessagesScreenState();
}

class _FamilyMessagesScreenState extends ConsumerState<FamilyMessagesScreen> {
  final _contentController = TextEditingController();
  FamilyInvitation? _selected;
  bool _reviewing = false;
  FamilyInvitation? _previewLink;
  String? _previewContent;
  bool _previewRetired = false;
  late final AppController _sourceController;
  late final AuthSession? _sourceSession;
  late final String? _sourceOwnerId;
  bool _sourceInvalidated = false;

  @override
  void initState() {
    super.initState();
    _sourceController = ref.read(appControllerProvider);
    _sourceSession = _sourceController.session;
    _sourceOwnerId = _sourceController.user?.id;
    final story = widget.initialStory;
    if (story != null) {
      _contentController.text = '${story.title}\n${story.content}';
    }
    _sourceController.addListener(_sourceChanged);
    Future<void>.microtask(() =>
        ref.read(appControllerProvider).refreshFamilyMessages(silent: true));
  }

  bool _sourceCurrent(AppController controller) {
    final story = widget.initialStory;
    if (_sourceInvalidated || !identical(controller, _sourceController) ||
        !identical(controller.session, _sourceSession) ||
        controller.user?.id != _sourceOwnerId) {
      return false;
    }
    if (story == null) return true;
    if (!controller.isElder ||
        controller.memoryDeletionBusy || controller.pendingMemoryDeletion != null ||
        controller.memoryRevision != story.revision) {
      return false;
    }
    final matches = controller.stories.where((s) => s.id == story.id).toList();
    if (matches.length != 1) return false;
    final current = matches.single;
    return current.revision == story.revision && current.title == story.title &&
      current.content == story.content && current.memoryIds.length == story.memoryIds.length &&
      current.memoryIds.toSet().containsAll(story.memoryIds);
  }

  void _clearSource() {
    _sourceInvalidated = true;
    _reviewing = false;
    _selected = null;
    _previewLink = null;
    _previewContent = null;
    _contentController.clear();
  }

  void _sourceChanged() {
    if (!mounted || _sourceInvalidated) return;
    if (!_sourceCurrent(_sourceController)) {
      setState(_clearSource);
    } else if (_selected != null && !_sourceController.familyMessageLinks.contains(_selected)) {
      setState(() { _reviewing = false; _selected = null; _previewLink = null; _previewContent = null; _previewRetired = true; });
    }
  }

  @override
  void dispose() {
    _sourceController.removeListener(_sourceChanged);
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final controller = ref.read(appControllerProvider);
    if (!_sourceCurrent(controller)) {
      setState(_clearSource);
      return;
    }
    final link = _reviewing ? _previewLink : null;
    final content = _previewContent;
    if (link != null && !controller.familyMessageLinks.contains(link)) {
      setState(() { _reviewing = false; _selected = null; _previewLink = null; _previewContent = null; _previewRetired = true; });
      return;
    }
    if (link == null || content == null ||
        content.trim().isEmpty ||
        content.runes.length > 10000) {
      return;
    }
    final ok = await controller.sendFamilyMessage(
      link: link,
      content: content,
      sourceStory: widget.initialStory,
    );
    if (ok && mounted) {
      setState(() {
        _reviewing = false;
        _previewLink = null;
        _previewContent = null;
        if (widget.initialStory == null) _contentController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '家庭訊息已由伺服器發送。', 'Family message sent.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    if (!_sourceCurrent(controller)) {
      _clearSource();
      return Scaffold(appBar: AppBar(title: Text(tr(context, '家庭訊息', 'Family messages'))),
        body: Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(tr(context,
          '卡片或帳戶已變更。請重新開啟目前的卡片並選擇收件人。',
          widget.initialStory == null ? 'The account changed. Reopen family messages and choose a recipient.' : 'The card or account changed. Reopen the current card and choose a recipient.')))));
    }
    final tooLong = widget.initialStory != null &&
        _contentController.text.runes.length > 10000;
    final links = controller.familyMessageLinks
        .where((link) => controller.recipientIdFor(link) != null)
        .toList();
    if (_selected != null && !links.contains(_selected)) {
      _reviewing = false;
      _selected = null;
      _previewLink = null;
      _previewContent = null;
      _previewRetired = true;
    }
    if (_selected == null || !links.contains(_selected)) {
      _selected = widget.initialStory != null || _previewRetired || links.isEmpty ? null : links.first;
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '家庭訊息', 'Family messages'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text(tr(context, '只傳給已授權的家人', 'Message authorized family members'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          Text(tr(context, '長者私密聊天不會出現在這裡。每次發送前，你都會看到收件人和完整內容。',
              'Private chats do not appear here. Review the recipient and complete message before every send.')),
          const SizedBox(height: 18),
          if (tooLong)
            Text(tr(context, '全文超過10,000字，無法分享；請先編輯卡片。',
                'The full card exceeds 10,000 characters and cannot be shared. Edit the card first.')),
          if (links.isEmpty)
            EmptyCard(
                icon: Icons.lock_outline_rounded,
                message: tr(context, '目前沒有開啟「家庭訊息」的家庭連結。請由長者重新發出邀請並主動勾選這項權限。',
                    'No family links have messaging enabled. The senior must send a new invitation and select Allow family messages.'))
          else if (_reviewing && _previewLink != null)
            _FamilyMessageReview(
                link: _previewLink!,
                content: _previewContent!,
                story: widget.initialStory,
                onBack: () => setState(() { _reviewing = false; _previewLink = null; _previewContent = null; }),
                onConfirm: controller.loading || tooLong ? null : _send)
          else ...[
            DropdownButtonFormField<FamilyInvitation>(
              isExpanded: true,
              isDense: false,
              itemHeight: null,
              initialValue: _selected,
              decoration: InputDecoration(
                  labelText: tr(context, '收件人', 'Recipient'),
                  prefixIcon: Icon(Icons.person_outline_rounded)),
              items: [
                for (final link in links)
                  DropdownMenuItem(
                      value: link,
                      child: Text(_counterpartLabel(context, controller, link)))
              ],
              onChanged: (value) => setState(() { _selected = value; _previewRetired = false; }),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _contentController,
              readOnly: widget.initialStory != null,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: widget.initialStory == null
                    ? tr(context, '訊息內容', 'Message')
                    : tr(context, '故事卡內容', 'Story card content'),
                helperText: widget.initialStory == null
                    ? null
                    : tr(context, '分享故事卡時內容會保持原文，伺服器會再次核對故事版本。',
                        'Story cards are shared unchanged. The server checks the story version before sending.'),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
                onPressed: controller.loading || tooLong || _selected == null
                    ? null
                    : () => setState(() {
                        _previewLink = _selected;
                        _previewContent = _contentController.text;
                        _reviewing = true;
                      }),
                icon: const Icon(Icons.visibility_outlined),
                label: Text(tr(context, '檢視並確認發送', 'Review before sending')),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54))),
          ],
          if (controller.familyMessages.isNotEmpty) ...[
            const SizedBox(height: 24),
            SectionTitle(title: tr(context, '訊息記錄', 'Message history')),
            const SizedBox(height: 9),
            ...controller.familyMessages.map((message) => FamilyMessageCard(
                message: message, currentUserId: controller.user?.id)),
          ],
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 14),
            ErrorBanner(
                message: controller.errorMessage!,
                onRetry: () => controller.refreshFamilyMessages()),
          ],
        ],
      ),
    );
  }
}

class _FamilyMessageReview extends StatelessWidget {
  const _FamilyMessageReview(
      {required this.link,
      required this.content,
      required this.story,
      required this.onBack,
      required this.onConfirm});

  final FamilyInvitation link;
  final String content;
  final StoryRecord? story;
  final VoidCallback onBack;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final controller =
        ProviderScope.containerOf(context).read(appControllerProvider);
    return Card(
      color: const Color(0xFFDDEDEA),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(context, '請確認後才會發送', 'Review before sending'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(
              tr(context, '收件人：${_counterpartLabel(context, controller, link)}',
                  'To: ${_counterpartLabel(context, controller, link)}'),
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 10),
          Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              color: Colors.white,
              child:
                  Text(content, style: Theme.of(context).textTheme.bodyLarge)),
          if (story != null) ...[
            const SizedBox(height: 8),
            Text(tr(context, '這是故事卡原文分享，服務會核對你仍擁有最新版本。',
                'This shares the original story. The service checks that you still own the current version.'))
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: OutlinedButton(
                    onPressed: onBack,
                    child: Text(tr(context, '返回編輯', 'Edit')))),
            const SizedBox(width: 10),
            Expanded(
                child: FilledButton(
                    onPressed: onConfirm,
                    child: Text(tr(context, '確認發送', 'Confirm send'))))
          ]),
        ]),
      ),
    );
  }
}

class FamilyMessageCard extends StatelessWidget {
  const FamilyMessageCard(
      {required this.message, required this.currentUserId, super.key});

  final FamilyMessage message;
  final String? currentUserId;

  @override
  Widget build(BuildContext context) {
    final mine = currentUserId != null && message.senderId == currentUserId;
    final sender = mine
        ? tr(context, '你', 'You')
        : (message.senderName ?? tr(context, '家庭成員', 'Family member'));
    return Card(
        margin: const EdgeInsets.only(bottom: 9),
        child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 17, vertical: 7),
            leading: Icon(mine ? Icons.outbox_rounded : Icons.inbox_rounded,
                color: const Color(0xFF116466)),
            title: Text(sender,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(message.content,
                style: const TextStyle(fontSize: 17, height: 1.35))));
  }
}

String _dateLabel(BuildContext context, DateTime? value) {
  if (value == null) return tr(context, '未提供', 'Not provided');
  return '${value.year}/${value.month}/${value.day}';
}

String _retrievalLabel(BuildContext context, String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'keyword':
    case 'lexical':
    case 'keyword_search':
      return tr(context, '關鍵字查找', 'Keyword search');
    case 'hybrid':
    case 'hybrid_python':
    case 'hybrid_keyword_embedding':
    case 'hybrid_pgvector':
    case 'semantic_keyword':
    case 'vector_keyword':
      return tr(context, '語意與關鍵字查找', 'Semantic and keyword search');
    case 'verified_registry':
    case 'official_registry':
      return tr(context, '已核實資料查找', 'Verified sources');
    case 'local':
      return tr(context, '你的已保存記憶', 'Your saved memories');
    case 'deterministic_demo':
    case 'demo':
      return tr(context, '示範資料', 'Demo data');
    default:
      return tr(context, '服務提供的查找結果', 'Retrieved results');
  }
}

String _memoryKindLabel(BuildContext context, String value) {
  switch (value.trim().toLowerCase()) {
    case 'fact':
      return tr(context, '生活事實', 'Life fact');
    case 'preference':
      return tr(context, '喜好', 'Preference');
    case 'emotion':
      return tr(context, '心情', 'Emotion');
    case 'experience':
      return tr(context, '生活經歷', 'Experience');
    default:
      return tr(context, '生活記憶', 'Memory');
  }
}

class DemoModeLabel extends StatelessWidget {
  const DemoModeLabel({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12, vertical: compact ? 5 : 8),
      decoration: BoxDecoration(
          color: const Color(0xFFFFE5C1),
          borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.science_outlined,
            size: compact ? 16 : 19, color: const Color(0xFF8B4E2D)),
        const SizedBox(width: 6),
        Text(
            compact
                ? tr(context, '示範模式', 'Demo')
                : tr(context, '伺服器示範模式', 'Demo replies'),
            style: TextStyle(
                fontSize: compact ? 12 : 15,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF8B4E2D)))
      ]),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({required this.message, this.onRetry, super.key});

  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFE7E1),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline_rounded, color: Color(0xFF9A3D28)),
            const SizedBox(width: 10),
            Expanded(
                child: Text(_errorLabel(context, message),
                    style: const TextStyle(color: Color(0xFF742817)))),
            if (onRetry != null)
              TextButton(
                  onPressed: onRetry, child: Text(tr(context, '重試', 'Retry'))),
          ],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({required this.title, this.action, super.key});

  final String title;
  final String? action;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
      if (action != null)
        Text(action!, style: Theme.of(context).textTheme.bodyMedium)
    ]);
  }
}

class EmptyCard extends StatelessWidget {
  const EmptyCard({required this.icon, required this.message, super.key});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 28, color: const Color(0xFF116466)),
          const SizedBox(width: 14),
          Expanded(child: Text(message))
        ]),
      ),
    );
  }
}

String _roleLabel(BuildContext context, UserRole role) => role == UserRole.elder
    ? tr(context, '長者', 'Senior')
    : tr(context, '照顧者', 'Caregiver');
String _taskStatusLabel(BuildContext context, TaskStatus status) =>
    switch (status) {
      TaskStatus.pending => tr(context, '待處理', 'Pending'),
      TaskStatus.inProgress => tr(context, '進行中', 'In progress'),
      TaskStatus.completed => tr(context, '已完成', 'Completed'),
      TaskStatus.dismissed => tr(context, '已略過', 'Skipped'),
      TaskStatus.failed => tr(context, '需要重試', 'Retry needed'),
    };
String _invitationStatusLabel(BuildContext context, InvitationStatus status) =>
    switch (status) {
      InvitationStatus.pending => tr(context, '等待接受', 'Awaiting acceptance'),
      InvitationStatus.accepted => tr(context, '已連結', 'Linked'),
      InvitationStatus.revoked => tr(context, '已撤回', 'Revoked'),
      InvitationStatus.expired => tr(context, '已過期', 'Expired'),
      InvitationStatus.unknown => tr(context, '未知道狀態', 'Unknown status'),
    };
String _counterpartLabel(
    BuildContext context, AppController controller, FamilyInvitation link) {
  return controller.familyCounterpartLabel(link);
}

String _errorLabel(BuildContext context, String message) {
  const translations = <String, String>{
    '請輸入邀請碼，服務才可以確認這個連結。': 'Enter the invitation code to confirm this link.',
    '這位家庭成員尚未授權家庭訊息。': 'This family member has not authorized messages.',
    '連線逾時，請檢查網絡後再試。':
        'Connection timed out. Check your connection and try again.',
    '暫時未能連接服務，請檢查網絡後再試。':
        'Unable to connect. Check your connection and try again.',
    '登入已過期，請重新登入。': 'Your session has expired. Please sign in again.',
    '你沒有權限進行這項操作。': 'You do not have permission for this action.',
    '服務回覆的登入資料不完整，請稍後再試。':
        'Sign-in information was incomplete. Please try again later.',
    '服務回覆的帳戶資料不完整。': 'Account information was incomplete.',
    '服務未回覆新對話資料。': 'The service did not return the new conversation.',
    '服務未回覆新對話編號。': 'The service did not return the conversation ID.',
    '服務未回覆更新後的任務。': 'The service did not return the updated task.',
    '服務未回覆邀請資料。': 'The service did not return the invitation.',
    '服務未回覆接受後的連結。': 'The service did not return the accepted link.',
    '服務未回覆故事資料。': 'The service did not return the story.',
    '服務未回覆故事編號。': 'The service did not return the story ID.',
    '服務未回覆家庭訊息。': 'The service did not return the family message.',
    '服務未回覆家庭訊息編號。': 'The service did not return the family message ID.',
    '服務未回覆記憶資料。': 'The service did not return the memory.',
    '服務未回覆記憶編號。': 'The service did not return the memory ID.',
  };
  final english = translations[message];
  if (english != null) return tr(context, message, english);
  final status = RegExp(r'^服務暫時未能完成要求（(\d{3})）。$').firstMatch(message);
  if (status != null) {
    return tr(context, message,
        'The service could not complete the request (${status.group(1)}).');
  }
  return message;
}

class SafetySupportCard extends ConsumerWidget {
  const SafetySupportCard({required this.links, super.key});

  final List<FamilyInvitation> links;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      color: const Color(0xFFFFF0E8),
      margin: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.support_rounded,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr(context, '你不必獨自面對',
                        'You do not have to face this alone'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(tr(
              context,
              '我很高興你告訴我。若你或他人正處於即時危險，請致電999或前往最近的急症室。安心伴不能提供緊急救援，也不會自動聯絡任何人。',
              'I am glad you told me. If you or someone else is in immediate danger, call 999 or go to the nearest emergency department. Anxin cannot provide emergency rescue and will not contact anyone automatically.',
            )),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () async {
                    final launched =
                        await launchUrl(Uri(scheme: 'tel', path: '999'));
                    if (!launched && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tr(
                            context,
                            '無法開啟電話。請使用電話撥打999。',
                            'Could not open the phone app. Please dial 999 directly.',
                          )),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.call_rounded),
                  label: Text(tr(context, '致電999', 'Call 999')),
                ),
                OutlinedButton.icon(
                  onPressed: links.isEmpty
                      ? null
                      : () => _sendFamilySupportRequest(context, ref),
                  icon: const Icon(Icons.message_outlined),
                  label: Text(tr(
                    context,
                    '向一位家人求助',
                    'Ask one family member for support',
                  )),
                ),
                OutlinedButton.icon(
                  key: const Key('open-designated-support'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CareControlsScreen(
                        controller: ref.read(appControllerProvider),
                        initialTab: 2,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.contact_emergency_outlined),
                  label: Text(
                      tr(context, '指定聯絡人支援', 'Designated contact support')),
                ),
              ],
            ),
            if (links.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                tr(
                  context,
                  '目前沒有已授權家庭訊息的聯絡人。你可使用家庭頁面設定授權；不會向其他人發送訊息。',
                  'No family-message recipient is currently authorized. You can set up permission in Family; nobody else will be contacted.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _sendFamilySupportRequest(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final controller = ref.read(appControllerProvider);
    var selectedId = links.first.id;
    final selected = await showDialog<FamilyInvitation>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tr(
            context,
            '選擇一位已授權家人',
            'Choose one authorized family member',
          )),
          content: DropdownButtonFormField<String>(
            initialValue: selectedId,
            items: links
                .map(
                  (link) => DropdownMenuItem(
                    value: link.id,
                    child: Text(controller.familyCounterpartLabel(link)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setDialogState(() => selectedId = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(context, '取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                links.firstWhere((link) => link.id == selectedId),
              ),
              child: Text(tr(context, '下一步', 'Continue')),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !context.mounted) return;

    const messageEnglish =
        'I may need some support. Please contact me when you can.';
    const messageChinese = '我現在可能需要一些支援。方便時請聯絡我。';
    final message = Localizations.localeOf(context).languageCode == 'en'
        ? messageEnglish
        : messageChinese;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, '請確認求助訊息', 'Review support request')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${tr(context, '收件人：', 'Recipient: ')}${controller.familyCounterpartLabel(selected)}',
            ),
            const SizedBox(height: 12),
            Text(message),
            const SizedBox(height: 12),
            Text(tr(
              context,
              '只有在你確認後，訊息才會傳送。若有即時危險，請致電999。',
              'The message is sent only after you confirm. For immediate danger, call 999.',
            )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, '返回', 'Back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, '確認並傳送', 'Confirm and send')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final sent = await controller.sendFamilyMessage(
      link: selected,
      content: message,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? tr(context, '求助訊息已傳送。', 'Support request sent.')
              : controller.errorMessage ??
                  tr(
                    context,
                    '未能傳送求助訊息；如有即時危險，請致電999。',
                    'The support request could not be sent. Call 999 if there is immediate danger.',
                  ),
        ),
      ),
    );
  }
}

class ActivityCatalogScreen extends ConsumerStatefulWidget {
  const ActivityCatalogScreen({super.key});

  @override
  ConsumerState<ActivityCatalogScreen> createState() =>
      _ActivityCatalogScreenState();
}

class _ActivityCatalogScreenState extends ConsumerState<ActivityCatalogScreen> {
  String? _selectedDistrict;
  String? _selectedInterest;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      final controller = ref.read(appControllerProvider);
      controller.refreshCatalogActivities(silent: true);
      controller.refreshCatalogInterests(silent: true);
      if (controller.isElder) {
        controller.refreshCatalogRecommendations(silent: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final activities = controller.catalogActivities;
    final filtered = activities.where((a) {
      if (_selectedDistrict != null &&
          (a.district ?? '').replaceAll('區', '') !=
              _selectedDistrict!.replaceAll('區', '')) {
        return false;
      }
      if (_selectedInterest != null &&
          !a.interestTags.any((t) =>
              t.toLowerCase().contains(_selectedInterest!.toLowerCase()))) {
        return false;
      }
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '社區參與', 'Community'))),
      body: RefreshIndicator(
        onRefresh: () async {
          await controller.refreshCatalogActivities(
            district: _selectedDistrict,
            interest: _selectedInterest,
          );
          await controller.refreshCatalogInterests(silent: true);
          if (controller.isElder) {
            await controller.refreshCatalogRecommendations(silent: true);
          }
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Text(tr(context, '參與社區活動', 'Join community activities'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 7),
            Text(tr(context, '按地區或興趣篩選活動目錄。示例活動只供試用，時間、費用及地點須向機構確認。表達興趣不代表已報名。',
                'Filter the activity directory by district or interest. Example activities are for trying the app; confirm times, fees and venues with the organizer. Expressing interest is not registration.')),
            const SizedBox(height: 18),

            // District filter
            DropdownButtonFormField<String>(
              initialValue: _selectedDistrict,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: tr(context, '按地區', 'By district'),
                prefixIcon: const Icon(Icons.place_outlined),
              ),
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(tr(context, '全部地區', 'All districts')),
                ),
                ..._hongKongDistricts.map((d) => DropdownMenuItem(
                      value: d.$2,
                      child: Text(
                          Localizations.localeOf(context).languageCode == 'en'
                              ? d.$1
                              : d.$2),
                    )),
              ],
              onChanged: (value) {
                setState(() => _selectedDistrict = value);
                controller.refreshCatalogActivities(
                  silent: true,
                  district: _selectedDistrict,
                  interest: _selectedInterest,
                );
              },
            ),
            const SizedBox(height: 12),

            // Interest filter
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ('太極', 'Tai Chi'),
                ('書法', 'Calligraphy'),
                ('煮食', 'Cooking'),
                ('義工', 'Volunteering'),
                ('合唱', 'Choir'),
                ('園藝', 'Gardening'),
                ('數碼', 'Digital'),
              ].map((tag) {
                final selected = _selectedInterest == tag.$1;
                return FilterChip(
                  label: Text(tr(context, tag.$1, tag.$2)),
                  selected: selected,
                  onSelected: (value) {
                    setState(() => _selectedInterest = value ? tag.$1 : null);
                    controller.refreshCatalogActivities(
                      silent: true,
                      district: _selectedDistrict,
                      interest: _selectedInterest,
                    );
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 18),

            // Recommendations section (elder only)
            if (controller.isElder &&
                controller.catalogRecommendations.isNotEmpty) ...[
              SectionTitle(title: tr(context, '為你推薦', 'Activity suggestions')),
              const SizedBox(height: 9),
              ...controller.catalogRecommendations
                  .take(3)
                  .map((activity) => CatalogActivityCard(
                        activity: activity,
                        isInterested: controller.catalogInterests
                            .any((i) => i.id == activity.id),
                        onInterest: controller.isElder
                            ? () => (controller.catalogInterests
                                    .any((i) => i.id == activity.id)
                                ? controller.withdrawInterest(activity)
                                : controller.expressInterest(activity))
                            : null,
                      )),
              const SizedBox(height: 18),
            ],

            // My interests section
            if (controller.isElder &&
                controller.catalogInterests.isNotEmpty) ...[
              SectionTitle(
                  title: tr(context, '我感興趣的', 'My interests'),
                  action: '${controller.catalogInterests.length}'),
              const SizedBox(height: 9),
              ...controller.catalogInterests
                  .map((activity) => CatalogActivityCard(
                        activity: activity,
                        isInterested: true,
                        onInterest: () => controller.withdrawInterest(activity),
                      )),
              const SizedBox(height: 18),
            ],

            // All activities
            SectionTitle(
                title: tr(context, '全部活動', 'All activities'),
                action: filtered.isEmpty ? null : '${filtered.length}'),
            const SizedBox(height: 9),
            if (filtered.isEmpty)
              EmptyCard(
                  icon: Icons.groups_outlined,
                  message: tr(context, '暫時沒有符合篩選條件的活動。試試其他地區或興趣。',
                      'No activities match your filters. Try a different district or interest.'))
            else
              ...filtered.map((activity) => CatalogActivityCard(
                    activity: activity,
                    isInterested: controller.catalogInterests
                        .any((i) => i.id == activity.id),
                    onInterest: controller.isElder
                        ? () => (controller.catalogInterests
                                .any((i) => i.id == activity.id)
                            ? controller.withdrawInterest(activity)
                            : controller.expressInterest(activity))
                        : null,
                  )),

            if (controller.errorMessage != null) ...[
              const SizedBox(height: 14),
              ErrorBanner(message: controller.errorMessage!),
            ],
          ],
        ),
      ),
    );
  }
}

class CatalogActivityCard extends StatelessWidget {
  const CatalogActivityCard(
      {required this.activity,
      required this.isInterested,
      this.onInterest,
      super.key});
  final CatalogActivity activity;
  final bool isInterested;
  final Future<bool> Function()? onInterest;

  String _availabilityText(BuildContext context) {
    switch (activity.availabilityStatus) {
      case 'current':
        return tr(context, '活動資料仍有效；參加前請向主辦機構核實。',
            'Activity information current; verify with the organizer before attending.');
      case 'date_unknown':
        return tr(context, '活動日期不詳；參加前請向主辦機構核實。',
            'Activity dates unknown; verify with the organizer before attending.');
      case 'expired':
        return tr(context, '活動已過期；只保留興趣記錄。',
            'Activity expired; retained as interest history only.');
      case 'invalid_date':
        return tr(
            context, '活動日期無效；暫時無法參加。', 'Activity dates invalid; unavailable.');
      case 'unverified':
        return tr(context, '活動資料未經核實。', 'Activity details unverified.');
      default:
        return tr(context, '活動暫時無法參加。', 'Activity unavailable.');
    }
  }

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(17, 16, 17, 15),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!activity.verified)
              Text(tr(context, '示範活動 — 詳情未經核實',
                  'Example activity — details unverified')),
            Text(activity.title,
                style: Theme.of(context).textTheme.titleMedium),
            if (activity.contributionType != null)
              Chip(
                  label: Text(activity.contributionType == 'contribute'
                      ? tr(context, '貢獻', 'Contribute')
                      : tr(context, '參與', 'Participate'))),
            if (activity.organizer?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text(activity.organizer!),
            ],
            const SizedBox(height: 8),
            Text(activity.description),
            if (activity.district?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.place_outlined, size: 18),
                const SizedBox(width: 4),
                Expanded(child: Text(activity.district!))
              ]),
            ],
            if (activity.scheduleNote?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.schedule_outlined, size: 18),
                const SizedBox(width: 4),
                Expanded(child: Text(activity.scheduleNote!))
              ]),
            ],
            if (activity.mobilityNote?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.accessible_outlined, size: 18),
                const SizedBox(width: 4),
                Expanded(child: Text(activity.mobilityNote!))
              ]),
            ],
            if (activity.interestTags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: activity.interestTags
                      .map((tag) => Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact))
                      .toList()),
            ],
            if (activity.availabilityStatus != null || !activity.available) ...[
              const SizedBox(height: 10),
              Text(_availabilityText(context)),
            ],
            if (activity.verifiedAt != null) ...[
              const SizedBox(height: 6),
              Text('${tr(context, '最後核實日期', 'Last checked')}: '
                  '${activity.verifiedAt!.year}-${activity.verifiedAt!.month.toString().padLeft(2, '0')}-${activity.verifiedAt!.day.toString().padLeft(2, '0')}'),
            ],
            if (activity.recommendationBasis == 'general') ...[
              const SizedBox(height: 10),
              Text(tr(context, '一般建議', 'General suggestion')),
              Text(tr(context, '非個人化建議，仍可能包含你不喜歡的活動。',
                  'Not personalized. These suggestions may include activities you dislike.')),
            ],
            if (activity.recommendationBasis == 'memory')
              Padding(padding: const EdgeInsets.only(top: 10), child: Text(tr(context,
                  '僅表示技能相關，不代表喜歡或願意參加。',
                  'Skill-related match; this does not imply liking or willingness to participate.'))),
            if (activity.recommendationBasis == 'memory')
              ...activity.recommendationReasons.map((reason) => Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                        '${reason.sourceType == 'skill' ? tr(context, '已確認的技能：', 'Confirmed skill: ') : tr(context, '已儲存的喜好：', 'Saved preference: ')}${reason.sourceText}\n'
                        '${tr(context, '配對主題：', 'Matched topic: ')}${reason.matchedTag}'),
                  )),
            if (activity.url?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text('${tr(context, '資料來源', 'Source')}: ${activity.url}'),
            ],
            if (activity.available && activity.url?.isNotEmpty == true) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(activity.url!);
                  if (uri == null ||
                      !await launchUrl(uri,
                          mode: LaunchMode.externalApplication)) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(tr(context, '暫時無法開啟資料來源連結。',
                              'Unable to open the source link right now.'))));
                    }
                  }
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 20),
                label: Text(tr(context, '開啟來源', 'Open source')),
              ),
            ],
            if (onInterest != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed:
                    isInterested || activity.available ? onInterest : null,
                icon: Icon(isInterested
                    ? Icons.check_circle_rounded
                    : Icons.favorite_border_rounded),
                label: Text(isInterested
                    ? tr(context, '撤回興趣', 'Withdraw interest')
                    : tr(context, '表示有興趣', 'Express interest')),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
          ]),
        ),
      );
}

// ---------------------------------------------------------------------------
// Scam Safety (FR SCM 01-04)
// ---------------------------------------------------------------------------

class ScamSafetyScreen extends ConsumerStatefulWidget {
  const ScamSafetyScreen({super.key});

  @override
  ConsumerState<ScamSafetyScreen> createState() => _ScamSafetyScreenState();
}

class _ScamSafetyScreenState extends ConsumerState<ScamSafetyScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      final controller = ref.read(appControllerProvider);
      controller.refreshScamResources(silent: true);
      controller.refreshVerifyActions(silent: true);
      controller.refreshScamContacts(silent: true);
      controller.refreshScamLogs(silent: true);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, '防騙指引', 'Scam safety'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text(tr(context, '核實、暫停、保護', 'Verify, Pause, Protect'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          Text(tr(context, '遇到可疑電話或訊息時，記住三個步驟。安心伴不會代你報警或自動聯絡家人。',
              'When you receive a suspicious call or message, follow three steps. Anxin does not report to police or contact family automatically.')),
          const SizedBox(height: 18),

          // Three-step verify actions (FR SCM 02)
          if (controller.verifyActions.isNotEmpty) ...[
            ...controller.verifyActions.map((action) => Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: Color(0xFFDDEDEA),
                            shape: BoxShape.circle,
                          ),
                          child: Text('${action.step}',
                              style: const TextStyle(
                                  color: Color(0xFF116466),
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(action.title,
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 4),
                              Text(action.description),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )),
            const SizedBox(height: 18),
          ],

          // Verified contacts (FR SCM 03)
          SectionTitle(title: tr(context, '已核實反詐騙聯絡', 'Verified contacts')),
          const SizedBox(height: 9),
          ...controller.scamContacts.map((contact) => Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 17, vertical: 6),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFDDEDEA),
                    child: Icon(Icons.phone_in_talk_rounded,
                        color: Color(0xFF116466)),
                  ),
                  title: Text(contact.name,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  subtitle: contact.description != null
                      ? Text(contact.description!)
                      : null,
                  trailing: FilledButton.icon(
                    onPressed: () async {
                      final launched = await launchUrl(Uri(
                          scheme: 'tel',
                          path: contact.phone.replaceAll(' ', '')));
                      if (!launched && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(tr(context, '無法開啟電話。',
                              'Could not open the phone app.')),
                        ));
                      }
                    },
                    icon: const Icon(Icons.call_rounded),
                    label: Text(contact.phone),
                  ),
                ),
              )),
          const SizedBox(height: 18),

          // Search scam resources (FR SCM 01)
          SectionTitle(title: tr(context, '常見騙局指引', 'Scam guidance')),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onSubmitted: (_) =>
                      controller.searchScamResources(_searchController.text),
                  decoration: InputDecoration(
                    labelText: tr(context, '搜尋騙局類型', 'Search scam type'),
                    prefixIcon: const Icon(Icons.search_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: tr(context, '搜尋', 'Search'),
                onPressed: () =>
                    controller.searchScamResources(_searchController.text),
                icon: const Icon(Icons.search_rounded),
                style: IconButton.styleFrom(minimumSize: const Size(54, 54)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Scam resource cards
          ...controller.scamResources
              .map((resource) => ScamResourceCard(resource: resource)),

          // Scam guidance history (FR SCM 04)
          if (controller.isElder && controller.scamLogs.isNotEmpty) ...[
            const SizedBox(height: 18),
            SectionTitle(title: tr(context, '指引記錄', 'Guidance history')),
            const SizedBox(height: 9),
            ...controller.scamLogs.map((log) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 17, vertical: 4),
                    leading: const Icon(Icons.shield_outlined,
                        color: Color(0xFF116466)),
                    title: Text(log.scamType,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(log.guidanceSummary.isEmpty
                        ? tr(context, '已提供防騙指引', 'Scam guidance provided')
                        : log.guidanceSummary),
                  ),
                )),
          ],

          if (controller.errorMessage != null) ...[
            const SizedBox(height: 14),
            ErrorBanner(message: controller.errorMessage!),
          ],
        ],
      ),
    );
  }
}

class ScamResourceCard extends StatelessWidget {
  const ScamResourceCard({required this.resource, super.key});

  final ScamResource resource;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 16, 17, 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(resource.title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (resource.scamType != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFE5C1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(resource.scamType!,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF8B4E2D),
                            fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (resource.verifiedAt != null)
              Text(
                tr(context, '資料核實：${_dateLabel(context, resource.verifiedAt)}',
                    'Verified: ${_dateLabel(context, resource.verifiedAt)}'),
                style: const TextStyle(fontSize: 15, color: Color(0xFF526663)),
              ),
            const SizedBox(height: 10),
            Text(resource.excerpt),
            if (resource.warningSigns.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(tr(context, '常見警號', 'Warning signs'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...resource.warningSigns.map((sign) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            size: 20, color: Color(0xFF8B4E2D)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(sign)),
                      ],
                    ),
                  )),
            ],
            if (resource.verificationSteps.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(tr(context, '核實步驟', 'Verification steps'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...resource.verificationSteps
                  .asMap()
                  .entries
                  .map((entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                  color: Color(0xFFDDEDEA),
                                  shape: BoxShape.circle),
                              child: Text('${entry.key + 1}',
                                  style: const TextStyle(
                                      color: Color(0xFF116466),
                                      fontWeight: FontWeight.w700)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(entry.value)),
                          ],
                        ),
                      )),
            ],
            if (resource.nextSteps.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(tr(context, '你可以這樣做', 'Your next steps'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...resource.nextSteps.map((step) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  ',
                            style: TextStyle(color: Color(0xFF116466))),
                        Expanded(child: Text(step)),
                      ],
                    ),
                  )),
            ],
            if (resource.officialContacts.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: resource.officialContacts
                    .map((contact) => ActionChip(
                          label: Text(contact),
                          avatar: const Icon(Icons.phone_outlined, size: 18),
                          onPressed: () async {
                            final tel =
                                contact.replaceAll(RegExp(r'[^0-9]'), '');
                            if (tel.isNotEmpty) {
                              await launchUrl(Uri(scheme: 'tel', path: tel));
                            }
                          },
                        ))
                    .toList(),
              ),
            ],
            if (resource.sourceUrl != null &&
                resource.sourceUrl!.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(resource.sourceUrl!);
                  if (uri == null ||
                      !await launchUrl(uri,
                          mode: LaunchMode.externalApplication)) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(tr(context, '暫時未能開啟來源連結。',
                              'Unable to open the source link right now.'))));
                    }
                  }
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 20),
                label: Text(tr(context, '開啟來源', 'Open source')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const _hongKongDistricts = <(String, String)>[
  ('Central and Western', '中西區'),
  ('Eastern', '東區'),
  ('Southern', '南區'),
  ('Wan Chai', '灣仔'),
  ('Kowloon City', '九龍城'),
  ('Kwun Tong', '觀塘'),
  ('Sham Shui Po', '深水埗'),
  ('Wong Tai Sin', '黃大仙'),
  ('Yau Tsim Mong', '油尖旺'),
  ('Islands', '離島'),
  ('Kwai Tsing', '葵青'),
  ('North', '北區'),
  ('Sai Kung', '西貢'),
  ('Sha Tin', '沙田'),
  ('Tai Po', '大埔'),
  ('Tsuen Wan', '荃灣'),
  ('Tuen Mun', '屯門'),
  ('Yuen Long', '元朗'),
];
