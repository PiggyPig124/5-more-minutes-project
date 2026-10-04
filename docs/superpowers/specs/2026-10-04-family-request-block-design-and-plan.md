# Family Request and Block Implementation Plan / 家庭请求与封锁设计及计划

> **For agentic workers:** REQUIRED SUB-SKILL: 后续按任务使用 superpowers:executing-plans 或已获授权的 superpowers:subagent-driven-development。Steps use checkbox (`- [ ]`) syntax for tracking。本轮仅编写本文件，不实施、不提交、不操作真实账号；执行方式由主任务安排。

**Goal:** 完成 SRS FR FAM01 的长者批准、拒绝、移除及封锁，保证旧连接、token 和分享不会因解除封锁或重连复活。

**Architecture:** 保留长者主动邀请，新增照顾者入站申请。使用独立账户 pair 封锁记录、连接授权代次以及家庭消息永久撤权标记；复用 owner guard、TaskShare 撤销及卡片正文撤回机制。

**Tech Stack:** 现有 FastAPI、SQLAlchemy、SQLite 测试、Flutter/Riverpod；不增加模型调用或外部账号服务。

**Spec:** 本文件 §1–9 为设计，§10–12 为相应实施计划与验收；同一独立文档。

## Global Constraints

- 范围仅家庭连接，不涉及群聊、家庭回复、陪同请求或 SHOULD 功能。
- 仅长者对已确认账户 pair 封锁；不扩到照顾者封锁、邮箱封禁或换号追踪。
- 普通拒绝只终止当前请求；允许新请求，但旧 token 终态不可恢复。
- 解除封锁不恢复旧连接、旧 scopes、旧 token 或旧分享。
- 请求不授予权限；批准 scopes 必须长者显式选择，禁止照顾者代选或隐式默认。
- 旧分享不得自动重开；保留本人数据；无关 pair 不受影响。
- 只在临时合成数据库进行后续测试；不运行真实数据库升级、迁移或封锁。
- 本轮不写产品代码，不提交、推送、发布或安装依赖。

## Review Focus

1. 同名照顾者及输入错误邮箱：所有操作绑定稳定 account ID、pair 和请求 ID，不按显示名称猜身份（批次2/4）。
2. token 重试与批准/封锁交错：终态不激活，accepted token 不映射到后来的授权代次（批次2/3）。
3. 消息 scope 移除后再增加、连接移除后重连：旧消息和旧任务分享仍撤权（批次1/3）。
4. 网络结果不明、账户切换及迟到缓存：不假报成功，不自动改收件人或重试新授权（批次4）。
5. legacy 数据缺代次、重复启动及事务回滚：升级幂等且 fail closed，不能靠删除本人数据解决（批次1/5）。

## 1. 需求、批准依据与当前实现

修订 SRS `reference documents/Echo_Software_Requirements_Specification_v1.1_Corrected (1).md` §8.4、FR FAM01–03、§10.2/10.3：长者批准后连接才 active；长者可拒绝、移除或封锁；连接不开放私人聊天或完整记忆库；每次分享须显示内容和收件人。

本会话产品批准依据：主对话提出“保留长者主动邀请，也允许家属申请、由长者批准或拒绝；封锁后旧授权失效，解除封锁不会自动恢复连接或旧分享”，用户回答“行”。本次委托进一步明确 Global Constraints。这里只记录产品授权，不伪称团队签字、外部审核或已完成实施。

现有 `backend/app/routers/family.py`：elder 创建邮箱/token 邀请，caregiver 接受；FamilyLink 唯一 pair，接受可复用并重新激活旧 link；双方可移除。尚无入站申请、reject、block。

现有 `task_share_service.py`：`begin_guard` 锁长者，`revoke_shares` 永久撤销任务同意；重连不恢复。`family_messages.py` 依赖 active link/scope，当前重连同一 link 可使历史消息重新可见。`memory_service.py` 的卡片来源撤回会清除相关已分享正文。本设计要求这两类撤回叠加，互不覆盖。

## 2. 用户流程与身份

### 2.1 长者主动邀请

长者输入照顾者邮箱，查看授权说明并显式选择 scopes，确认“发送邀请”即长者对这份邀请的事先批准。caregiver 以目标账号及 token 接受，双方一致后 active。现有接口/别名保留，不把发邀请解释为分享全部任务或消息。

新建邀请仍可寄给尚未注册的邮箱，沿用现有机制；封锁不追踪未注册邮箱。创建时若邮箱已对应被该长者封锁的已确认 caregiver ID，应拒绝；接受时总是以实际账户 ID 重新检查封锁。原始 token 仅创建回执一次返回，持久存储摘要。

### 2.2 照顾者入站申请

caregiver 输入已注册长者邮箱并请求连接。服务端解析当前账户，不引入公开用户目录；不存在、角色错误、自身或不可用目标统一“无法发送请求”，不返回搜索到的 AccountPublic、私人内容或详细原因。成功回执只包含本人申请及自己输入的目标邮箱。

长者收到申请可查看申请人姓名、邮箱及权限说明，选择 Approve、Reject 或 Reject and block。同名人必须同时显示邮箱，不预选或自动替换身份；绑定 caregiver_id 不能因之后同名账号注册而改变。请求者不能给自己授权。

批准 scopes 初始全不勾选；仅允许 `care_tasks`、`family_messages`。至少一项显式选择后才能批准，空/未知 scope 返回422。请求 DTO 不接收可授予的 scopes（extra forbid）；请求表达意愿，长者作出授权。已有 active pair 不创建新申请（409一般状态），避免申请重试偷偷修改既有 scopes。

### 2.3 拒绝、移除、封锁与解除

- Reject：仅目标 elder 处理自己的 pending 入站申请；终态 rejected，重试幂等，不触及另一份既有连接。普通拒绝之后允许新申请。
- 发起人撤回 pending 请求/邀请：终态 revoked，与拒绝区分；对方批准该旧请求不得成功。
- Remove：保持双方移除能力；同事务撤销连接授权和旧分享，但不创建封锁。
- Block：仅 elder，目标必须来自其入站申请或其已有/历史 FamilyLink 的已确认 caregiver ID；不得凭任意账户ID创建跨人封锁。决定单向、该 pair 内家庭联系效果双向；不影响其他 pair 或对方账号。
- Unblock：仅该 elder 显式解除，二次说明“不恢复连接或以前分享”。解除后必须新邀请/新申请及批准才能重连。
- 一切 block/unblock 均由按钮和确认操作触发；模型、建议、后台刷新不得自动执行。

## 3. 最小数据契约

使用独立 `backend/app/family_connection_models.py`，避免把 caregiver 请求塞进当前方向固定的 FamilyInvitation。

| 实体 | 新增字段/约束 | 说明 |
|---|---|---|
| FamilyConnectionRequest | id、elder_id、caregiver_id、status、version、created_at、expires_at、decided_at；status=pending/approved/rejected/revoked/expired | 固定账户 pair；有效期7天；同 pair 只允许一份 pending，重复发起返回该申请；终态后允许新ID |
| FamilyBlock | elder_id/caregiver_id 联合主键、blocked_at、active、version | 永久记录事件身份；解除设active=false，不修改原账号或删除历史 |
| FamilyLink | `authorization_epoch` 正整数，旧行初始1 | 每次重新激活及 scopes 改动推进；不重置，不能代替 per-task 同意 |
| FamilyInvitation | `accepted_link_id`、`accepted_epoch` nullable | 新接受记录具体授权；旧 accepted token 只能重放原代次的有效连接 |
| FamilyMessage | `link_epoch` 正整数、`access_revoked_at`、`access_revocation_reason` nullable | 永久撤销接收方共享读取能力；原文留存，不因重新授权清空标记 |

保留现有 sender/client_message_id 唯一约束。FamilyMessage 的卡片正文已被来源撤回时，绝不从快照/来源恢复原文。消息撤权和正文脱敏是两个单调状态。

消息可见性：接收方需要该 pair 未封锁、active link、family_messages scope、当前 epoch 和 access_revoked_at为空。本人发送的数据允许本人管理；建议增加 `GET /family-messages/sent` 的 sender-only 回执视图，返回本人原文及撤权状态，不返回接收方私人资料；接收方不因这个接口读到撤回的旧消息。本人原文已被卡片撤回脱敏时，只返回现有脱敏内容。

## 4. 状态、token 与 API

请求状态转换仅 pending→approved/rejected/revoked/expired。新状态必须 explicit allowlist；其他值/unknown不能落入当前接受函数的默认激活分支。既有邀请 pending→accepted/revoked/expired；非pending仅允许安全重放，不允许重新授权。

| 接口（建议） | 操作者/输入 | 结果 |
|---|---|---|
| POST `/family-links/requests` | caregiver，elder_email，client_request_id | 201新申请；同key相同输入200回执，不同输入409；同pair pending返回原申请 |
| GET `/family-links/requests` | 已认证本人 | elder仅入站；caregiver仅本人发起；无token/聊天/记忆/完整账户对象 |
| POST `/family-links/requests/{id}/decision` | elder，decision=approve/reject，expected_version；approve要求scopes | approve产生link；reject仅终态；旧版本409 |
| POST `/family-links/requests/{id}/withdraw` | 原caregiver，expected_version | pending→revoked；自身重复幂等 |
| POST `/family-links/blocks` | elder，caregiver_id、来源request_id或link_id、client_operation_id | 同事务block+撤权；request来源时包含拒绝当前请求 |
| GET `/family-links/blocks` | elder | 仅本人名单及已有最少身份；不提供对方封锁名单 |
| POST `/family-links/blocks/{caregiver_id}/unblock` | 同elder，expected_version、client_operation_id | active=false；不改变连接/分享 |

决策/body采用 extra forbid。idempotency receipt绑定 actor、操作类型、目标ID、输入hash；同key同输入重放状态不触发授权，不同输入409。receipt必须在事务提交时一起写；可用独立小表FamilyConnectionOperation，不复用MemoryDeletionReceipt。授权类回执重放前仍验证当前pair/epoch，已撤权或被替代返回410，不能返回后来权限。block/unblock重试返回原操作身份和当前pair状态/版本，不回写旧状态。

所有现有接受入口：`/invitations/accept`、`/invitations/{id}/accept`、`/{id}/accept`共用同一accept服务。先校验认证caregiver、目标邮箱和token，再检查pair封锁和状态；blocked统一403“目前无法建立连接”，终态/过期410。accepted重试仅当accepted_link_id、accepted_epoch仍与当前有效且未封锁link一致时返回原回执；否则410，不返回后来的连接/权限。

所有family读写都以活数据库授权为准，登录JWT不携带永久family权限。wrong owner/陌生资源以404等一般结果拒绝，不披露存在性和封锁理由。成功的block详情只返回给发起elder，对方最多看到连接不可用。GET/错误回执不返回被封锁者私人聊天、记忆或新资料。

## 5. 撤权规则与事务

提供 `family_connection_service.py` 的公共内部契约：

- `begin_family_guard(db: Session, elder_id: str) -> None`：复用begin_guard，开始fresh事务并expire旧缓存。
- `pair_is_blocked(db: Session, elder_id: str, caregiver_id: str) -> bool`。
- `withdraw_family_access(db: Session, link: FamilyLink, reason: str) -> None`：revoke_shares；标记该link所有未撤权FamilyMessage；推进epoch；不commit。
- `approve_request(db, elder_id, request_id, expected_version, scopes) -> FamilyLink`。
- `set_pair_block(db, elder_id, caregiver_id, source_id, operation_id) -> FamilyBlock`。
- `clear_pair_block(db, elder_id, caregiver_id, expected_version, operation_id) -> FamilyBlock`。

锁序固定：elder Account owner guard → pair block（有则FOR UPDATE，无则owner mutex保护插入）→请求/邀请按ID排序→FamilyLink→TaskShare/FamilyMessage。终止该pair请求及邀请时顺序固定；不得先锁link/message再回头锁owner。所有同pair授权改变调用同一服务。

Block单事务：重新校验actor和目标pair → 写block → 终止该pair所有pending请求/邀请 → 撤权当前link和旧share/message、推进epoch → link.status=revoked → 写operation receipt → commit。查找邀请目标使用当前caregiver已确认邮箱，仅为关联现有记录，不创建邮箱封锁规则。

Remove同事务withdraw_family_access后revoked。family_messages scope被移除时永久撤权旧消息；care_tasks移除保留既有revoke_shares行为。重新连接或更新scopes推进epoch；新增family_messages权限不取消旧撤权标记。TaskShare的历史撤销标记不恢复。

消息发送（普通及Story来源）均先取得相同elder guard，再锁link并复核block、scope、epoch；story读取/全文检查仍在此事务，不能绕过owner→link顺序。卡片源owner必为elder；普通双向消息先只读解析pair，开始guard后重新读取身份和link。

消息重试先检查live授权及permanent撤权标记：已撤权或link_epoch不等于当前代次的旧client_message_id返回410，不当作新发送或新epoch写入；payload变化409。重新分享必须新key及完整新预览。

所有其他家庭发送入口（例如安全求助）复用这个授权检查，不能直接插入绕过标记/epoch。任务及通知保持active_share的live检查，增加pair blocked防御性检查，不对历史同意改为宽泛scope授权。

并发结局：block先赢→accept/share拒绝；accept/share先赢→block撤销刚产生的权限和站内分享。两种顺序完成后都不得保留有效分享。移除/封锁失败回滚时不允许只留block或只撤任务。同步路由在工作线程执行锁等待；异步路由使用已有run_in_threadpool seam，Session始终顺序使用，不重新引入SQLite事件循环阻塞。

## 6. Flutter及可用性

新增单独FamilyConnectionApi接口，API DTO不将请求/封锁塞进InvitationStatus.accepted。FamilyRequestStatus和FamilyBlockRecord独立；unknown/缺字段为不可操作。

Family页区分收到申请、发出邀请/申请、连接、封锁管理。每个动作绑定request/link ID、elder_id、caregiver_id、session和generation；同名身份同时显示邮箱。approve scopes全不勾选，不因后台更新换成另一人；block前确认影响，不询问私人理由。

固定中英文语义：

- “拒絕只結束這次申請；對方仍可提出新申請。” / “Reject ends this request. They may send a new request.”
- “封鎖會移除這個家庭連接，並停止雙方透過此連接傳送及查看已分享內容。” / “Block removes this family connection and stops sending and viewing shared content through it.”
- “解除封鎖不會恢復連接或以前的分享。重新連接需要新的邀請及批准。” / “Unblocking does not restore the connection or previous shares. Reconnecting needs a new invitation and approval.”

成功撤权即清相关links、消息/任务/通知缓存、收件人、分享预览和retry准备状态。开始mutating时阻止新分享，推进pair generation；晚返回不能补回旧授权。失败/超时保留原operation key，仅经用户再次操作重试同请求，不自动当成功或自动换key。账户切换清RAM及busy/error，旧finally不覆盖新session。

普通家庭收件箱隐藏已撤权incoming；本人发出历史标记已撤权，不能直接“一键重发旧分享”。若用户新分享仍要求重新连接、选择内容/收件人/完整预览和新key。

320px宽、2倍文字、中英都必须完整读到身份、scopes、撤权影响，并能滚动到approve/reject/block/cancel/unblock；键盘不遮挡确认。焦点/语义标签区分不同人的按钮；颜色不是唯一状态提示。

## 7. Legacy兼容与安全默认

仅设计 additive、可重复的升级；本轮不执行真实数据库操作。临时测试验证：

1. 现有active link初始epoch=1；对应旧消息link_epoch=1、撤权为空，保持原本已授权可见性；现有nonactive或没有family_messages scope的link旧消息置永久撤权，避免未来重连恢复。原文不删除。
2. 旧accepted invitation没有accepted_epoch，按失效处理（410），不凭当前link推测历史代次；不撤销目前active link。用户需新token操作。旧pending邀请维持原七天期限及邮箱绑定，接受时采用新block检查。
3. 旧来源卡片已脱敏正文原样保留，不通过回填恢复；TaskShare revoked状态原样保留。
4. 新schema/升级失败不得回退到“只看active link”的宽授权。启动应明确失败或家庭接口503；不得服务半升级隐私数据。
5. 同pair legacy重复pending记录保留审计并全部纳入block终止；创建服务在owner guard中只返回一份现有pending，不通过删除历史建立唯一约束。

当前 startup initialize_database 有手写additive升级模式；实现不得在尚未复核升级机制时运行生产URL。本地兼容测试包含老schema→升级→再次升级，数据及撤权不回退。

## 8. 排除与未决范围

已批准的方向、拒绝与封锁区别、pair作用范围、旧授权不复活及本人数据保留均不再提问。以下未由本方案承诺：邮箱换号防绕过、照顾者封锁、邀请邮件真实发送、联系人验证/账号恢复、骚扰冷却与速率政策、群聊、陪同/回复、离线设备或外部文件副本远程删除。

这些项不阻断本批；若执行中出现需要修改已批准政策的情况，回报具体冲突。真实PostgreSQL并发和实体设备必须单列未测，不能用SQLite/widget证据代替。scope并非共享内容，任何自动保存偏好仍不构成家庭分享。

## 9. 验收矩阵

| ID | 情景 | 必须结果 | 批次 |
|---|---|---|---|
| F01 | 长者主动邀请/照顾者接受 | 邮箱/token绑定；仅明示scopes；无自动task/card/history授权 | 2 |
| F02 | caregiver申请、elder批准/拒绝 | pending无权限；仅目标elder决定；批准scope全未选时拒绝 | 2 |
| F03 | 普通拒绝后新请求 | 旧请求终态410/409，新ID可提出，无自动连接 | 2 |
| F04 | 所有接受alias、旧token、未知状态 | 相同校验，终态不激活；旧accepted代次不返回新授权 | 2/3 |
| F05 | 同名/跨owner/错误角色/陌生target | 稳定ID绑定；无误封/误批；无私人信息泄露 | 2/4 |
| F06 | block已有link或pending request | 同pair全撤权，task/message/notification不可用；无关pair不变 | 3 |
| F07 | unblock及新连接 | 原link/scopes/token/share不恢复；新批准后只新分享可见 | 3 |
| F08 | scope移除/再加、remove/reconnect | 旧message标记和task撤权永久，sender本人数据仍可管理 | 1/3 |
| F09 | accept/share与block两种赢家 | 最终block有效，无有效旧分享，无500/死锁 | 3 |
| F10 | rollback故障注入 | block/link/request/share/message/epoch/receipt全部回滚 | 3 |
| F11 | 重试同key/改payload、旧message key | 合法幂等，无新授权；改payload409；已撤权key410 | 2/3 |
| F12 | 卡片编辑/删除与家庭撤权叠加 | 已脱敏正文不恢复；后来的新连接不复活旧card message | 3 |
| F13 | 网络不明/迟到读/切换账号 | 不假报成功或旧缓存复活，不对新账号清busy/写error | 4 |
| F14 | 320px、2倍文字、中英/键盘 | 身份、scopes、影响及全部动作可读可达 | 4 |
| F15 | legacy升级/重复启动/缺schema | 幂等保本人数据；nonactive历史撤权，旧accepted token失效；失败关闭家庭访问 | 1/5 |

## 10. 最小实施批次与文件归属

批次依次执行；授权服务/schema不得被多个任务同时改写。以下是未来实施文件，当前只创建本说明。

### 批次1：授权代次、消息永久撤权与兼容

**Files:** 新增 `backend/app/family_connection_models.py`、`backend/app/family_connection_service.py`；修改 `models.py`、`collaboration_models.py`、`db.py`、`routers/family_messages.py`；新增 `backend/tests/test_family_connection_legacy.py`、`test_family_message_withdrawal.py`。

**Interfaces:** 产生 §3 数据字段、`begin_family_guard`、`pair_is_blocked`、`withdraw_family_access`及sender-only历史DTO；后续批次调用，不自行复制撤权逻辑。

- [ ] RED：`test_reconnect_never_restores_incoming_message_but_preserves_sender_record`，断言重连incoming为空、sender原文和撤权标记保留；`test_removed_message_scope_never_restores_old_key`断言旧key410。
- [ ] 从backend运行 `python -m pytest tests/test_family_message_withdrawal.py tests/test_family_connection_legacy.py -q`，确认失败是缺契约/旧可见性，不是导入或环境错误。
- [ ] 实现 §3/5/7 的最小字段、升级和共享授权服务；卡片正文撤回保持现状。
- [ ] GREEN：上述测试通过；补oldschema重复升级、nonactive历史、缺schema503和脱敏原文不恢复，覆盖F08/F15。
- [ ] 检查仅该批次文件变化、原始文本未删除；独立读审后进入批次2，不提交真实数据操作。

### 批次2：入站申请、明确批准和拒绝终态

**Files:** 新增 `backend/app/routers/family_requests.py`、`backend/tests/test_family_requests.py`；修改 `main.py`注册路由、`family.py`共用接受服务、`schemas.py`契约；复用批次1服务。

**Interfaces:** 产生 §4 request API及`approve_request`；保留全部现有accept aliases，接受返回仍为FamilyLinkOut并补epoch。

- [ ] RED：`test_request_is_not_a_grant_and_only_target_elder_approves`、`test_reject_allows_new_request_without_reviving_old_id`、`test_approve_requires_explicit_nonempty_scopes`；断言pending无任务/消息可见、错人拒绝、空scope422。
- [ ] 运行 `python -m pytest tests/test_family_requests.py -q` 确认预期失败。
- [ ] 实现request创建/列表/决定/撤回、owner guard、version与operation receipt；邀请终态allowlist和accepted epoch安全重放。
- [ ] GREEN：含same-name稳定ID、unknown状态、全部aliases、错误邮箱/token、过期和幂等payload冲突；覆盖F01–F05/F11。
- [ ] 读审角色/方向矩阵和兼容返回体，未批准scope不落库，不把request当授权。

### 批次3：封锁、解除和所有家庭路径的原子撤权

**Files:** 新增 `backend/app/routers/family_blocks.py`、`backend/tests/test_family_blocks.py`；修改 `family_connection_service.py`、`routers/family.py`、`routers/family_messages.py`、`task_share_service.py`及实际家庭发送的 `routers/safety.py`（只改授权入口，不扩功能）。

**Interfaces:** 产生block/list/unblock API及`set_pair_block`/`clear_pair_block`；共享 §5 锁序和撤权helper。

- [ ] RED：`test_block_then_unblock_never_restores_old_authorization`、`test_accept_block_race_both_orders`、`test_share_block_race_both_orders`、`test_unrelated_pair_is_unchanged`。
- [ ] 运行 `python -m pytest tests/test_family_blocks.py -q`，观察旧实现缺block/旧token或分享复活的预期失败。
- [ ] 实现单事务block/解除/receipt；所有接受、创建、消息/卡片/安全发送入口统一重新检查。remove及scope变化调用同一撤权服务。
- [ ] GREEN：故障注入在任务撤权、消息标记、receipt写入后失败均全回滚；旧message key410、新连接只新share有效、卡片已脱敏不恢复；覆盖F06–F12。
- [ ] 运行既有 `test_family_messages.py`、`test_task_sharing.py`、`test_private_memory_cards.py`、`test_safety_hardening.py`；完成owner→link锁序审查，不移除现有live授权检查。

### 批次4：Flutter角色UI、缓存与失败反馈

**Files:** 修改 `app/lib/src/api_client.dart`、`models.dart`、`app_controller.dart`、`app.dart`；新增 `family_connections_screen.dart`及 `app/test/family_request_api_test.dart`、`family_connection_controller_test.dart`、`family_connection_widget_test.dart`。

**Interfaces:** `FamilyConnectionApi` 的create/list/decide/withdraw/block/listBlocks/unblock方法与 §4 一一对应；所有变更返回version，request/link/block DTO分开。controller操作捕获session/pair generation。

- [ ] RED：审批权限全未勾选、同名邮箱区分、拒绝与封锁不同确认、解除不自动重连；录入 §6 固定中英语义。
- [ ] 临时app副本运行 `flutter test --no-pub test/family_request_api_test.dart test/family_connection_controller_test.dart test/family_connection_widget_test.dart`，确认预期失败。
- [ ] 实现UI/API及pair缓存失效；sender-only历史显示撤权，无一键跳过新预览的重发。
- [ ] GREEN：晚读/晚写/超时同key/账户切换、recipient被撤销、320px2倍文字中英及键盘操作；覆盖F05/F13/F14。
- [ ] 静态分析通过；若source DTO缺必需字段，按钮禁用且说明刷新，不猜ID/role/status。

### 批次5：整体合同及证据冻结

**Files:** 新增 `acceptance/family_connection_acceptance.py`；仅必要调整既有合同测试以适应新增显式scopes及终态；记录本批实现证据于另获授权的报告，不修改SRS原文。

- [ ] 写F01–F15合同断言，synthetic SQLite和账户；不发送真实邀请/封锁，不调用模型。
- [ ] 全backend pytest、完整Flutter tests/analyze及已有HTTP合同通过；owned临时服务使用独立端口，停止自己创建的服务，不占主浏览器端口。
- [ ] 独立复跑accept/share-block交错及legacy，检查无500和旧分享复活；不以串行启动器掩盖并发故障。
- [ ] 实际UI走双方账号申请/批准/拒绝/封锁/解除/新连接/新分享，保留截图及API回执；不能用widget截图冒称真机。
- [ ] 冻结具体文件差异和逐项证据；未测PostgreSQL/实体设备如实列出。没有用户授权不提交、推送或发布。

## 11. 自审结论

- SRS明确的elder控制及本次批准政策均映射F01–F15和批次1–5。
- 删除/撤权/解除不相互混淆：原文保留与接收方永久失权同时成立；卡片脱敏永不逆转。
- 普通Reject仅当前请求终态，不暗中永久封锁；新请求不绕过active block。
- source/request/pair/epoch/operation ID在数据、API和测试保持一致；旧token不依靠当前pair推断新授权。
- 初始主动邀请仍代表明确elder批准；新入站批准不继承申请方scope；没有引入未经批准的照顾者封锁或追踪。
- 所有Review Focus均有对应测试批次；既有任务分享、来源撤回及SQLite线程修复作为不可回退约束。
- 仅此文档完成；checkbox未勾选代表尚未实施，不能将计划当作测试通过证据。

## 12. 文档交付与执行边界

这份设计已自审，可交主任务按最小批次安排实施。真实账号操作、真实数据库升级、外部邀请发送及部署不在本次文档授权内。用户关键政策已确认，不应重复询问；若新事实迫使改变作用对象、旧分享历史或权限默认，再提出具体冲突。

