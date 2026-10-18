# 演示手动验收说明（虚构数据／Mock）

本说明是待操作者执行的清单；本轮自动化已验证合同，不代表已经做过真实浏览器、设备或人工可用性验收。先阅读同目录 GATES_MUST_COVERAGE_ZH.md 的剩余门槛。真实模型、通知、电话、麦克风、日历和外部发送不在本轮执行范围。

## 准备及安全边界

仅用一次性隔离实例、空临时SQLite、example.invalid虚构账号及现有MockTransport/MockClient。不要复制真实.env、密钥、用户数据库、设备存储或凭证。不得连接实际provider来冒充本清单的mock验收。仅DEMO且无简化模型配置时，应演示“不可用”降级。简化成功展示须使用测试中的严格mock适配器，不得编造真实模型质量结论。不要在既有服务上改配置、重启或清数据。

本机可复核的安全命令（任务目录，已有SDK/venv，无需安装依赖）：

```powershell
& 'D:\sdg ai hackathon\.venv\Scripts\python.exe' .\run_gates_backend.py gates-applied-runtime targeted gates-manual-reproduce-backend
# 下一条只运行虚构UI/传输测试；工作目录为 gates-applied-runtime/app
& 'D:\zendiary\tmp\flutter\bin\flutter.bat' test --no-pub test/guest_privacy_lifecycle_test.dart test/action_confirmation_details_test.dart test/gates_combination_test.dart test/content_simplification_journey_test.dart test/http_body_deadline_test.dart
```

不要为了展示而反复跑完整套件。localhost两会话桥接已由本轮定向验证，报告在任务目录；它会启动并停止自己拥有的临时mock服务，不是既有用户服务。

## 人工步骤与应见结果（未在真实设备执行）

1. 冷启动／访客：无登录墙，不填身份资料。输入虚构问题，等待期间有waiting；不重复提交，End仍可用。选择typing/speaking/both可在设置修改；本次只看控件状态，不触发麦克风或权限。
2. Guest RAM：用测试实例返回短expires_at（不得改正式TTL）。输入未发送虚构草稿及合成来源metadata；到期、resume核对、当前会话404/410均清正文/metadata/输入，禁用失效输入。普通503保留重试；旧请求迟到404/410不能清新会话。
3. F10跨组边界：打开一个纯虚构回答的“Explain more simply”，先看到完整将发送的所选原文及模型说明；取消不请求。第二次明确同意才走专用只读路径。成功仅显示未独立核验的临时草稿，原文/来源/安全说明保留；失败/无配置不假装成功。在请求中End/到期/换会话/改原文或metadata后，旧结果不得出现。取消只失效显示，不承诺撤销正在执行的调用或费用。
4. 提醒确认G2：用虚构提案2099-01-02T00:15:30+08:00，描述留空仍应看到实际事项、2099-01-02、00:15:30、UTC+08:00，以及保存待办与既有opt-in通知的区分和任何收件人。仅在mock scheduler环境点Confirm；Skip/返回不得保存。缺项、无时区、Feb30、过期或仅“明天早上”均禁用并要求补充；停留至过期后点击也拒绝。真实OS通知不执行。
5. Memory候选G5：虚构非敏感或不确定资料的手动候选卡与编辑确认框应显示实际建议类别。Edit保存的最终内容/kind/revision正确；取消/Do not save无memory写入。普通明确低敏偏好auto-save保留已批准例外；不要把它误报为本轮回归。
6. Help G6：普通搜索结果显示可信manifest机构、标题/链接、原日期及状态；旧回包缺机构明确说未提供，不从host猜。等待、空态、失败Retry和退出可达，旧回包不污染新session。
7. 保留回归：访客Help防骗三步含“不转钱／不交密码个人资料”；联系人只显示批准版本与核查日期，审批失败有官方网页回退。只检查按钮状态/URL，不拨号或打开真实外部站。Rehabus未核实hold保持，不能作为当前可推荐资料。
8. 家庭／社区：仅在隔离合成账户确认所选内容与收件人；本轮不实际发送。Community必须如实显示当前活动来源/日期及无机会结果。SmartPLAY休闲活动不能冒充真实贡献匹配；不使用旧未核实样例证明G7完成。
9. 320px/200%及中英：所有关键说明可滚动，Confirm/Skip/Cancel、输入、Retry/End可到达；未发现溢出才人工记通过。真实设备辅助功能、粤语语义、识别和通知送达另验。

## 记录方式

每步记录执行人、UTC时间、隔离源码哈希、测试数据、预期／实际、截图（不得含真实资料）及Pass/Fail/未执行。请勿预填“通过”。新发现必须按复现证据处理；未执行项继续标“未验收”。官方资料只复用已批准来源，不编造医疗／法律建议或新紧急号码。
