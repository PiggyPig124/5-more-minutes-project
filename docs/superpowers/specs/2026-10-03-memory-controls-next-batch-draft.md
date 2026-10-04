# 记忆控制下一批最小方案（待实施，2026-10-03）

> 后续政策澄清：本文 Pending 是当时记录；用户现已明确选择开启 Memory 后普通非敏感偏好自动保存，无需逐项 Save。团队审核仍无完成证据。手动草稿、敏感/非偏好确认和家庭分享边界不变；[现行 SRS 适用说明](../../SRS_APPLICABILITY_MEM_AUTO_PREFERENCE.md)区分当前政策与未闭合的 legacy candidate 路径。

## 范围和依据

首个补丁只补齐“关闭记忆、查看已保存记忆、删除选中记忆、删除全部记忆”四个独立操作，以及 Save 前不落盘的 UI 契约。复用既有单条删除和删除关联内容的规则。不执行真实数据删除，不自动清理旧记录。Memory Card 创建和编辑作为紧接的第二个补丁，避免把删除原子性、卡片编辑版本和家庭分享三个流程捆绑。

依据：`reference documents/Echo_Software_Requirements_Specification_v1.1_Corrected (1).md` FR MEM 02（355 行起，Save 后才存储）、FR MEM 04/05（401/410 行起，编辑及四种控制分离）、FR MEM 06（427 行起，从确认记忆创建卡片）、§10.1/10.3（732/754 行起，默认私有和撤回后停止未来访问）。

## 第一个补丁的行为

1. 关闭记忆只停止后续收集与使用，不删除旧记录，保留查看和手动删除入口。删除成功不默默改变开关；界面明确说明继续开启时将来仍可通过允许的流程新增记忆。
2. “删除全部”覆盖当前账户全部持久化记忆，包括暂停、替代版本和旧 candidate；不能使用默认过滤掉旧版本的 GET /memories 列表来拼客户端循环删除。前台先展示删除范围和关联内容影响，用户明确确认后发送一个请求。
3. 后端一个 owner 锁、一个事务、一次提交。所有读取和删除写入 owner 条件，重构 `memory_service.py:745` 当前全表链扫描和 `:1040` 左右仅按 ID 删除的末端语句后再复用清理逻辑。删除相关 embedding、skill、派生故事及其家庭消息正文，并清除相关对话来源/上下文；独立且无关联记忆的故事、任务、任务分享和无关消息保留。
4. 使用账户内唯一请求键及最小删除收据，重试只返回原结果，不能再次删除重试期间新增的记忆。空库删除也增加 memory revision，阻止已在途的旧模型结果写回。继续保留阻止被删偏好重新捕获的 topic block；不以本批修改自动偏好产品行为。
5. 技能建议 GET 和技能确认当前也会写入数据库（`routers/community.py:194`、`:241`），需使用相同 owner guard；否则删除期间可能重新产生关联内容。并发的手动 Save/Confirm/Edit 需明确以锁顺序决定；删除确认开始后迟到的旧界面 Save 应由一致的 mutation revision/epoch 检查拒绝，不能仅依赖尚未由全部手动写入递增的旧 memory revision。
6. Flutter 增加记忆数据 mutation generation。删除和编辑开始时清理 memory/search、关联 stories/family messages 和推荐缓存，迟到的旧请求不能恢复正文；成功后重读服务器状态。会话切换及确认取消不能发 DELETE；403/409/5xx 不展示删除成功。
7. 新建或编辑建议的未保存草稿只驻留 RAM，不调用 `SessionStore.saveDraft` 或 legacy `POST /memories`。当前真实聊天 UI 已走 transient suggestion + explicit `/memories/save`；旧 candidate 端点仍被旧调用方和跨进程验收使用，退役应单独列出兼容迁移及验收更新，不能仅删接口或自动删历史 candidate。

## 首个补丁的验收

合成两个账户；混合 confirmed、paused、candidate、superseded、legacy deleted 记录及关联 embedding、skill、story、已分享消息；确认仅当前账户清空、关联副本正文被撤回、独立故事/任务保留。覆盖空库删除、同键超时重试后新 Save 保留、技能 GET/决定和在途模型的竞态、事务中途失败完整回滚。前端覆盖关闭不删除、取消不请求、双语小屏与大字、迟到加载不恢复内容及账号切换。先 RED，再定向、完整后端/Flutter及隔离真实 HTTP 验证。

## 第二个补丁：确认记忆到私人 Memory Card

从已确认且未暂停的记忆直接预填一个仅 RAM 草稿，明确保存后复用 Story/StoryMemoryLink。编辑保持卡片 ID 和来源引用，以服务端版本检查避免覆盖；共享出去的旧正文失效，新内容默认私有，需重新选择收件人和预览确认。不可在编辑时自动重发。无来源的独立故事保持独立；长卡片超过家庭消息长度限制时明确阻止发送，不静默截断。图片和语音字段暂缓到独立范围。

现状定位：`routers/memories.py:246` 列表过滤、`:415` 单条删除；`memory_service.py:1017` purge_memory；`app_controller.dart` 的 refreshMemories/refreshStories/refreshFamilyMessages 目前主要保护会话 generation，仍需增加数据变更 generation。本文件仅为方案，尚未新增删除接口、执行迁移或修改任何真实数据。


## 审查后的实施契约

此草案已由用户持续授权进入实施。严格版本屏障、同键删除收据、旧调用迁移及owner关联清理，以 `2026-10-03-memory-controls-implementation.md` 为准；上述文件同时列出顺序、归属、自审和验收条件。所有删除验证只使用合成隔离数据库。


## 首批状态更新（2026-10-03）

首批记忆控制已实现并完成完整回归与隔离 HTTP 验证，结果见 `2026-10-03-memory-controls-implementation.md` 的“首批实现与最终验证”。本文前面的现状定位与草案描述是实施前记录，不代表当前代码。第二批 Memory Card 编辑仍未实施；agent_auto 合规状态仍为 Pending。


## 第二批状态更新（2026-10-03）

私人Memory Card创建编辑已完成并冻结；前面的“第二个补丁”是实施前计划，最终契约及验证以 `2026-10-03-private-memory-card-design.md` 和 `../plans/2026-10-03-private-memory-card.md` 为准。无媒体、公开发布或自动偏好行为变更。
