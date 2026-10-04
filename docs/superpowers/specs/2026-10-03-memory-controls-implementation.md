# 记忆四控制实施契约与计划（2026-10-03）

> 后续政策澄清：本文 Pending 是当时记录；用户现已明确选择开启 Memory 后普通非敏感偏好自动保存，无需逐项 Save。团队审核仍无完成证据。手动草稿、敏感/非偏好确认和家庭分享边界不变；[现行 SRS 适用说明](../../SRS_APPLICABILITY_MEM_AUTO_PREFERENCE.md)区分当前政策与未闭合的 legacy candidate 路径。

## 已审查的范围

关闭、查看、删除选中、删除全部四操作分开。关闭停止记忆采集、检索和个性化，不删除且本人仍可管理；删除不改开关。关联清理仅依赖明确来源，不由模型猜相似副本。手动建议和编辑草稿 Save 前仅 RAM；agent_auto 偏好为保留例外，产品符合性标为 Pending，不宣称 SRS Save 前不持久化全满足。保留当前自动偏好行为，不做卡片编辑、媒体和发布。

## HTTP 和事务契约

- GET `/memories/control-state`：`{enabled, revision, counts}`，total 包括隐藏/旧记录，current 是可管理的当前锚。MemoryOut、StoryOut、SkillOut 和 ConsentOut 增加 revision，原列表形状保持。
- memory consent/create/save/patch/confirm/legacy delete、skill suggestions GET（会写）/decision、所有 story create/delete，以及有 source_story_id 的 family share，提交读取时捕获的 `X-Memory-Revision`。缺失 422，过时 409；禁止旧客户端默认采用当前版本。游客/照顾者权限在版本校验前检查。普通无来源家庭消息保持接口。
- 新 POST `/memories/deletions`：`{mode:all|selected, memory_ids, expected_revision, idempotency_key}`。selected 只接受本人当前锚、非重复非空 ID；all 无 ID。收据无正文，仅 request_id、revision 和删除计数。旧 DELETE /memories/{id} 需 revision + Idempotency-Key，保留 204，复用同一事务服务。
- owner 锁内先查 `(owner,key hash)` 收据。同键同请求直接重放原结果，不先检查 revision 或已消失锚；异请求 409。首次才检查 revision 和锚。范围查询、清理、版本推进和收据一个事务、一次 commit；任一错误 rollback。
- 每个相关记忆写和开关操作推进 owner revision，空库删除也推进。owner revision 从所有个人聊天/问候读取可清理历史上下文前捕获，生成后在同 owner guard 内无条件重验；包括 memory off、on 无检索结果。过时 409，回复、建议、auto、滚动上下文均不写，不以重跑模型掩盖。
- 延迟 retrieval/embed 返回时核验 owner revision 和记录状态，不重建被删 embedding。所有锁顺序 owner→相关行；Postgres owner 使用 FOR NO KEY UPDATE，SQLite BEGIN IMMEDIATE。真实 Postgres 此批不实测。
- selected 从当前锚向历史替代链扩展，链查询和最终 DELETE 全部限制 owner。旧页指向 superseded 项拒绝并要求重新核对。all 包括所有历史状态。
- 删除相关 embedding、skill、整张派生 story 及链接；source_story_id 对应家庭消息正文变撤回占位，保留必要 ID。清理本人对话明确来源、相关正文和滚动上下文。不删除独立 story、无关家庭消息和独立确认 task/taskshare。收据、revision、topic hash 可保留；不承诺设备/备份/供应商副本被删。

## 客户端与兼容迁移

可选 MemoryControlApi 承载严格版本化能力，旧 FakeApi 不因基础接口增加参数全部失效。真实 API 不自动获取新版本来提交旧 draft：控件、记忆行、技能、故事等捕获读取版本，409 要重新读取和重新确认。取消不请求也不清缓存；确认提交后隐藏关联内容。超时无假成功，保留请求 key 和原摘要重试，结果不确定前不重现内容。mutation generation 涵盖 memory/search/story/family messages/recommendations 和账户切换。

所有 backend test/acceptance/live client 调用方迁移为显式取版本、带版本提交。顺序合成 fixture 可用测试 helper；竞态场景必须提前捕获版本，不用自动刷新掩盖 stale 行为。legacy candidate 仍支持明确人工旧调用，但要求版本；旧记录不自动迁移或清理，全删纳入。

## 实施顺序与文件归属

1. Root 补 spec/plan并自审，然后 RED：删除、隐藏历史/owner链、receipt retry/冲突、空库、rollback、missing/stale、embedding。
2. Root：memory_models.py（最小收据）、memory_service.py（guard/revision/owner purge）、routers/memories.py（state/严格写/删除）。
3. task_sharing_backend：conversations.py、check_ins.py 和 generation fence tests，先 RED 后 GREEN。
4. catalog_review：community.py、stories.py、family_messages.py、schemas.py SkillOut，独立 related revision tests，先 RED 后 GREEN。
5. catalog_next_design：Flutter api_client.dart、models.dart 与独立 API/model tests。
6. catalog_frontend：backend tests/acceptance版本迁移；明确隔离 fixture，不改生产。
7. Root 或新独立代理：Flutter app_controller.dart、记忆控制 widget/app.dart与controller/widget tests，先 RED 后 GREEN；其他代理不得触及这些文件。
8. 合并后定向回归，再完整 pytest/Flutter/analyze，最后本地临时 SQLite HTTP验收与进程重启。所有工具命令注入临时 DATABASE_URL、清外部 provider keys；不启动真实 DB，不对真实用户数据 DELETE。

## 自审与固定验收

已检查基线：chat off 不核验版本、greeting 空sources不核验、owner链全库扫描、purge裸 ID、Save/Create不 bump、skill GET隐式写和前端仅session generation均需修；不能将现有实现误称新实现已满足。全批安全完成条件：两账户混合状态、无关数据保留；关不删/删不关；替代链/隐藏/空库/同键/异请求/事务回滚；全部写路径和模型/retrieval/embed竞态；游客/照顾者/跨账户拒绝；403/409/5xx/timeout/cancel；繁中英文320px大字。未来真实DB迁移、Postgres并发和实机验证只记录为限制。


## 首批实现与最终验证（2026-10-03）

首批已实现：独立的关闭、查看、删除选中、删除全部；按 owner 的 revision 屏障；原请求幂等删除回执；关联数据撤销；前端确认、取消、超时隔离与同 key 重试。真实调用方及旧测试已显式迁移 revision，不自动替旧草稿刷新版本。后续 Memory Card 编辑不在本批范围。

独立复审发现并修复：异步搜索原版本丢失；删除后历史行动迟到回填；缺失捕获版本的记忆/故事草稿误用新版本；旧家庭发送操作清除新操作忙碌状态。相关回归均先观察 RED，再验证 GREEN。故事创建在状态缺失时要求先刷新、再重新点击，不继续旧草稿。

最终验证结果：

- 后端完整 pytest：270 passed，1 条既有 Starlette/AnyIO 警告；日志 `C:\Users\Administrator\Documents\Codex\2026-10-03\task\memory-full-final.log`。
- Flutter 完整测试：233 passed，4 skipped；四项跳过仅因默认关闭真实 HTTP 标志，已另行全部通过。日志 `C:\Users\Administrator\Documents\Codex\2026-10-03\task\memory-flutter-complete.log`。
- Flutter analyze：No issues found。使用已有缓存 Flutter tools snapshot，`--no-pub --no-version-check`，未安装软件。
- 临时 SQLite + 自有 localhost HTTP：4/4 passed；包含删除回执重放不删除期间新保存记录、旧 Save 409、关闭保留历史、删除保留开关。临时后端进程已停止。
- 隔离验收：foundation 119、interim API 62、Echo phase 1 34、interim restart 16；全部零失败。日志 `C:\Users\Administrator\Documents\Codex\2026-10-03\task\review_acceptance_memory_migration.log`。
- `git diff --check` 通过。前端控制器复审回归所在五文件 59/59、双语 widget 两文件 18/18 已通过；完整测试在这些最终修复后再次通过。

所有服务/删除/重启验证仅使用合成数据和临时 SQLite，清除外部模型及语音服务密钥。未启动真实数据库、未执行真实数据库迁移、未删除真实用户数据、未提交或推送代码、未部署。真实 PostgreSQL 并发与真机行为尚未实测；不承诺设备、备份或服务商副本删除。agent_auto 仍保留既有例外，合规标记 Pending，不宣称原 SRS 的所有 Save 前无持久化要求已经满足。


## 独立复审 P1：删除后行动提案复活阻断（2026-10-03）

复现：明确 `source_memory_ids` + `action_id` 的 assistant 回复被撤回后，关联未执行 ActionProposal 的旧 payload 仍可通过 actions GET 读取，并由 confirm 创建新 Task。新增 `backend/tests/test_memory_action_withdrawal.py`，修改生产代码前观察到 4 failed / 4 passed；其中 selected/all、重启和 delete-first 确认均真实复现漏洞。

最小修复仅在 `memory_service.py` 和 `routers/actions.py`：同一记忆清理事务中，根据明确来源的 assistant 回复 action_id，同 owner、同 conversation、未执行且无 result_task_id 的 proposal 清 payload，持久化 status=invalidated，移除已失效 action_id。文本相似不作为依赖证据。confirm/dismiss 均统一 owner -> action 锁顺序，并对 invalidated 返回409。已独立确认的 Task/TaskShare、无明确来源的 proposal 和其他账户记录保留。

定向回归最终9/9通过，包含重新读取、直接确认、选中及全量删除、新应用及独立 Python 进程重启、删除先赢/确认先赢 SQLite 并发、事务中途异常回滚及同key重试、foreign/无来源提案保留、既有Task/TaskShare仍可被授权家人读取。独立只读复审未发现实际阻断；真实 PostgreSQL 并发仍未实测。

本次补丁后的完整验证取代上一节的后端计数：279 passed（1条既有Starlette/AnyIO警告），Flutter 233 passed / 4 default skipped，四项真实HTTP另行全部通过；analyze无问题；foundation119、interim API62、Echo phase1 34、interim restart16均零失败；git diff --check通过。日志位于 `C:\Users\Administrator\Documents\Codex\2026-10-03\task` 的 `memory-action-full-backend.log`、`memory-action-full-flutter.log`、`memory-action-live.log`、`memory-action-acceptance.log`。

原独立诊断已合法只读取得；直接从原Temp路径运行时 pytest 目录收集碰到 Windows 临时 socket 文件，属于收集错误，随后将原文件原样复制到隔离工作目录运行。产品代码保持冻结，未实施下一批Memory Card编辑；无真实数据库操作、提交、推送或部署。

原始独立诊断在隔离工作目录运行结果：1 passed；日志 memory-action-original-diagnostic-retry.log。
