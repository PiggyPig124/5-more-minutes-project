import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class MessageBubble extends StatelessWidget {
  const MessageBubble({required this.message, super.key});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
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
        child: Text(message.body, style: TextStyle(color: mine ? Colors.white : Colors.black87, fontSize: 18, height: 1.45)),
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

  @override
  void dispose() {
    _emailController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    if (_emailController.text.trim().isEmpty) return;
    final ok = await ref.read(appControllerProvider).createInvitation(_emailController.text);
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
        subtitle: Text('${invitation.email}\n${invitation.status.label}'),
        isThreeLine: true,
        trailing: onAccept != null
            ? TextButton(onPressed: onAccept, child: const Text('接受'))
            : onRevoke != null && invitation.status != InvitationStatus.revoked
                ? TextButton(onPressed: onRevoke, child: const Text('撤回'))
                : null,
      ),
    );
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
