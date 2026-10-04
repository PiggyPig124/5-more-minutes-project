# Private Memory Card 增量规格（2026-10-03）

> 后续政策澄清：本文 Pending 是当时记录；用户现已明确选择开启 Memory 后普通非敏感偏好自动保存，无需逐项 Save。团队审核仍无完成证据。手动草稿、敏感/非偏好确认和家庭分享边界不变；[现行 SRS 适用说明](../../SRS_APPLICABILITY_MEM_AUTO_PREFERENCE.md)区分当前政策与未闭合的 legacy candidate 路径。

## 目标与授权

按持续授权，完成确认记忆 -> 私人卡片创建编辑。复用 Story/StoryMemoryLink 与既有全文家庭预览、发送、撤回。不安装、提交、推送、部署；不碰真实数据库。自动偏好保持现状 Pending。本批不接模型、不推断、不加媒体、独立 Answer Card 或公开发布。

## SRS 映射

来源：reference documents/Echo_Software_Requirements_Specification_v1.1_Corrected (1).md。

| 条款 | 本批行为 |
|---|---|
| FR MEM 06（§9.3） | 从 confirmed 未暂停记忆预填 RAM 草稿，明确 Save 后创建私人卡片 |
| FR MEM 02、04 | 不创建 candidate；卡片编辑独立于原记忆编辑，来源不变 |
| FR MEM 05 | 原四操作保持；删除来源撤回整张关联卡与相关站内分享 |
| FR FAM 02、03、AT05 | 家人无私人卡权限；先完整内容及确定收件人预览，再明确发送 |
| §10.1–10.4 | 默认私人、来源透明、旧分享可撤回；不承诺设备副本删除 |
| §11.1、§17步骤6/8 | 英/繁中320px、2×字可创建编辑分享 |

这是一批局部补全，不宣称 FR MEM02/AT03 的既有 agent_auto 例外已合规。

## 数据和来源

Story.id、owner_id、title、content及 StoryMemoryLink 不增加新表。API使用content，UI展示正文。创建用既有 POST /stories，memory_ids最多50项、必须唯一；真实用户草稿只能显式附上捕获的 X-Memory-Revision。独立故事可无来源，维持既有行为。

每项来源必须同 owner、status confirmed、suppressed false、superseded_by NULL、deleted_at NULL。任意项不合格，整次拒绝（现有400）；重复IDs422。不取当前替换版本、不删掉不合格项继续保存。编辑不接受memory_ids字段；保留所有原来源、卡片ID和created_at。旧独立故事仍无来源，不强加来源。

## 编辑 API 与事务

PATCH /stories/{story_id}，JSON仅title和content，两项必填；extra forbid，trim空白后非空，title <=240，content <=30000。X-Memory-Revision缺失422、过期409，非本人403、缺卡404；在owner guard内统一验证。

顺序：owner guard -> require captured revision -> owner story -> 读取所有原source links -> 全部来源校验 -> title/content update -> 撤回该卡已有 FamilyMessage正文（只source_story_id匹配且sender_id=owner）-> bump owner revision -> flush并构造带revision响应 -> 一个commit。用现有撤回helper复用过滤语义，不用purge_stories删除卡/links。即使原文相同的明确PATCH，也视为一次编辑撤回旧分享并推进revision。不把正文存入审计/回执。

异常回滚所有上述变化。无关卡片、任务、TaskShare和普通家庭消息保持。编辑先赢则旧share409；share先赢则编辑撤回其站内正文。新卡正文默认私人，不自动重发，重发必须重新预览和确认、使用新发送编号；旧编号和旧正文不能复活。关闭记忆不关闭用户对已存卡片的独立管理/分享，状态关闭不变，不进行新记忆收集。

## Flutter 接口与边界

API追加可选 StoryEditApi（不扩展既有FakeApi核心接口）：updateStoryAtRevision(String storyId, {required String title, required String content, required int expectedRevision}) -> Future<StoryRecord>。RestApiClient实现并发送原X-Memory-Revision，返回同卡ID与新revision。未知/非法响应不能报成功。

控制器提供RAM MemoryCardDraft和以下统一接口：prepareMemoryCardDraft(MemoryRecord) -> MemoryCardDraft?；prepareStoryEditDraft(StoryRecord) -> MemoryCardDraft?；isMemoryCardDraftCurrent(MemoryCardDraft) -> bool；saveMemoryCardDraft(MemoryCardDraft, {required String title, required String content}) -> Future<bool>。Draft含owner、session、mutation/operation generation、captured revision、可空storyId、title、content、不可改source IDs。来源记忆预填标题用原文首段截取最多240字符，正文原文，不调用模型。编辑原title/content，不改变source IDs。

Draft仅RAM，无SessionStore.saveDraft、数据库候选或浏览器持久化。取消零写请求；账户切换、来源/卡删除、不同操作generation使旧draft失效，关闭正文预览且清RAM。草稿打开前确保捕获非空版本；缺失时刷新并要求新点击，不继续旧点击。提交前以及await后校验owner/session/operation，不能将旧响应填进新账号，也不能把旧稿发给新账号。

保存中的自身generation变化不误清正文；403/409明确失败不报成功，不换draft版本重发。网络超时/5xx不报成功，RAM编辑文本保留、原revision保留；禁止自动重建或自动重交。需要重新读服务器核对结果；只有用户明确重新打开的全新预览可绑定新revision。成功后更新卡片同ID、清旧family cache并刷新，所有迟到读不得回填旧卡/分享。

UI复用StoryComposerDialog实现新建/编辑、完整来源列表，记忆条目增加“建立记忆卡”，卡片增加“编辑”，明确私人、Save/Back。保存失败不关闭editor假装成功。关闭/清除失效draft时不保留旧敏感正文。编辑保存前说明旧站内分享正文会撤回，新正文需要再次选择收件人确认。

完整title+'\n'+content分享超过10000字符时客户端明确阻止，不能截断或发送；API仍按既有长度限制拒绝。英/繁中320px、2×字体可滚动访问所有动作和长来源正文。

## 验收与冻结

后端：创建/编辑本人合格来源；ID/source links不变；mixed source任一candidate/paused/deleted/superseded/foreign整次拒绝；重复IDs；missing422/stale409；预览后来源变更；edit-share双顺序；同旧发送编号失败；站内旧正文撤回；关闭记忆仍可独立管理分享；无关数据保留；注入事务中途失败全部回滚。

前端：RAM预填、取消零请求、Save明确一条请求、不推断；原版本/header；跨账号/迟到请求不污染；删除来源清draft；旧revision不换新重交；超时/5xx保留RAM、不报成功；sameID编辑缓存；超10000字符拦截；英/繁中320px2×；真实HTTP创建编辑撤回并重新预览分享。

按TDD先RED再GREEN。定向后完整pytest、Flutter test/analyze、4项既有HTTP+本批HTTP及119/62/34/16验收（仅临时SQLite，外部keys清除）；独立只读审查实际阻断闭合后冻结报告。真实Postgres并发和真机仍明确未实测。


## 实施闭合与冻结（2026-10-03）

已实现且冻结：确认记忆原文RAM预填私人卡片、明确Save、原卡编辑、来源ID保留、严格captured revision、单事务撤回旧站内分享、重新选择收件人及完整预览后新编号分享。手写独立故事也绑定原账号/session/generation，失败保留RAM；没有模型生成、推断、媒体、Answer Card或公开发布，自动偏好仍Pending。

TDD证据：后端新增43项（初始35failed/7passed，最终43passed）；API32项（15初始缺方法RED，另16条畸形成功响应RED）；控制器21新+26旧=47通过；私人卡片widget26项通过。独立复审发现保存后源缓存无法再次编辑、畸形2xx误报成功两项P2，均补RED→GREEN；同时闭合手写草稿跨账号、家庭预览失效/收件人替换空值崩溃，以及繁中320px2×字体下拉框溢出。英/繁中创建、编辑、完整分享预览的动作可访问，未做真机人工审计。

最终验证：

- 完整后端 pytest：322 passed，2条依赖弃用警告；`private-card-full-backend.log`。
- 完整Flutter：312 passed / 5默认live跳过；`private-card-final-full-flutter.log`。
- 五项真实HTTP合同均另行通过，包含卡片创建、旧分享撤回、新分享以及原版本/旧编号拒绝；`private-card-final-http.log`。使用临时SQLite、自有localhost、`--concurrency=1`，后端进程已停止。
- 四组隔离验收：foundation119、interim API62、Echo phase1 34、interim restart16，全零失败；`private-card-acceptance.log`。
- 最终Flutter analyze：No issues found；git diff --check通过。
- 独立只读复审批准，无未解决阻断；`private-card-review-report.md`。全量测试由root实际运行，审阅者未重复测试。

日志和报告位置：`C:\Users\Administrator\Documents\Codex\2026-10-03\task`。产品改动文件：backend/app/routers/stories.py、memory_service.py（撤回helper）；app/lib/src/api_client.dart、app_controller.dart、app.dart。新增测试分别为 test_private_memory_cards.py、private_memory_card_api_test.dart、private_memory_card_controller_test.dart、private_memory_card_widget_test.dart、private_memory_card_live_test.dart。

实施取舍已显式记录：按用户指定并行代理，以文件归属避免冲突；沿用已授权功能分支及既有未提交工作，用本批前后快照审查；SQLite取出的创建时间缺tzinfo，API统一UTC序列化而未改数据库值；缺来源测试用合成dangling link验证400，真实API删除仍走purge/revision，不新增卡片来源snapshot表。没有提交、推送、安装、部署、真实数据库启动/迁移/删除或外部模型调用。

限制：成功Save后若来源刷新读失败，保存仍确认成功，用户可能需下拉刷新再创建/编辑；不会将旧稿套用新revision。真实PostgreSQL并发、真机尚未实测。共享一个SQLite数据库并行运行独立HTTP测试文件时，旧异步memory-confirm接口曾返回500/database-is-locked（失败测试live_api_test.dart personal-data contract，日志private-card-live-parallel-server.log）；本批独立HTTP合同顺序全部通过，卡片edit/share两个真实owner锁顺序专项通过，但不宣称已经修复部署环境中该旧接口的SQLite并发问题。没有扩大到批次外数据库运行时改造，也不承诺设备/备份/服务商副本删除。
