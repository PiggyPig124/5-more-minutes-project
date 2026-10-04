# 双模式 AnswerCard 首批验收（T1／T2）

日期：2026-10-04。本批是公开字段契约与私有后端，尚未完成 Flutter 两入口、站内分享、复制／打印／PDF。家庭 P1 已由父线程独立复核关闭；本批未改家庭产品文件。

## 已实现

- 当前已完成 assistant 单条回答的 owner-only prepare：原文只返回供 RAM 摘选，不新增持久副本；默认零选段。保存重查账户、消息 owner／role／content hash；不读邻近对话、摘要或个人记忆。
- 恰好三张版本化公共模板；原审阅日期2026-10-03、未知日期null。模板哈希绑定正文、来源、范围和版本；旧草稿不能用同版本新内容冒充。
- 独立 AnswerCard 与无正文 operation 回执。只保存最终选段；编辑前／未选原文、私有metadata不进入新卡或回执。规范公共payload和 owner-only provenance分离。
- 本人 create/list/detail/PATCH/DELETE；别人资源404，匿名401，caregiver可管理本人卡。严格嵌套DTO，不接受客户端 owner／来源正文／日期／核验字段。
- PATCH完整展示字段与严格正整数版本；原样编辑也版本+1。幂等hash保留字段是否显式提交，重试不能改写较新版本。删除清除卡正文和全部provenance；旧key410且重启后不复活。
- 来源只能精确绑定已审阅snapshot后重建规范title／URL／日期。当前历史resource_sources通常不带版本hash，保守排除、标无可核实出处；不以当前日期回填历史来源，AI出处标签仍由mode保留。
- 缺表、不可用模板和损坏已存payload中性503。事务失败注入证明 body/version/operation回滚。`purge_answer_cards`仅清该owner卡，不自行提交或取得新锁。

## 证据

| 验证 | 结果 | 日志 |
|---|---|---|
| T1公开契约 | 20 passed | answer-contract-final-green.log |
| T2私有后端 | 59 passed，1既有warning | answer-private-final-green.log |
| 完整后端回归 | 595 passed，2既有warnings，284.66s | answer-batch1-full-backend.log |

全部日志位于 `C:\Users\Administrator\Documents\Codex\2026-10-03\task`。真实行为RED证据含缺实现、非法版本／完成状态、损坏payload、模板hash、PATCH字段缺失、幂等字段省略差别；不得把工具选择错误或fixture错误当产品RED。三份官方原页面snapshot哈希与manifest一致；产品仅复制已审阅公共字段，不带原HTML。

## 边界与下一批

本批未改 Flutter、未新增分享／export-preview API；没有真实浏览器单卡打印／PDF、Android原生桥或真机验收，也没有真实PostgreSQL竞态结论。独立分享快照、家庭scope/block/remove撤权与未知旧key请求是T4门槛，不能仅凭私有卡版本测试宣称完成。

项目不存在完整账户／个人数据删除入口；已准备caller-owned purge helper并验证回滚与其他owner保留，未误挂到“全部记忆删除”。该集成缺口仍需完整数据删除功能接入。

下一批T3接严格AnswerCard DTO/API/独立控制器、两个入口、明确选段／编辑／完整预览／保存、guestRAM、换账号和晚返回；T4分享授权竞态；T5完整文本和Web真实打印/PDF；Android原生PDF另T6。既有完整Web8–12小时规划仍粗略，不包括工具链／设备等待。

未安装、提交、推送、部署、上传、运行真实模型／ASR或修改真实数据库。首批最终文件哈希保存在scratch `answer-card-batch1-change-receipt.json`，用于父线程独立复审。
