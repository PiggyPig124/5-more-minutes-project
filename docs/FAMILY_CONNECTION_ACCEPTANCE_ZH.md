# 家庭连接申请与封锁：实现及验收记录

最终补充：独立审阅发现的旧未送达预览授权 P1 已修复，最新结果见末尾“P1 最终修复与冻结”。前文 505/390/22 为先前阶段证据。

依据 `superpowers/specs/2026-10-04-family-request-block-design-and-plan.md`，用户授权本地前后端修改及合成数据测试。未安装、提交、推送、部署、上传或迁移真实数据库。原 SRS 未修改。

## 实现结果

- 保留长者邀请及照护者接受邀请码；新增照护者申请、目标长者明确审批／拒绝、申请者撤回。待审批不产生权限，审批两项 scopes 默认均不勾选。
- 长者可通过自己持有的申请或连接记录封锁该 pair；同事务拒绝待审批申请、撤回连接、任务分享和消息访问，并推进授权代次。解除仅解除封锁，旧连接及旧分享不会恢复。
- 旧 accepted token 缺少历史授权代次时失效，不根据当前 link 猜测授权；旧撤回消息 key 返回 410。发送者可管理自己的发送历史与撤回标记，接收方无法通过重连恢复旧正文。
- Flutter 对账号、稳定 ID、version、session 和 generation 作检查；晚返回、失败重试、任务详情、通知缓存和求助消息 key 均覆盖。失败重试保留原 payload/key，用户明确操作才重试。
- 真实浏览器发现旧消息收件人及预览只显示姓名。补丁复用现有真实邮箱身份方法，新增行为测试核对同名邮箱和实际收件 ID。

## 最终自动验证

| 验证 | 结果 | 临时工作目录日志 |
|---|---|---|
| 全部后端 pytest | 505 通过，2 项既有 warnings | `family-full-backend.log` |
| 最后修改后全部 Flutter | 390 通过，5 项既有跳过 | `family-final3-flutter.log` |
| 最终静态分析 | No issues found | `family-final-analyze.log` |
| 实际 localhost 双账号／重启 HTTP | 22 项通过，自建服务已停止 | `family-final-http.log` |
| 同名消息身份行为 RED→GREEN | 缺少邮箱复现→1 项通过，核对所选收件 ID | `family-identity-red.log`, `family-identity-green.log` |
| 最终 JS Web 构建 | 成功，28.3s；既有 Cupertino 字体及 wasm 提示 | `family-final-web-build.log` |

以上日志位于 `C:\Users\Administrator\Documents\Codex\2026-10-03\task`。后端在完整回归后没有再改动；最后补丁只改变已有消息身份显示及对应前端断言。

## F01–F15 覆盖索引

| 合同 | 证据 |
|---|---|
| F01/F04 邀请、所有接受 aliases、终态和旧 accepted token | `backend/tests/test_family_requests.py`, `test_family_connection_legacy.py` |
| F02/F03 申请无权限、明确审批、普通拒绝及新申请 | `test_family_requests.py`；真实 UI 01–04、24–28 |
| F05 稳定身份、同名、错误 owner/角色、陌生目标 | 请求／封锁后端测试；`family_connections_widget_test.dart`；`family_message_identity_test.dart`；真实 UI 15–18、40–42 |
| F06/F07 封锁、解除不恢复、重连需新批准／分享 | `test_family_blocks.py`, `test_family_message_withdrawal.py`；HTTP 22 项；真实 UI 09–13、17–28、41–43 |
| F08 scope/remove/reconnect、原始消息与任务保留 | `test_family_message_withdrawal.py`, `test_task_sharing.py`；真实 API 回执与 UI 13 |
| F09 双赢顺序竞态 | `test_family_blocks.py` 的 8 个强制 SQLite owner-guard 顺序用例；未验证真实 PostgreSQL |
| F10 全表事务回滚 | `test_family_blocks.py` 故障注入及全表快照 |
| F11 请求及 alias key、撤回旧 message key、payload 冲突 | `test_family_requests.py`, `test_family_message_withdrawal.py`；HTTP旧key410 |
| F12 卡片编辑／删除与家庭撤权 | `test_private_memory_cards.py`, `test_family_blocks.py`；既有 Flutter 卡片合同回归 |
| F13 晚返回、账号切换、失败重试及缓存清理 | `family_connection_controller_test.dart`, `family_notification_cache_test.dart`, `family_support_epoch_test.dart`, `family_support_strict_test.dart` |
| F14 320px／2倍字／中英文／键盘 | 21 项家庭 widget；真实浏览器所有四种确认页及缩短视口的聚焦申请页面 |
| F15 旧 schema、部分 additive 列、重复初始化、缺 schema 失败关闭 | `test_family_connection_legacy.py`, `test_family_message_withdrawal.py` |

## 真实浏览器证据

实际运行本次最终构建、localhost 后端、全新隔离 SQLite 和两个独立无窗口 Chrome 配置。长者及照护者为合成账号；额外同名账号仅用于身份区分和无关 pair 验证。账号、原始任务及额外场景的 API fixture 均有明示记录，不冒充 UI 创建证据。

证据目录：`C:\Users\Administrator\Documents\Codex\2026-10-03\task\actual-ui-family-connections`。

- UI 01–04：照护者明确申请、长者拒绝、重新申请、两个 scopes 默认未勾选且明确审批。
- UI 06–13：完整新消息预览后明确发送；照护者可见既有消息与共享任务；长者封锁后两者均撤回，自己的发送原文保留并标记撤权。
- UI 15–18、24–27、44–45：中英文审批、拒绝、封锁和解除页面，320px／2倍字，可滚动到身份、影响、scope 和按钮。截图已实际打开检查。UI 20–21 使用聚焦输入及 650px 缩短视口模拟键盘占用；实体系统键盘未测。
- UI 28、41–43：同一主 pair 的新申请明确审批后，旧分享仍不可见；新预览按真实邮箱选择照护者并明确发送，接收方只看到新内容，旧任务仍不可见。
- UI 47–48：两个同名而邮箱不同的真实合成连接，选择器及预览能够区分；额外预览未发送。
- `browser-final-api-receipt.json`：主 pair epoch 3，接收方仅 1 条新消息、0 个旧共享任务；原始私人任务保留。本人发送历史有 3 条：原始消息和先前脚本发给第三合成账号的消息已撤权，正确主 pair 新消息仍有效。
- `elder-error-audit.json`、`caregiver-error-audit.json`：产品 console errors 为零。保留脚本定位异常，不计为产品测试成功或产品失败。

早期脚本误选额外同名合成账号，暴露了旧选择器只显示姓名的问题。早期 UI 22、23、29 明确排除为主 pair 重连／新分享证明；不删除这些审计记录。最终证据以 28、41–43、47–48 及 API 回执为准。`family-browser-receipt-finish.log` 包含 `ACTUAL_BROWSER_FINAL_ACCEPTED`，`family-browser-identities.log` 包含双同名身份实际浏览器通过标记。

## 兼容性裁决与边界

scope 集合改变时保守撤回该连接的全部既有消息及任务分享并推进代次，包括增加 scope；用户需要明确重新分享。解除遇到历史不一致的仍 active link 会修复为撤回，绝不恢复旧访问。通知页面在家庭 generation 变化后需关闭重开，原始通知数据未删除。

竞态、旧数据迁移和故障注入使用合成 SQLite；真实 PostgreSQL、多实体设备、系统虚拟键盘及外部模型／ASR 未验证。浏览器的键盘场景为聚焦输入及缩短可视视口；widget 使用实际 viewInsets 组合验证，不能声称实体键盘验收。

独立最终审阅由父线程在冻结版本上完成，本记录不冒充审阅结论。保留已有未提交工作；以 `family-change-receipt.json` 核对本轮之外的基线文件和 HEAD，不把整个既有 dirty diff 归为本轮修改。


## P1 最终修复与冻结（2026-10-04）

独立审阅实际复现：epoch 1 下确认、尚未送达的首次消息请求，在 block/unblock/new approval 后被服务端用当前 epoch 写入。旧 key 检查只能保护已写入的消息，不能保护迟到首次请求。本次对普通消息、Story 及同源既有指定联系人求助统一修复，不新增求助功能。

普通及 Story POST `/family-messages`、既有 POST `/safety/support-request` 均要求 `family_link_id` 和严格正整数 `expected_authorization_epoch`。同 owner/link guard、同事务中检查捕获的 ID/epoch，缺失或非法 422，当前 active link 不匹配 410。不会按当前授权自动补字段或升级旧预览，正常同 epoch 同 key 重试仍返回同一消息。Story 同时保留原 captured memory revision 校验。

Flutter 完整预览捕获不可变 link DTO 与完整正文；普通消息也监听授权和账号变化。旧预览撤销后不会自动选新代次收件人，必须明确重新选择、完整预览及确认。求助 dialog 打开前捕获每个候选 contact 对应的 link，发送使用捕获字段。旧生产发送方法缺捕获字段在本地 422；可选 capability 保留测试 fake 兼容，真实 REST 无回退或自动查询当前 epoch。

最新完整证据均在 `C:\Users\Administrator\Documents\Codex\2026-10-03\task`：

| 验证 | 最终结果 | 日志 |
|---|---|---|
| 全后端 | 516 passed，2 既有 warnings，264.62s | `family-p1-full-backend.log` |
| 最后源文件修改后的全 Flutter | 404 passed，5 既有 skipped | `family-p1-final-flutter.log` |
| 最终 analyze | No issues found | `family-p1-final-analyze.log` |
| 真实 HTTP／重启 | 26 项通过，临时服务停止 | `family-p1-final-http.log` |
| 最终 Web 构建 | 成功，29.4s，既有字体／wasm 提示 | `family-p1-web-build.log` |
| 实际浏览器延迟请求 | 双方向旧请求 410，新完整预览当前代次发送成功 | `family-p1-browser-flow.log` |

新增 `backend/tests/test_family_message_preview.py` 的 11 项真实路由合同覆盖双向迟到首次写入、缺绑定、错误 link、非法 epoch、Story revision、求助同源漏口及同 epoch 合法重试。独立原始诊断在修复前双向 201 已 RED 复现；新增 API、controller、普通预览 widget 也有 RED→GREEN 证据。原始临时目录 pytest 发现权限失败不计为产品 RED；复制到受限范围后诊断实际复现。夹具适配期间重复参数收集错误已修，最终全套真实执行通过，未把 AST 检查冒充测试通过。

实际浏览器证据目录 `actual-ui-family-preview-p1` 使用全新合成数据库／双 Chrome 配置。确认完整预览后，CDP 在 Request 阶段暂停真实 POST（未送达后端），再经实际 localhost API fixture 完成 block/unblock/新申请审批，释放原始请求。长者 epoch 1→3、照护者 epoch 3→5 均收到 410，双方普通消息列表为空；相同旧 body 重试仍 410。当前 epoch 5 下新选择收件人、完整预览并明确确认后，照护者仅见新内容。

`p1-browser-api-receipt.json` 保存无凭证的捕获 body、代次和 410。截图 `old-preview-elder`, `late-elder-410-no-send`, `old-preview-caregiver`, `late-caregiver-410-no-send`, `fresh-current-epoch-full-preview`, `caregiver-fresh-only-after-old-late-rejected` 已保存。这里的重连是明示 API fixture，完整预览／确认／暂停释放为实际 UI/CDP；不冒充每次重连都由页面点击完成。先前完整 UI 家庭操作证明仍保留。

兼容性边界：旧客户端未携带必需预览授权字段会收到 422，应使用当前前端。未测真实 PostgreSQL、实体设备／系统键盘或真实模型／ASR。AnswerCard 仍未混入本次家庭补丁。父线程对新冻结版本进行独立复审，不在此冒充已审阅通过。
