# 答案卡：单卡分享与公开内容导出验收

日期：2026-10-04。范围为已批准双模式方案的 T4/T5、demo 来源标注修正，以及独立预审发现的撤回回执丢失恢复修复。原始 SRS 未修改；没有提交、推送、部署、安装新软件或调用真实模型/ASR。此文件描述实现及实际证据，不代替主办方或独立审核批准。

## 用户可见行为

登录用户可以保存、查看、编辑和删除自己的独立答案卡。AI 回答的段落和来源默认不选；公共模板保留原来源、原日期和核验范围。英文界面明确提示模板正文为中文、英文版本未核对。

长者从已保存卡片选择一位获授权家人，按电邮辨认收件人，核对完整卡片，并明确确认个人资料检查后才站内分享。接收人读取独立公开快照，不获得原对话、私人 provenance 或私人卡片编辑入口。旧授权 epoch 不会自动升级；未知发送结果只能明确重试同一请求。发送历史提供明确撤回和确认；后端撤回已提交但回执丢失时，刷新只有确认同发送人、同卡、同分享快照的撤回终态才能解除待确认状态。缺失、无关或旧账户回包保留原操作重试入口，刷新不自动重发。

编辑、删除卡片，屏蔽家人或撤回相应家庭授权后，旧分享站内访问被撤销。删除卡片还清空全部相关分享快照正文。重新授权不会恢复旧分享，分享更新内容需要新的明确核对。站内撤权不能收回对方已经复制或导出的文件。

导出独立于分享：先检查完整公开卡片、勾选个人资料确认，再复制完整文本；Web 可调用浏览器打印／另存 PDF。登录用户在输出前重新校验卡版本和公开内容 hash，预留打印窗口在校验前为空白。弹窗阻止、版本失效、取消或迟到回包不会输出旧内容。访客导出只使用当前已核对的 RAM 草稿，不调用 owner 卡片接口，结束访客会话或登录后不自动迁移草稿。Android 使用 SDK Clipboard 文本复制；没有宣称实现 Android 原生 PDF。

## 自动化验证

| 检查 | 实际结果 | 工作区证据 |
|---|---|---|
| 后端标准全量 | 748 passed，0 skip/deselect，2 条已有警告 | t4-backend-freeze/RECEIPT.txt、最终 full 日志 |
| 后端分享／导出相关 | 221 passed；真实 localhost HTTP 12 项通过 | t4-backend-freeze |
| Flutter 最终标准全量 | 629 passed，5 项已有 skip | answer-revoke-terminal-read-flutter-full.log |
| 撤回恢复目标 | 45 passed；初次 controller RED 23/4、widget RED 14/3，最终并发读取 RED 27/1 | answer-revoke-recovery-{controller-red,widget-red,target-green}.log |
| 静态分析 | No issues found | answer-revoke-terminal-read-analyze.log |
| Web JavaScript | 编译成功 | answer-revoke-terminal-read-web-build.log |
| Android arm64 debug APK | 已有 SDK/JDK/Gradle 离线构建成功，223 tasks | answer-revoke-terminal-read-android-offline-build.log |

Web 构建仍有已有 Wasm dry-run 及 Cupertino 字体提示；这里验收 JavaScript 构建，不宣称 Wasm。Android APK 为 debug 构建，未安装到设备、未验真机 Clipboard。JDK 在 Windows 上的 Unix-domain socket 兼容失败使用其自带 TCP loopback 回退，只设置本次构建进程属性，未修改 JDK 或系统安全设置。一次重建使用错误 cwd 的诊断失败日志保留，最终正确目录构建成功。

## 实际浏览器证据

全部使用 synthetic elder/caregiver、全新非个人 Chrome profile、临时 SQLite 和 deterministic demo；家庭授权 API 数据为明确记录的合成 fixture。没有手工捏造 AI prepare 来源：实际生产聊天产生可信 resource_source_bindings，再由用户选择／编辑／保存。

工作区 `actual-ui-answer-cards-sharing-export-final-v2` 保存 PNG、DOM 和 JSON：

| 行为 | 证据 |
|---|---|
| 同名收件人按 exact email 选择，默认无选择／确认 | 02、03、15、17 |
| 分享真实提交后模拟500；明确同 key 重试只有一个快照 | share-commit500-exact-recipient-proof.json |
| 未送达旧 epoch 请求409；重新授权后新明确分享 | stale-epoch-unknown-key-proof.json、fresh-epoch-share.json |
| 撤回取消、确认及卡编辑使旧接收快照消失 | withdraw-and-edit-revocation-proof.json |
| 最终补丁：撤回真实提交丢回执→刷新 exact terminal→允许新分享；无自动重发 | actual-revoke-lost-receipt-recovery-proof.json、21–23 |
| owner 私人删除使接收列表为空且全部相关分享正文 null | actual-delete-shared-card-scrub-proof.json、34 |
| 原生 Clipboard 完整复制与真实 window.print 内容相同 | template-export-proof.json、ai-share-export-proof.json |
| 弹窗阻止零 owner POST；取消关闭预留空白窗口且迟到无打印 | export-popup-and-cancel-proof.json、19–20 |
| server 卡版本变化409，空白打印窗关闭且零输出 | owner-export-stale-version-proof.json、33 |
| 320px、实际 Flutter 字体200%，英文／繁中完整预览和控件可达，复制不截断 | narrow-{English,TraditionalChinese}-share-export-proof.json、24–29 |
| 访客真实聊天→局部 RAM 卡→实际复制／打印，无 owner 卡接口，结束登录无迁移 | guest-local-export-proof.json、30–32 |
| demo 只有公共来源时标注“参考公共资源”，不声称读取保存记忆 | actual-demo-fixed-chat.json、12 |

模板 PDF 为2页，AI 编辑卡 PDF 为3页；逐项核对全部公开显示字段、URL、原日期、核验状态／范围，AI 长正文18行全部保留，无替代字符，私人卡 ID、原聊天和 provenance 未进入输出。`template-pdf-full-content-verification.json` 与 `ai-share-export-proof.json` 说明 PDF 由真实 window.print 前捕获的 exact HTML 经 Chrome PDF engine 输出；没有把 headless 打印请求说成用户已保存 PDF。

另在 `kiosk-save-as-pdf-19068` 使用非 headless 的独立 Chrome、默认 Save as PDF 目标和自动 kiosk printing，经真实 window.print 产生两份原生 PDF，未调用 Page.printToPDF。`kiosk-result.json`、`content-verification.json` 全文核对通过。该项证明 exact 产品 HTML 的原生 Save as PDF 路径，属于自动化，不是人工系统对话框验收；实际应用到该原生路径的按钮流程停在设置页，未完成。收到用户桌面阻碍反馈后已关闭该自有 Chrome，不再开启可见测试窗口。

## 冻结与限制

`answer-revoke-recovery-freeze/manifest.json` 单独冻结最小五文件补丁供复核。`answer-sharing-export-current-freeze/manifest.json` 保存最终全量改动 hash、Web bundle、APK hash、HEAD 和空暂存区证明。早期私有卡169文件及分享／导出修复前192文件快照保留为历史证据，不冒充最终源码。

已知未验项目：Android 真机 Clipboard／原生键盘、人工系统 Save as PDF 对话框、真实 PostgreSQL 并发。没有完整账户／全部个人资料删除 API；purge helper 不等于已有账户删除功能。已复制／导出内容不能远程撤回。英文公共模板全文审核尚未完成。

所有测试服务／浏览器只管理本次自建 PID 和 localhost 端口；最终停止结果见 FINAL_BROWSER_RECEIPT.json 及 owned cleanup 证据。桌面白框另经只读窗口图像定位为 Windows“设置”启动页（ApplicationFrameHost，HWND855518／PID32904），仅最小化该指定阻碍窗口，没有终止系统进程或改安全设置。

最终独立复核另发现并发历史读的迟到 active 快照可回填问题：终态确认现在递增读取 generation，只移除其他在途 token，保留本 token 的通知，并防止旧 finally 释放新读取 busy。真实 RED 27 pass/1 fail 后，controller28+widget17=45 pass、全量629 pass。独立复核62项通过，原 P2 已关闭。最终两文件 SHA 与独立核对一致；单独 v2 freeze 和最终构建 hash 见 answer-revoke-terminal-read-freeze/manifest.json。

最终 Web bundle 又完成无可见窗口的实际迟到读取验收：旧路由 A 已收到真实 active HTTP 快照后延迟，新路由 B 先收到真实撤回终态，再释放 A，已撤回正文与活动按钮均未回填，新明确分享预览可用。合成 fixture 及准确交错在 actual-ui-answer-terminal-read-v3/FINAL_TERMINAL_READ_BROWSER_RECEIPT.json，运行时异常0；该阶段自有服务和浏览器全部停止、端口0。
