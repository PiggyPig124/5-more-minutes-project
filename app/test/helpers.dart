import 'package:anxin_companion/src/api_client.dart';
import 'package:anxin_companion/src/models.dart';

class FakeApi implements AnxinApi {
  FakeApi({this.role = UserRole.elder});

  UserRole role;
  bool failSend = false;
  String? lastMessageClientId;
  String? lastActionClientId;
  int actionConfirmations = 0;
  final List<CareTask> fakeTasks = <CareTask>[];
  final List<FamilyInvitation> fakeInvitations = <FamilyInvitation>[];
  final List<FamilyInvitation> fakeLinks = <FamilyInvitation>[];
  final List<Conversation> fakeConversations = <Conversation>[];
  final Map<String, List<ChatMessage>> fakeMessages = <String, List<ChatMessage>>{};
  ActionProposal? fakeAction;

  AuthSession _session([UserRole? requestedRole]) => AuthSession(
        accessToken: 'fake-token',
        user: AppUser(
          id: requestedRole == UserRole.caregiver ? 'caregiver-1' : 'elder-1',
          displayName: requestedRole == UserRole.caregiver ? '照顧者' : '長者',
          email: requestedRole == UserRole.caregiver ? 'caregiver@example.com' : 'elder@example.com',
          role: requestedRole ?? role,
        ),
      );

  @override
  Future<AuthSession> register({required String email, required String password, required String displayName, required UserRole role}) async {
    this.role = role;
    return _session(role);
  }

  @override
  Future<AuthSession> login({required String email, required String password}) async => _session();

  @override
  Future<AppUser> currentUser() async => _session().user;

  @override
  Future<void> logout() async {}

  @override
  Future<List<Conversation>> listConversations() async => List.of(fakeConversations);

  @override
  Future<List<ChatMessage>> listMessages(String conversationId) async => List.of(fakeMessages[conversationId] ?? const []);

  @override
  Future<Conversation> createConversation({String? title}) async {
    final conversation = Conversation(id: 'conversation-1', title: title ?? '新對話');
    fakeConversations.insert(0, conversation);
    fakeMessages[conversation.id] = <ChatMessage>[];
    return conversation;
  }

  @override
  Future<SendMessageResult> sendMessage({required String conversationId, required String content, required String clientMessageId}) async {
    lastMessageClientId = clientMessageId;
    if (failSend) throw const ApiException('網絡暫時未能連接。');
    final user = ChatMessage(id: clientMessageId, conversationId: conversationId, body: content, isFromUser: true, createdAt: DateTime.now());
    final assistant = ChatMessage(id: 'assistant-$clientMessageId', conversationId: conversationId, body: '我聽到你了，我們可以慢慢來。', isFromUser: false, createdAt: DateTime.now());
    fakeMessages.putIfAbsent(conversationId, () => <ChatMessage>[]).addAll([user, assistant]);
    return SendMessageResult(userMessage: user, assistantMessage: assistant, action: fakeAction, demoMode: true);
  }

  @override
  Future<List<CareTask>> listTasks() async => List.of(fakeTasks);

  @override
  Future<CareTask> updateTask({required String taskId, required TaskStatus status}) async {
    final index = fakeTasks.indexWhere((task) => task.id == taskId);
    final updated = CareTask(id: taskId, title: fakeTasks[index].title, description: fakeTasks[index].description, status: status, dueAt: fakeTasks[index].dueAt);
    fakeTasks[index] = updated;
    return updated;
  }

  @override
  Future<CareTask?> confirmAction({required String actionId, required String clientActionId}) async {
    lastActionClientId = clientActionId;
    actionConfirmations += 1;
    return const CareTask(id: 'task-1', title: '覆診提醒', description: '記得帶同文件', status: TaskStatus.pending);
  }

  @override
  Future<void> dismissAction({required String actionId}) async {}

  @override
  Future<FamilyInvitation> createInvitation({required String email}) async {
    final invitation = FamilyInvitation(id: 'invitation-1', email: email, status: InvitationStatus.pending, token: 'token-for-test-123456');
    fakeInvitations.insert(0, invitation);
    return invitation;
  }

  @override
  Future<List<FamilyInvitation>> listInvitations() async => List.of(fakeInvitations);

  @override
  Future<List<FamilyInvitation>> listLinks() async => List.of(fakeLinks);

  @override
  Future<FamilyInvitation> acceptInvitation({required String invitationId, required String token}) async {
    final link = FamilyInvitation(id: 'link-1', email: 'elder@example.com', status: InvitationStatus.accepted);
    fakeLinks.insert(0, link);
    return link;
  }

  @override
  Future<void> revokeInvitation({required String invitationId}) async {}

  @override
  Future<void> revokeLink({required String linkId}) async {}

  @override
  Future<List<ActionProposal>> listActions(String conversationId) async => fakeAction == null ? const [] : [fakeAction!];
}
