# 答案卡 Flutter 双入口与私人管理验收

日期：2026-10-04。本批为双模式方案 T3，并包含独立冻结的两项后端 P2 修复。原始 SRS 未修改；不代表整个方案或比赛交付已经完成。

## 已实现行为

- 长者、照顾者、访客首页均可进入答案卡。完成的 AI 回复提供“制作答案卡”入口；用户消息和进行中的消息没有此入口。
- AI 模式仅准备当前回复，所有段落和来源默认不选，不自动带入记忆、任务或检索正文。用户勾选后可删改摘录，原文保留于当前编辑页面 RAM；最终预览和私人保存仅含所选、编辑后的正文。
- 公共模板入口读取三份已审核中文模板，保留打开时的 template_id/version/hash、来源日期及核验范围；不填入推测日期。英文界面明确说明模板内容为中文，英文全文尚未审核。
- 注册用户可完整预览后明确私人保存，并在自己的列表查看、编辑、删除；创建、修改、删除回执均检查身份、版本、正文和来源。卡片是独立副本，删除原对话不代表删除卡片。访客草稿只在 RAM，不能私人保存，登录不会自动导入。
- 取消、返回、账户切换会清理草稿、预览、编辑控件和旧页面；普通聊天通知不清除同一会话草稿。旧网络响应不能恢复原文、覆盖新草稿、清除新账户忙碌状态或弹出新页面。其他页面确认删除卡片后，已经打开的旧详情立即退役。
- 保存/删除重复点击仅发一个请求。结果未知时保留相同操作编号和版本供用户明确重试，无自动重试。未知删除经过列表刷新仍保留该卡的原快照，避免界面悄悄改用新版删除；确认回执到达后清除原快照和正文。已知 409/410 删除冲突仅在用户明确重新加载成功后解除旧操作，再审阅新版。

## 后端 P2 与来源规则

生产回复现在记录内部 resource_source_bindings，将资源 ID 与已审核记录 hash 绑定；答案卡从可信 manifest 重建机构、标题、网址和原审核/生效日期，不复制消息 metadata 中提供的标题、私人字段或日期。AI 回答仍标记未经独立核验。

有来源的 prepare/create hash 同时绑定正文与规范来源；正文、绑定或 manifest 改变，旧草稿保存返回 409。空来源不读取模板目录；预期目录 ValueError/OSError 返回中性 503，日志仅记录事件和异常类型。前后端均允许八个已审核机构域名，以及唯一完整 HA 查询网址和既有 CSDI dataset 例外，拒绝其他查询参数、fragment、凭据和显式端口。

没有新增来源版本归档表；缺少版本或与 manifest 不匹配的旧消息来源保守省略，不补写今天的日期。已保存卡片保持其历史来源快照。后端五文件独立冻结于 scratch/p2-backend-freeze-v2；根代理再次核验 5/5 SHA-256 与项目一致。

## 验证证据

| 检查 | 结果 | 日志（scratch 目录） |
|---|---|---|
| 答案卡专项：API 10、DTO 11、controller 25、UI 16、实际应用入口 9 | 71 全通过 | answer-flutter-all-target-green.log |
| 最终完整 Flutter 回归 | 475 passed，5 项既有 skips；新增专项无跳过 | answer-flutter-full-final.log |
| 最终静态检查 | No issues found | answer-flutter-analyze-final.log |
| Web JavaScript 编译，--no-pub --no-web-resources-cdn | 成功生成 app/build/web | answer-flutter-web-build.log |
| 标准项目完整后端回归 | 621 passed，0 skip/0 deselected，2 个既有弃用警告 | p2-backend-freeze-v2/p2-v2-full-green.log |
| 后端卡片/来源定向回归 | 110 passed | p2-backend-freeze-v2 receipt 与 target 日志 |

确实观察并修正了来源白名单丢失合法来源、取消准备仍占用忙碌状态、已删除旧详情残留、编辑时原文变化，以及未知删除刷新后版本/提示丢失的行为 RED。测试夹具编译/编码问题独立记录，未算作产品行为 RED。静态检查的括号、冗余导入提示已全部清理。

UI 验证包括英文、繁体中文、320px 宽度、2 倍文字、长 URL、模拟键盘 inset、实际点击保存确认、删除确认/取消和迟到响应。此为 Flutter widget 测试，未宣称实体设备键盘或本批真实浏览器端到端验收。Web 编译含既有依赖的 Wasm dry-run 与 Cupertino 字体提示；验收的是成功的 JavaScript 构建，不是 Wasm 构建。

测试使用合成数据、模拟 HTTP 和临时 SQLite；没有安装依赖、调用真实模型/ASR、操作真实数据库、上传、提交、推送或部署。

## 范围及后续验收

- 本批完成双入口和私人 CRUD；实际分享、复制/导出、浏览器打印/PDF 与原生平台桥接仍属后续批次，不能宣称已完成。
- 当前项目没有完整账户/个人数据删除 API。purge_answer_cards 只是供将来删除事务使用的 helper；全记忆删除不能称为完整个人数据清除，也不会暗中删除独立答案卡。
- 英文全文模板审核、实体设备与最终浏览器端到端验证仍待后续验收。
- 原有家庭 P1 改动保留，HEAD 仍为 818bbedd82215d8ba45e7aef8122c40bdfca5559，暂存区为空；本批 receipt 对比前一冻结清单，无文件丢失。

本批代码/测试文件与 SHA-256 见 scratch/answer-card-flutter-change-receipt.json；完整前端冻结副本见 scratch/answer-card-flutter-freeze。scratch 指 C:/Users/Administrator/Documents/Codex/2026-10-03/task。

> 后续阶段：本文保留 T3 历史验收。T4/T5 分享与导出及撤回恢复已实现；最终测试、实际输出和限制见 [ANSWER_CARDS_SHARING_EXPORT_ACCEPTANCE_ZH.md](ANSWER_CARDS_SHARING_EXPORT_ACCEPTANCE_ZH.md)。
