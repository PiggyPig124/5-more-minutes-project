# Private Memory Card Implementation Plan

> 后续政策澄清：本文 Pending 是当时记录；用户现已明确选择开启 Memory 后普通非敏感偏好自动保存，无需逐项 Save。团队审核仍无完成证据。手动草稿、敏感/非偏好确认和家庭分享边界不变；[现行 SRS 适用说明](../../SRS_APPLICABILITY_MEM_AUTO_PREFERENCE.md)区分当前政策与未闭合的 legacy candidate 路径。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox tracking.

**Goal:** 确认记忆可明确保存私人卡片；编辑保留来源和ID并撤回旧站内分享。

**Architecture:** 复用Story及来源links，owner revision作为创建/编辑/分享屏障。前端捕获账号及草稿generation，不持久化草稿，不把旧正文套上新revision。

**Tech Stack:** FastAPI、SQLAlchemy、SQLite synthetic tests、Flutter/Dart既有依赖。

**Spec:** docs/superpowers/specs/2026-10-03-private-memory-card-design.md

## Global Constraints

- 不安装、提交、推送、部署；不碰真实数据库。
- 自动偏好保持现状 Pending。本批不接模型、不推断、不加媒体、独立 Answer Card 或公开发布。
- X-Memory-Revision缺失422、过期409。编辑不接受memory_ids字段。
- 卡片title <=240，content <=30000；家庭全文分享 <=10000字符，不截断。
- 所有删除、重启、HTTP验收仅合成临时SQLite，清除外部模型keys。

## Review Focus

- 来源缓存版本不一致，必须拒绝旧草稿而不是选择最新owner revision（T2/T3）。
- 保存自己推进generation时不能误丢失败RAM文本（T2/T3）。
- 账户在editor打开时切换，旧稿不能发给新账号（T2/T3）。
- 混合来源只失效一项，不能保留无依据的部分卡片（T1）。
- 编辑后站内旧分享被撤回，但原client message key不能重放（T1/T4）。

## 归属与接口

- Root: 本spec/plan、backend/app/routers/stories.py、backend/app/memory_service.py的撤回helper封装、全量整合验证/记录。不改其他agent文件。
- API agent: app/lib/src/api_client.dart、app/test/private_memory_card_api_test.dart、app/test/private_memory_card_live_test.dart。新增可选StoryEditApi，不改MemoryControlApi。
- Controller agent: app/lib/src/app_controller.dart、app/test/private_memory_card_controller_test.dart。产出spec规定MemoryCardDraft与四个接口；模型API仅消费StoryEditApi。
- UI agent: app/lib/src/app.dart、必要app/lib/src/memory_controls_panel.dart、app/test/private_memory_card_widget_test.dart。消费控制器草稿接口，不改controller/API。
- Backend test agent: backend/tests/test_private_memory_cards.py，只合成tests、不得改产品。独立review agent只读。
- 所有agent先阅读本spec+plan，确认接口后RED→GREEN，禁止交叉ownership。

### T1: 卡片PATCH与撤回事务

- [x] 测试agent写test_patch_preserves_id_sources_and_withdraws_old_share：assert PATCH200、sameID、same来源、新revision、旧FamilyMessage tombstone、普通消息不变。
- [x] 写test_patch_revision_and_source_boundaries：缺422旧409、crossowner403、mixed candidate/paused/deleted/superseded/foreign400、extra memory_ids422；创建duplicate IDs422。
- [x] 写test_patch_share_races_and_rollback：owner锁两个赢家、旧share/key不复活、注入失败revision/正文/消息/links全不变。
- [x] Root运行 `run_memory_action_tests.ps1 -Target tests/test_private_memory_cards.py` 观察404/405等真实RED。
- [x] Root实现 `patch_story(... expected_revision: int | None = Header(...)) -> StoryOut`；复用 `_confirmed_memory_ids`、撤回helper，单commit。
- [x] 重跑定向GREEN；保留既有 memory action withdrawal9回归。

### T2: API与RAM草稿控制器

- [x] API agent先测PATCH只传title/content和原header、响应sameID/revision验证、长度限制；观察RED再新增StoryEditApi。
- [x] Controller agent先测prepareMemoryCardDraft仅confirmed当前来源，原文RAM；prepareStoryEditDraft保持sourceIDs；save显式捕获版本、编辑更新sameID。
- [x] 覆盖cancel无写、null/mixed revision、账号切换、generation迟到结果、删除源、timeout/5xx和409不替换revision；观察RED再实现四接口。
- [x] 定向Flutter test与analyze，冻结owned文件并告知接口变化（不得暗改接口）。

### T3: 私人卡片创建/编辑UI

- [x] UI agent先测确认记忆入口预填、Save前无写、cancel零写、editor来源不可移除、成功才关闭。
- [x] 测英/繁中320px2×、超长全文分享不发送、旧分享撤回提示、失败RAM保留、账号/删除源失效关闭。
- [x] RED后复用composer接入draft四接口；大段UI若需拆分仅新的private_memory_card_editor.dart归UIowner并先通知root。
- [x] 定向widget和analyze通过，不修改无关legacy预期来掩盖失败。

### T4: 整合、HTTP、复审和冻结

- [x] API agent新增live test：saveMemory -> createStory -> share -> patch -> recipient旧正文tombstone -> freshpreview/newkeyshare，旧version/key409；off不擅改独立分享。
- [x] Root独立只读检查ownership/interface、self-review spec覆盖；review agent审实际代码与竞态，不重复全套。
- [x] Root完整后端pytest、Flutter test/analyze、既有4项+本批HTTP、四组119/62/34/16隔离验收；修复实际失败后再验证。
- [x] 写实际RED/GREEN、最终计数、限制和未实测边界；git diff --check；产品冻结报告，无commit/push。

## 自审（实施前）

来源、修改权限、owner锁、revision、事务撤回、不可移除来源、账号和mutation、RAM失败、长度、小屏、HTTP和无关数据保留均映射到T1–T4；API命名/签名一致。关闭仅停收集，人工管理既存卡片不隐式变更consent。无占位项；不要求新DB表或真实迁移。按用户已明确指定的方法直接实施，不再重复请求授权。


## 完成记录

T1–T4已完成，独立复审无阻断。最终后端322、Flutter312、HTTP5、隔离验收119/62/34/16通过；实际证据与边界见对应spec的“实施闭合与冻结”。所有代码保持未提交；无真实数据操作。
