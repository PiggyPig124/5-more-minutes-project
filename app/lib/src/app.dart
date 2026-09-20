import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'app_controller.dart';
import 'models.dart';
import 'storage.dart';

final apiProvider = Provider<AnxinApi>((ref) => RestApiClient());
final localStoreProvider = Provider<LocalStore>((ref) => SecureLocalStore());
final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SessionStore(ref.watch(localStoreProvider)),
);
final appControllerProvider = ChangeNotifierProvider<AppController>(
  (ref) => AppController(
    api: ref.watch(apiProvider),
    sessionStore: ref.watch(sessionStoreProvider),
  ),
);

class AnxinApp extends ConsumerWidget {
  const AnxinApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: '安心伴',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
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
    textTheme: base.textTheme.copyWith(
      displaySmall: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
      headlineSmall: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
      titleLarge: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
      titleMedium: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      bodyLarge: const TextStyle(fontSize: 19, height: 1.45),
      bodyMedium: const TextStyle(fontSize: 17, height: 1.4),
      labelLarge: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
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
          label: '正在連接安心伴服務',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.favorite_rounded, size: 68, color: Color(0xFF116466)),
              const SizedBox(height: 18),
              Text('安心伴', style: Theme.of(context).textTheme.displaySmall),
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
                    const Icon(Icons.favorite_rounded, size: 72, color: Color(0xFF116466)),
                    const SizedBox(height: 12),
                    Text('安心伴', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displaySmall),
                    const SizedBox(height: 8),
                    Text(
                      _register ? '建立你的安心伴帳戶' : '陪你一步一步處理生活大小事',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 30),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('登入'), icon: Icon(Icons.login_rounded)),
                        ButtonSegment(value: true, label: Text('註冊'), icon: Icon(Icons.person_add_alt_1_rounded)),
                      ],
                      selected: {_register},
                      onSelectionChanged: (values) => setState(() => _register = values.first),
                    ),
                    const SizedBox(height: 22),
                    if (_register) ...[
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: '稱呼你甚麼？', prefixIcon: Icon(Icons.person_outline_rounded)),
                        validator: (value) => value == null || value.trim().isEmpty ? '請輸入稱呼' : null,
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('你是', style: Theme.of(context).textTheme.titleMedium),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<UserRole>(
                        segments: const [
                          ButtonSegment(value: UserRole.elder, label: Text('長者'), icon: Icon(Icons.elderly_rounded)),
                          ButtonSegment(value: UserRole.caregiver, label: Text('照顧者'), icon: Icon(Icons.diversity_1_rounded)),
                        ],
                        selected: {_role},
                        onSelectionChanged: (values) => setState(() => _role = values.first),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: '電郵地址', prefixIcon: Icon(Icons.email_outlined)),
                      validator: (value) => value == null || !value.contains('@') ? '請輸入有效電郵地址' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(labelText: '密碼', prefixIcon: Icon(Icons.lock_outline_rounded)),
                      validator: (value) => value == null || value.length < 8 ? '密碼最少需要 8 個字元' : null,
                    ),
                    const SizedBox(height: 18),
                    if (error != null) ErrorBanner(message: error),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: controller.loading ? null : _submit,
                      icon: controller.loading
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(_register ? Icons.person_add_alt_1_rounded : Icons.login_rounded),
                      label: Text(_register ? '建立帳戶' : '登入安心伴'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '你的對話只會由伺服器按授權保存和處理。長者私密對話不會因家庭連結而共享。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54),
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
        ? const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: '首頁'),
            NavigationDestination(icon: Icon(Icons.chat_bubble_outline_rounded), selectedIcon: Icon(Icons.chat_rounded), label: '聊天'),
            NavigationDestination(icon: Icon(Icons.checklist_outlined), selectedIcon: Icon(Icons.checklist_rounded), label: '任務'),
            NavigationDestination(icon: Icon(Icons.people_outline_rounded), selectedIcon: Icon(Icons.people_rounded), label: '家庭'),
          ]
        : const [
            NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard_rounded), label: '概覽'),
            NavigationDestination(icon: Icon(Icons.checklist_outlined), selectedIcon: Icon(Icons.checklist_rounded), label: '共享任務'),
            NavigationDestination(icon: Icon(Icons.people_outline_rounded), selectedIcon: Icon(Icons.people_rounded), label: '家庭連結'),
          ];
    final body = elder
        ? [
            ElderHome(onChat: () => _goTo(1)),
            const ElderChatScreen(),
            const TasksScreen(),
            const FamilyScreen(),
          ][_index]
        : [
            const CaregiverHome(),
            const TasksScreen(),
            const FamilyScreen(),
          ][_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(elder ? '安心伴 · 長者' : '安心伴 · 照顧者'),
        actions: [
          if (controller.session?.demoMode == true)
            const Padding(padding: EdgeInsets.only(right: 8), child: DemoModeLabel(compact: true)),
          IconButton(
            tooltip: '帳戶設定及登出',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(user.displayName.isEmpty ? user.role.label : user.displayName, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            Text('${user.email} · ${user.role.label}', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: controller.loading
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await controller.logout();
                    },
              icon: const Icon(Icons.logout_rounded),
              label: const Text('登出這個帳戶'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
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
          if (controller.session?.demoMode == true) const DemoModeLabel(),
          Text('你好，${user?.displayName.isNotEmpty == true ? user!.displayName : '朋友'}', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text('今天想找人傾吓偈，或者一起整理一件小事嗎？', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 20),
          Card(
            color: const Color(0xFFDDEDEA),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.wb_sunny_rounded, color: Color(0xFF116466), size: 34),
                  const SizedBox(height: 12),
                  Text('今日陪伴', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  const Text('你可以和安心伴分享心情，也可以說說今天想完成的事情。'),
                  const SizedBox(height: 18),
                  FilledButton.icon(onPressed: onChat, icon: const Icon(Icons.chat_rounded), label: const Text('開始聊天'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          SectionTitle(title: '今日任務', action: controller.tasks.isEmpty ? null : '${controller.tasks.length} 項'),
          const SizedBox(height: 10),
          if (controller.tasks.isEmpty)
            const EmptyCard(icon: Icons.check_circle_outline_rounded, message: '暫時沒有共享任務。聊天時有需要，安心伴會先讓你確認。')
          else
            ...controller.tasks.take(3).map((task) => TaskTile(task: task)),
          const SizedBox(height: 22),
          SectionTitle(title: '我的資料'),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.bookmark_outline_rounded,
            title: '我的記憶',
            description: '查看和管理你明確保存的生活記憶。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MemoriesScreen()),
            ),
          ),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.auto_stories_outlined,
            title: '故事卡',
            description: '把幾段記憶整理成自己的故事。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const StoriesScreen()),
            ),
          ),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.local_library_outlined,
            title: '生活資源',
            description: '查找有來源和日期的社區資料。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ResourcesScreen()),
            ),
          ),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.forum_outlined,
            title: '家庭訊息',
            description: '只與你主動授權的家庭成員聯絡。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FamilyMessagesScreen()),
            ),
          ),
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 18),
            ErrorBanner(message: controller.errorMessage!, onRetry: () => controller.refreshHome()),
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
    final active = controller.tasks.where((task) => task.status != TaskStatus.completed && task.status != TaskStatus.dismissed).length;
    return RefreshIndicator(
      onRefresh: () => controller.refreshHome(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          if (controller.session?.demoMode == true) const DemoModeLabel(),
          Text('照顧概覽', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          const Text('這裡只顯示長者明確授權的共享照顧事項。私密對話不會出現在照顧者帳戶。'),
          const SizedBox(height: 20),
          Card(
            color: const Color(0xFFF5E5D6),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Row(
                children: [
                  const Icon(Icons.volunteer_activism_rounded, color: Color(0xFF8B4E2D), size: 38),
                  const SizedBox(width: 16),
                  Expanded(child: Text('$active 項共享事項待處理', style: Theme.of(context).textTheme.titleLarge)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          SectionTitle(title: '最近共享任務', action: controller.tasks.isEmpty ? null : '${controller.tasks.length} 項'),
          const SizedBox(height: 10),
          if (controller.tasks.isEmpty)
            const EmptyCard(icon: Icons.inbox_outlined, message: '長者確認共享事項後，任務會在這裡出現。')
          else
            ...controller.tasks.take(5).map((task) => TaskTile(task: task)),
          const SizedBox(height: 22),
          SectionTitle(title: '需要時可以使用'),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.local_library_outlined,
            title: '生活資源',
            description: '查看有來源、有日期的照顧資料。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ResourcesScreen()),
            ),
          ),
          const SizedBox(height: 10),
          FeatureCard(
            icon: Icons.forum_outlined,
            title: '家庭訊息',
            description: '只與有明確訊息授權的家庭成員聯絡。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FamilyMessagesScreen()),
            ),
          ),
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 18),
            ErrorBanner(message: controller.errorMessage!, onRetry: () => controller.refreshHome()),
          ],
        ],
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
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatDetailScreen(conversation: conversation)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Row(
            children: [
              Expanded(child: Text('我的對話', style: Theme.of(context).textTheme.headlineSmall)),
              FilledButton.icon(onPressed: () => _newConversation(context, ref), icon: const Icon(Icons.add_comment_rounded), label: const Text('新對話')),
            ],
          ),
        ),
        Expanded(
          child: controller.conversations.isEmpty
              ? ListView(padding: const EdgeInsets.all(20), children: const [EmptyCard(icon: Icons.forum_outlined, message: '還未有對話。按「新對話」就可以開始。')])
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
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          leading: const CircleAvatar(child: Icon(Icons.chat_bubble_outline_rounded)),
                          title: Text(conversation.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                          subtitle: Text(conversation.preview ?? '按一下繼續這段對話。'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatDetailScreen(conversation: conversation))),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
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

  @override
  void initState() {
    super.initState();
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
    _draftController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _draftController.text;
    if (text.trim().isEmpty) return;
    final sent = await ref.read(appControllerProvider).sendMessage(conversationId: widget.conversation.id, content: text);
    if (sent && mounted) {
      _draftController.clear();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (_scrollController.hasClients) _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final messages = controller.messagesFor(widget.conversation.id);
    final actions = controller.pendingActions.where((action) => action.conversationId == null || action.conversationId == widget.conversation.id).toList();
    final busy = controller.sendingConversationIds.contains(widget.conversation.id);
    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.title)),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.session?.demoMode == true) const Padding(padding: EdgeInsets.fromLTRB(20, 12, 20, 0), child: DemoModeLabel()),
            if (controller.errorMessage != null) Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 0), child: ErrorBanner(message: controller.errorMessage!)),
            Expanded(
              child: messages.isEmpty && actions.isEmpty
                  ? ListView(padding: const EdgeInsets.all(24), children: const [EmptyCard(icon: Icons.chat_rounded, message: '你可以慢慢說。我會先聽清楚，再問你要不要一起安排下一步。')])
                  : ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      children: [
                        ...messages.map((message) => MessageBubble(message: message)),
                        ...actions.map((action) => ActionCard(action: action)),
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
                        onChanged: (value) => ref.read(appControllerProvider).saveDraft(widget.conversation.id, value),
                        decoration: const InputDecoration(hintText: '寫下你想分享的事…', prefixIcon: Icon(Icons.edit_note_rounded)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filled(
                      tooltip: '傳送訊息',
                      onPressed: busy ? null : _send,
                      icon: busy ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_rounded),
                      style: IconButton.styleFrom(minimumSize: const Size(54, 54)),
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
  const MessageBubble({required this.message, super.key});

  final ChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            Text(message.body, style: TextStyle(color: mine ? Colors.white : Colors.black87, fontSize: 18, height: 1.45)),
            if (!mine && message.retrievalMode != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFDDEDEA),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '取用資料：${_retrievalLabel(message.retrievalMode)}',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF116466), fontWeight: FontWeight.w700),
                ),
              ),
            ],
            if (!mine && message.memorySources.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('相關記憶', style: Theme.of(context).textTheme.labelLarge),
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
                        const Icon(Icons.format_quote_rounded, size: 18, color: Color(0xFF8B4E2D)),
                        const SizedBox(width: 6),
                        Expanded(child: Text(source.content, style: const TextStyle(fontSize: 14, height: 1.35))),
                        const SizedBox(width: 4),
                        const Text('已保存來源', style: TextStyle(fontSize: 12, color: Color(0xFF116466))),
                      ],
                    ),
                  ),
                ),
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
            Row(children: [const Icon(Icons.pending_actions_rounded, color: Color(0xFF8B4E2D)), const SizedBox(width: 10), Expanded(child: Text('請你確認', style: Theme.of(context).textTheme.titleMedium))]),
            const SizedBox(height: 10),
            Text(action.title, style: Theme.of(context).textTheme.titleMedium),
            if (action.description.isNotEmpty) ...[const SizedBox(height: 6), Text(action.description)],
            if (action.recipientLabel != null) ...[const SizedBox(height: 6), Text('對象：${action.recipientLabel}')],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: FilledButton(onPressed: busy ? null : () => ref.read(appControllerProvider).confirmAction(action), child: busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('確認建立'))),
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton(onPressed: busy ? null : () => ref.read(appControllerProvider).dismissAction(action), child: const Text('先略過'))),
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
    return RefreshIndicator(
      onRefresh: () => controller.refreshHome(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text(elder ? '我的任務' : '共享任務', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          Text(elder ? '確認後建立的照顧事項會在這裡追蹤。' : '只顯示長者授權共享的照顧事項。', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 18),
          if (controller.tasks.isEmpty) const EmptyCard(icon: Icons.checklist_rounded, message: '目前沒有任務。') else ...controller.tasks.map((task) => TaskTile(task: task, interactive: true)),
          if (controller.errorMessage != null) ...[const SizedBox(height: 18), ErrorBanner(message: controller.errorMessage!, onRetry: () => controller.refreshHome())],
        ],
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
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: CircleAvatar(backgroundColor: complete ? const Color(0xFFDDEDEA) : const Color(0xFFFFE5C1), child: Icon(complete ? Icons.check_rounded : Icons.schedule_rounded, color: const Color(0xFF116466))),
        title: Text(task.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        subtitle: Text(task.description.isEmpty ? task.status.label : '${task.description}\n${task.status.label}', maxLines: 3, overflow: TextOverflow.ellipsis),
        isThreeLine: task.description.isNotEmpty,
        trailing: interactive && !complete
            ? TextButton(onPressed: updating ? null : () => controller.updateTaskStatus(task, TaskStatus.completed), child: updating ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('完成'))
            : Text(task.status.label),
      ),
    );
  }
}

class FamilyScreen extends ConsumerStatefulWidget {
  const FamilyScreen({super.key});

  @override
  ConsumerState<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends ConsumerState<FamilyScreen> {
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('邀請已由伺服器建立。請把一次性邀請碼交給照顧者。')));
    }
  }

  Future<void> _accept(FamilyInvitation invitation) async {
    final ok = await ref.read(appControllerProvider).acceptInvitation(invitation, token: _tokenController.text);
    if (ok && mounted) {
      _tokenController.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('家庭連結已由伺服器確認。')));
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
          Text(elder ? '家庭連結' : '家庭連結', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          Text(elder ? '你決定誰可以看到共享照顧事項。私密聊天一直只屬於你。' : '接受長者邀請後，你只會看到已授權的共享照顧事項。', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 20),
          if (elder) ...[
            Text('邀請照顧者', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 9),
            Row(children: [Expanded(child: TextField(controller: _emailController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: '照顧者電郵'))), const SizedBox(width: 10), IconButton.filled(tooltip: '發出邀請', onPressed: controller.loading ? null : _invite, icon: const Icon(Icons.send_rounded), style: IconButton.styleFrom(minimumSize: const Size(54, 54)))]),
            const SizedBox(height: 8),
            Card(
              color: const Color(0xFFF5EDE3),
              child: CheckboxListTile(
                value: _includeFamilyMessages,
                onChanged: (value) => setState(() => _includeFamilyMessages = value ?? false),
                title: const Text('允許家庭訊息', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('只在你主動勾選後，對方才可以和你互傳家庭訊息。預設不開啟。'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ),
            const SizedBox(height: 20),
            if (controller.invitations.isNotEmpty) ...[Text('已發出的邀請', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 9), ...controller.invitations.map((inv) => InvitationTile(invitation: inv, onRevoke: () => controller.revokeInvitation(inv)))],
          ] else ...[
            Text('接受邀請', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 9),
            TextField(controller: _tokenController, decoration: const InputDecoration(labelText: '一次性邀請碼', prefixIcon: Icon(Icons.key_rounded))),
            const SizedBox(height: 12),
            if (controller.invitations.isEmpty) const EmptyCard(icon: Icons.mail_outline_rounded, message: '收到長者邀請後，把邀請碼貼在上面。') else ...controller.invitations.map((inv) => InvitationTile(invitation: inv, onAccept: () => _accept(inv))),
          ],
          const SizedBox(height: 22),
          if (controller.links.isNotEmpty) ...[
            Text('目前連結', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 9),
            ...controller.links.map((link) => InvitationTile(invitation: link, onRevoke: () => controller.revokeInvitation(link))),
          ],
          if (controller.errorMessage != null) ...[const SizedBox(height: 18), ErrorBanner(message: controller.errorMessage!, onRetry: () => controller.refreshHome())],
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
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        leading: Icon(invitation.status == InvitationStatus.accepted ? Icons.link_rounded : Icons.mail_outline_rounded),
        title: Text(invitation.name?.isNotEmpty == true ? invitation.name! : invitation.email, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${invitation.email}\n${invitation.status.label}'
          '${invitation.allowsFamilyMessages ? '\n已允許家庭訊息' : ''}',
        ),
        isThreeLine: invitation.allowsFamilyMessages,
        trailing: onAccept != null
            ? TextButton(onPressed: onAccept, child: const Text('接受'))
            : onRevoke != null && invitation.status != InvitationStatus.revoked
                ? TextButton(onPressed: onRevoke, child: const Text('撤回'))
                : null,
      ),
    );
  }
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
                    Text(description, style: Theme.of(context).textTheme.bodyMedium),
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

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => ref.read(appControllerProvider).refreshMemories(silent: true));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _edit(MemoryRecord memory) async {
    final editor = TextEditingController(text: memory.content);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改記憶'),
        content: TextField(
          controller: editor,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(labelText: '記憶內容'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.pop(context, editor.text), child: const Text('保存修改')),
        ],
      ),
    );
    editor.dispose();
    if (!mounted || value == null || value.trim().isEmpty) return;
    final ok = await ref.read(appControllerProvider).editMemory(memory, value);
    if (mounted && ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('記憶已更新。相關故事卡會先撤回，避免保留舊內容。')));
    }
  }

  Future<void> _delete(MemoryRecord memory) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除這項記憶？'),
        content: const Text('相關故事卡和聊天引用也會由服務撤回或遮蔽。這個操作無法還原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('確認刪除')),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await ref.read(appControllerProvider).deleteMemory(memory);
  }

  Future<void> _suppress(MemoryRecord memory) async {
    if (memory.suppressed) {
      await ref.read(appControllerProvider).restoreMemory(memory);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('暫停使用這項記憶？'),
        content: const Text('安心伴不會再用它作為回答參考；你仍可在此恢復或刪除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('暫停使用')),
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
    return Scaffold(
      appBar: AppBar(title: const Text('我的記憶')),
      body: RefreshIndicator(
        onRefresh: () => controller.refreshMemories(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Text('只由你決定保存', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 7),
            const Text('聊天裡出現的記憶只會先成為候選。你可以確認、修改、暫停使用或刪除；安心伴不會自動保存你的情緒。'),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onSubmitted: (_) => controller.searchMemories(_searchController.text),
                    decoration: const InputDecoration(labelText: '搜尋我的記憶', prefixIcon: Icon(Icons.search_rounded)),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: '搜尋記憶',
                  onPressed: () => controller.searchMemories(_searchController.text),
                  icon: const Icon(Icons.search_rounded),
                  style: IconButton.styleFrom(minimumSize: const Size(54, 54)),
                ),
              ],
            ),
            if (controller.memoryRetrievalMode != null && results.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('搜尋方式：${_retrievalLabel(controller.memoryRetrievalMode)}', style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (results.isNotEmpty) ...[
              const SizedBox(height: 16),
              SectionTitle(title: '搜尋結果'),
              const SizedBox(height: 9),
              ...results.map((memory) => MemoryCard(memory: memory, onEdit: _edit, onDelete: _delete, onSuppress: _suppress)),
            ],
            const SizedBox(height: 18),
            SectionTitle(title: '已保存及候選', action: memories.isEmpty ? null : '${memories.length} 項'),
            const SizedBox(height: 9),
            if (memories.isEmpty)
              const EmptyCard(icon: Icons.bookmark_border_rounded, message: '目前沒有記憶。聊天中的來源可以按「保存」成為候選。')
            else
              ...memories.map((memory) => MemoryCard(memory: memory, onEdit: _edit, onDelete: _delete, onSuppress: _suppress)),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 14),
              ErrorBanner(message: controller.errorMessage!, onRetry: () => controller.refreshMemories()),
            ],
          ],
        ),
      ),
    );
  }
}

class MemoryCard extends ConsumerWidget {
  const MemoryCard({required this.memory, required this.onEdit, required this.onDelete, required this.onSuppress, super.key});

  final MemoryRecord memory;
  final Future<void> Function(MemoryRecord) onEdit;
  final Future<void> Function(MemoryRecord) onDelete;
  final Future<void> Function(MemoryRecord) onSuppress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final busy = controller.updatingMemoryIds.contains(memory.id);
    final status = memory.suppressed ? '已暫停使用' : (memory.isCandidate ? '候選，等待你確認' : '已確認');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Expanded(child: Text(status, style: const TextStyle(color: Color(0xFF116466), fontWeight: FontWeight.w700))), Text(_memoryKindLabel(memory.kind), style: Theme.of(context).textTheme.bodyMedium)]),
            const SizedBox(height: 8),
            Text(memory.content, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (memory.isCandidate && !memory.suppressed)
                  FilledButton.tonal(onPressed: busy ? null : () => controller.confirmMemory(memory), child: const Text('確認保存')),
                OutlinedButton(onPressed: busy ? null : () => onEdit(memory), child: const Text('修改')),
                TextButton(onPressed: busy ? null : () => onSuppress(memory), child: Text(memory.suppressed ? '恢復使用' : '暫停使用')),
                TextButton(onPressed: busy ? null : () => onDelete(memory), child: const Text('刪除')),
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
    Future<void>.microtask(() => ref.read(appControllerProvider).refreshStories(silent: true));
  }

  Future<void> _create() async {
    final controller = ref.read(appControllerProvider);
    final draft = await showDialog<StoryDraft>(
      context: context,
      builder: (_) => StoryComposerDialog(
        memories: controller.memories
            .where((memory) => memory.isConfirmed && !memory.suppressed)
            .toList(),
      ),
    );
    if (draft == null || !mounted) return;
    await controller.createStory(title: draft.title, content: draft.content, memoryIds: draft.memoryIds);
  }

  Future<void> _delete(StoryRecord story) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除故事卡？'),
        content: const Text('已經發出的家庭訊息會保留當時的內容；之後不會再顯示這張故事卡。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('確認刪除')),
        ],
      ),
    );
    if (accepted == true && mounted) await ref.read(appControllerProvider).deleteStory(story);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('故事卡'),
        actions: [IconButton(tooltip: '建立故事卡', onPressed: controller.loading ? null : _create, icon: const Icon(Icons.add_rounded))],
      ),
      body: RefreshIndicator(
        onRefresh: () => controller.refreshStories(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Text('把記憶整理成自己的故事', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 7),
            const Text('故事由你寫、由你刪除。分享前一定會顯示收件人和完整內容讓你確認。'),
            const SizedBox(height: 18),
            FilledButton.icon(onPressed: controller.loading ? null : _create, icon: const Icon(Icons.add_rounded), label: const Text('建立故事卡'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
            const SizedBox(height: 16),
            if (controller.stories.isEmpty)
              const EmptyCard(icon: Icons.auto_stories_outlined, message: '目前沒有故事卡。你可以從幾段記憶開始整理。')
            else
              ...controller.stories.map((story) => StoryCard(story: story, onDelete: _delete)),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 14),
              ErrorBanner(message: controller.errorMessage!, onRetry: () => controller.refreshStories()),
            ],
          ],
        ),
      ),
    );
  }
}

class StoryDraft {
  const StoryDraft({required this.title, required this.content, required this.memoryIds});

  final String title;
  final String content;
  final List<String> memoryIds;
}

class StoryComposerDialog extends StatefulWidget {
  const StoryComposerDialog({required this.memories, super.key});

  final List<MemoryRecord> memories;

  @override
  State<StoryComposerDialog> createState() => _StoryComposerDialogState();
}

class _StoryComposerDialogState extends State<StoryComposerDialog> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _content = TextEditingController();
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('建立故事卡'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _title, decoration: const InputDecoration(labelText: '故事標題')),
              const SizedBox(height: 12),
              TextField(controller: _content, minLines: 4, maxLines: 8, decoration: const InputDecoration(labelText: '故事內容')),
              if (widget.memories.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Align(alignment: Alignment.centerLeft, child: Text('引用哪些記憶？', style: TextStyle(fontWeight: FontWeight.w700))),
                ...widget.memories.map((memory) => CheckboxListTile(
                      dense: true,
                      value: _selected.contains(memory.id),
                      onChanged: (value) => setState(() => value == true ? _selected.add(memory.id) : _selected.remove(memory.id)),
                      title: Text(memory.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                      controlAffinity: ListTileControlAffinity.leading,
                    )),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('返回')),
        FilledButton(
          onPressed: () {
            if (_title.text.trim().isEmpty || _content.text.trim().isEmpty) return;
            Navigator.pop(context, StoryDraft(title: _title.text, content: _content.text, memoryIds: _selected.toList()));
          },
          child: const Text('建立'),
        ),
      ],
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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(story.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(story.content, style: Theme.of(context).textTheme.bodyLarge),
          if (story.memoryIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('引用 ${story.memoryIds.length} 項記憶', style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: 9),
          Wrap(spacing: 8, children: [
            if (controller.familyMessageLinks.isNotEmpty)
              FilledButton.tonal(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FamilyMessagesScreen(initialStory: story))),
                child: const Text('分享給家庭成員'),
              ),
            TextButton(onPressed: controller.updatingStoryIds.contains(story.id) ? null : () => onDelete(story), child: const Text('刪除')),
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
      appBar: AppBar(title: const Text('生活資源')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text('找有來源的資料', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          const Text('資料會顯示查找方式、核實日期、適用條件和下一步。遇到資料差異時，請先查看提示。'),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _query,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(labelText: '例如：長者交通優惠', prefixIcon: Icon(Icons.search_rounded)),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(tooltip: '搜尋資源', onPressed: _search, icon: const Icon(Icons.search_rounded), style: IconButton.styleFrom(minimumSize: const Size(54, 54))),
          ]),
          if (controller.resourceRetrievalMode != null) ...[
            const SizedBox(height: 12),
            Text('查找方式：${_retrievalLabel(controller.resourceRetrievalMode)}', style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (controller.resourceConflicts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(color: const Color(0xFFFFF0D7), child: Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('資料之間有差異', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 7), ...controller.resourceConflicts.map((conflict) => Text(conflict.title.isEmpty ? conflict.summary : '${conflict.title}：${conflict.summary}'))]))),
          ],
          const SizedBox(height: 16),
          if (controller.resourceItems.isEmpty)
            const EmptyCard(icon: Icons.local_library_outlined, message: '輸入關鍵字後，資源會在這裡顯示。')
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
          const SizedBox(height: 7),
          Text(item.excerpt, style: Theme.of(context).textTheme.bodyLarge),
          if (item.verifiedAt != null || item.effectiveDate != null) ...[
            const SizedBox(height: 8),
            Text('核實：${_dateLabel(item.verifiedAt)}${item.effectiveDate == null ? '' : ' · 生效：${_dateLabel(item.effectiveDate)}'}', style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (item.conditions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('適用條件：${item.conditions.join('、')}', style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (item.missingInformation.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('仍需確認：${item.missingInformation.join('、')}', style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (item.nextSteps.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('下一步：${item.nextSteps.join('、')}', style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (item.url != null && item.url!.isNotEmpty) ...[
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SelectableText(item.url!, style: const TextStyle(color: Color(0xFF116466), decoration: TextDecoration.underline))),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () async {
                    final uri = Uri.tryParse(item.url!);
                    if (uri == null || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('暫時未能開啟來源連結。')));
                    }
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('開啟來源'),
                ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

class FamilyMessagesScreen extends ConsumerStatefulWidget {
  const FamilyMessagesScreen({this.initialStory, super.key});

  final StoryRecord? initialStory;

  @override
  ConsumerState<FamilyMessagesScreen> createState() => _FamilyMessagesScreenState();
}

class _FamilyMessagesScreenState extends ConsumerState<FamilyMessagesScreen> {
  final _contentController = TextEditingController();
  FamilyInvitation? _selected;
  bool _reviewing = false;

  @override
  void initState() {
    super.initState();
    final story = widget.initialStory;
    if (story != null) _contentController.text = '${story.title}\n${story.content}';
    Future<void>.microtask(() => ref.read(appControllerProvider).refreshFamilyMessages(silent: true));
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final controller = ref.read(appControllerProvider);
    final link = _selected;
    if (link == null || _contentController.text.trim().isEmpty) return;
    final ok = await controller.sendFamilyMessage(
      link: link,
      content: _contentController.text,
      sourceStory: widget.initialStory,
    );
    if (ok && mounted) {
      setState(() {
        _reviewing = false;
        if (widget.initialStory == null) _contentController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('家庭訊息已由伺服器發送。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final links = controller.familyMessageLinks.where((link) => controller.recipientIdFor(link) != null).toList();
    if (_selected == null || !links.contains(_selected)) {
      _selected = links.isEmpty ? null : links.first;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('家庭訊息')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Text('只傳給已授權的家人', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          const Text('長者私密聊天不會出現在這裡。每次發送前，你都會看到收件人和完整內容。'),
          const SizedBox(height: 18),
          if (links.isEmpty)
            const EmptyCard(icon: Icons.lock_outline_rounded, message: '目前沒有開啟「家庭訊息」的家庭連結。請由長者重新發出邀請並主動勾選這項權限。')
          else if (_reviewing)
            _FamilyMessageReview(link: _selected!, content: _contentController.text, story: widget.initialStory, onBack: () => setState(() => _reviewing = false), onConfirm: controller.loading ? null : _send)
          else ...[
            DropdownButtonFormField<FamilyInvitation>(
              initialValue: _selected,
              decoration: const InputDecoration(labelText: '收件人', prefixIcon: Icon(Icons.person_outline_rounded)),
              items: [for (final link in links) DropdownMenuItem(value: link, child: Text(controller.familyCounterpartLabel(link)))],
              onChanged: (value) => setState(() => _selected = value),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _contentController,
              readOnly: widget.initialStory != null,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: widget.initialStory == null ? '訊息內容' : '故事卡內容',
                helperText: widget.initialStory == null ? null : '分享故事卡時內容會保持原文，伺服器會再次核對故事版本。',
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(onPressed: controller.loading ? null : () => setState(() => _reviewing = true), icon: const Icon(Icons.visibility_outlined), label: const Text('檢視並確認發送'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54))),
          ],
          if (controller.familyMessages.isNotEmpty) ...[
            const SizedBox(height: 24),
            SectionTitle(title: '訊息記錄'),
            const SizedBox(height: 9),
            ...controller.familyMessages.map((message) => FamilyMessageCard(message: message, currentUserId: controller.user?.id)),
          ],
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 14),
            ErrorBanner(message: controller.errorMessage!, onRetry: () => controller.refreshFamilyMessages()),
          ],
        ],
      ),
    );
  }
}

class _FamilyMessageReview extends StatelessWidget {
  const _FamilyMessageReview({required this.link, required this.content, required this.story, required this.onBack, required this.onConfirm});

  final FamilyInvitation link;
  final String content;
  final StoryRecord? story;
  final VoidCallback onBack;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final controller = ProviderScope.containerOf(context).read(appControllerProvider);
    return Card(
      color: const Color(0xFFDDEDEA),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('請確認後才會發送', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text('收件人：${controller.familyCounterpartLabel(link)}', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 10),
          Container(width: double.infinity, padding: const EdgeInsets.all(13), color: Colors.white, child: Text(content, style: Theme.of(context).textTheme.bodyLarge)),
          if (story != null) ...[const SizedBox(height: 8), const Text('這是故事卡原文分享，服務會核對你仍擁有最新版本。')],
          const SizedBox(height: 14),
          Row(children: [Expanded(child: OutlinedButton(onPressed: onBack, child: const Text('返回編輯'))), const SizedBox(width: 10), Expanded(child: FilledButton(onPressed: onConfirm, child: const Text('確認發送')))]),
        ]),
      ),
    );
  }
}

class FamilyMessageCard extends StatelessWidget {
  const FamilyMessageCard({required this.message, required this.currentUserId, super.key});

  final FamilyMessage message;
  final String? currentUserId;

  @override
  Widget build(BuildContext context) {
    final mine = currentUserId != null && message.senderId == currentUserId;
    final sender = mine ? '你' : (message.senderName ?? '家庭成員');
    return Card(margin: const EdgeInsets.only(bottom: 9), child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 7), leading: Icon(mine ? Icons.outbox_rounded : Icons.inbox_rounded, color: const Color(0xFF116466)), title: Text(sender, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text(message.content, style: const TextStyle(fontSize: 17, height: 1.35))));
  }
}

String _dateLabel(DateTime? value) {
  if (value == null) return '未提供';
  return '${value.year}/${value.month}/${value.day}';
}

String _retrievalLabel(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'keyword':
    case 'lexical':
    case 'keyword_search':
      return '關鍵字查找';
    case 'hybrid':
    case 'hybrid_python':
    case 'hybrid_keyword_embedding':
    case 'hybrid_pgvector':
    case 'semantic_keyword':
    case 'vector_keyword':
      return '語意與關鍵字查找';
    case 'verified_registry':
    case 'official_registry':
      return '已核實資料查找';
    case 'local':
      return '你的已保存記憶';
    case 'deterministic_demo':
    case 'demo':
      return '示範資料';
    default:
      return '服務提供的查找結果';
  }
}

String _memoryKindLabel(String value) {
  switch (value.trim().toLowerCase()) {
    case 'fact':
      return '生活事實';
    case 'preference':
      return '喜好';
    case 'emotion':
      return '心情';
    case 'experience':
      return '生活經歷';
    default:
      return '生活記憶';
  }
}

class DemoModeLabel extends StatelessWidget {
  const DemoModeLabel({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: compact ? 5 : 8),
      decoration: BoxDecoration(color: const Color(0xFFFFE5C1), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.science_outlined, size: compact ? 16 : 19, color: const Color(0xFF8B4E2D)), const SizedBox(width: 6), Text('伺服器示範模式', style: TextStyle(fontSize: compact ? 12 : 15, fontWeight: FontWeight.w700, color: const Color(0xFF8B4E2D)))]),
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
            Expanded(child: Text(message, style: const TextStyle(color: Color(0xFF742817)))),
            if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('重試')),
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
    return Row(children: [Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)), if (action != null) Text(action!, style: Theme.of(context).textTheme.bodyMedium)]);
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
        padding: const EdgeInsets.all(24),
        child: Column(children: [Icon(icon, size: 42, color: const Color(0xFF116466)), const SizedBox(height: 12), Text(message, textAlign: TextAlign.center)]),
      ),
    );
  }
}
