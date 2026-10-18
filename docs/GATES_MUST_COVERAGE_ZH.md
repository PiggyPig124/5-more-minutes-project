# MUST 覆盖及未验收清单（本轮组合证据）

更新：`2026-10-15T06:29:31.655674+00:00`。设计依据：`reference documents/Echo_Software_Requirements_Specification_v1.1_Corrected (1).md`，并保留既有 Memory 普通低敏偏好自动保存的批准例外。

**这是受控自动化证据清单，不是全部需求完成或上线合规声明。** 三组合并后，后端999通过；Flutter875通过/5项显式live跳过；analyze无问题；JS Web构建通过。一次独立组合复核发现F10访客404/410未清RAM，补充RED→GREEN后最小接入统一清理，旧请求不清新会话，503保留重试。只有前端受影响，修复后重跑完整Flutter；后端全量只运行一次。

D盘是否已实际应用、应用时间、回读结果及目标/非目标哈希，以任务证据 `C:/Users/Administrator/Documents/Codex/2026-10-15/task-6/gates-integration-final-verification.json` 为准。未有成功receipt时，不得仅凭本文件宣称已落地。

| SRS MUST | 本轮可核对的覆盖 | 证据（模块数量不是需求通过率） | 未证明／剩余 |
|---|---|---|---|
| FR ACC 01 Start Without Registration | 访客、角色与独立许可合同；互动偏好、语音草稿/失败文字回退有Flutter覆盖 | `test_scam_guest_access` (5)；`test_privacy_boundaries` (4)；`test_integration` (11) | 真实设备语音、辅助功能与用户可用性未验收 |
| FR ACC 02 Create a Role-Based Personal Account | 访客、角色与独立许可合同；互动偏好、语音草稿/失败文字回退有Flutter覆盖 | `test_scam_guest_access` (5)；`test_privacy_boundaries` (4)；`test_integration` (11) | 真实设备语音、辅助功能与用户可用性未验收 |
| FR ACC 03 Select Interaction Preference | 访客、角色与独立许可合同；互动偏好、语音草稿/失败文字回退有Flutter覆盖 | `test_scam_guest_access` (5)；`test_privacy_boundaries` (4)；`test_integration` (11) | 真实设备语音、辅助功能与用户可用性未验收 |
| FR ACC 04 Present Consent and Privacy Choices | 访客、角色与独立许可合同；互动偏好、语音草稿/失败文字回退有Flutter覆盖 | `test_scam_guest_access` (5)；`test_privacy_boundaries` (4)；`test_integration` (11) | 真实设备语音、辅助功能与用户可用性未验收 |
| FR CON 01 Simple Conversation | Repeat与F10专用只读链路、原文保留、第二次同意和失效回退有受控覆盖 | `test_integration` (11)；`test_content_simplification` (42)；`test_content_simplification_http` (21) | 真实模型耐心、语义等价、粤语质量未验收 |
| FR MEM 01 Memory Disabled by Default | 默认off、手动RAM候选类别/编辑/保存、撤回与私有卡合同覆盖 | `test_memories` (6)；`test_memory_controls` (13)；`test_memory_action_withdrawal` (9)；`test_auto_preference_policy` (17)；`test_private_memory_cards` (43) | 普通明确低敏偏好auto-save沿用已批准例外；真实模型分类与端侧取证未验收 |
| FR MEM 02 Confirm a Memory Candidate | 默认off、手动RAM候选类别/编辑/保存、撤回与私有卡合同覆盖；G5保存前显示实际建议kind，取消零保存 | `test_memories` (6)；`test_memory_controls` (13)；`test_memory_action_withdrawal` (9)；`test_auto_preference_policy` (17)；`test_private_memory_cards` (43) | 普通明确低敏偏好auto-save沿用已批准例外；真实模型分类与端侧取证未验收 |
| FR MEM 04 Manage Saved Memories | 默认off、手动RAM候选类别/编辑/保存、撤回与私有卡合同覆盖 | `test_memories` (6)；`test_memory_controls` (13)；`test_memory_action_withdrawal` (9)；`test_auto_preference_policy` (17)；`test_private_memory_cards` (43) | 普通明确低敏偏好auto-save沿用已批准例外；真实模型分类与端侧取证未验收 |
| FR MEM 05 Disable Memory and Delete Data | 默认off、手动RAM候选类别/编辑/保存、撤回与私有卡合同覆盖 | `test_memories` (6)；`test_memory_controls` (13)；`test_memory_action_withdrawal` (9)；`test_auto_preference_policy` (17)；`test_private_memory_cards` (43) | 普通明确低敏偏好auto-save沿用已批准例外；真实模型分类与端侧取证未验收 |
| FR MEM 06 Create a Memory Card | 默认off、手动RAM候选类别/编辑/保存、撤回与私有卡合同覆盖 | `test_memories` (6)；`test_memory_controls` (13)；`test_memory_action_withdrawal` (9)；`test_auto_preference_policy` (17)；`test_private_memory_cards` (43) | 普通明确低敏偏好auto-save沿用已批准例外；真实模型分类与端侧取证未验收 |
| FR FAM 01 Send and Approve a Connection Request | 独立账号、授权/撤回、所选正文及收件人确认、私有隔离有覆盖 | `test_family_blocks` (22)；`test_family_message_preview` (11)；`test_family_messages` (2)；`test_task_sharing` (22)；`test_answer_card_sharing` (50) | 真实跨设备通知/传输与运营验收未执行；测试不能单独证明不存在所有遥测 |
| FR FAM 02 Protect Private Conversations | 独立账号、授权/撤回、所选正文及收件人确认、私有隔离有覆盖 | `test_family_blocks` (22)；`test_family_message_preview` (11)；`test_family_messages` (2)；`test_task_sharing` (22)；`test_answer_card_sharing` (50) | 真实跨设备通知/传输与运营验收未执行；测试不能单独证明不存在所有遥测 |
| FR FAM 03 Share Selected Memory-Linked Content | 独立账号、授权/撤回、所选正文及收件人确认、私有隔离有覆盖 | `test_family_blocks` (22)；`test_family_message_preview` (11)；`test_family_messages` (2)；`test_task_sharing` (22)；`test_answer_card_sharing` (50) | 真实跨设备通知/传输与运营验收未执行；测试不能单独证明不存在所有遥测 |
| FR FAM 06 No Generic Monitoring Feed | 独立账号、授权/撤回、所选正文及收件人确认、私有隔离有覆盖 | `test_family_blocks` (22)；`test_family_message_preview` (11)；`test_family_messages` (2)；`test_task_sharing` (22)；`test_answer_card_sharing` (50) | 真实跨设备通知/传输与运营验收未执行；测试不能单独证明不存在所有遥测 |
| FR INF 01 Use Approved Sources | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 02 Translate Everyday Language to Official Terms | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 03 Display Source and Date | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖；G6普通Help机构来自可信manifest，不从host猜测 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 04 Explain and Provide Next Steps | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 05 Create a Portable Sourced Answer Card | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 06 Handle Missing or Unverified Information | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 07 Transport Translation and Handoff | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 08 Healthcare Navigation and Preparation | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR INF 09 Live Data Boundary | 批准源、机构/标题/日期/状态、官方交接、缺项降级与制卡绑定有覆盖 | `test_official_guidance` (33)；`test_resources` (5)；`test_help_source_organisation` (4)；`test_answer_card_source_bindings` (25)；`test_resource_quarantine` (17) | 当期官网可用性/许可/维护责任未重验；不独立算路线/费用、读病历、预约或猜实时值 |
| FR SCM 01 Provide Post-Interaction Guidance | 访客三步含不转钱/密码资料、批准联系人版本/到期核验及私有写入边界有覆盖 | `test_scam_contact_approval` (32)；`test_scam_guest_access` (5)；`test_safety_hardening` (39) | 未拨真实电话、未复核当期热线服务；不做来电识别/监听 |
| FR SCM 02 Provide Clear Verification Actions | 访客三步含不转钱/密码资料、批准联系人版本/到期核验及私有写入边界有覆盖 | `test_scam_contact_approval` (32)；`test_scam_guest_access` (5)；`test_safety_hardening` (39) | 未拨真实电话、未复核当期热线服务；不做来电识别/监听 |
| FR SCM 03 Provide Verified Contacts | 访客三步含不转钱/密码资料、批准联系人版本/到期核验及私有写入边界有覆盖 | `test_scam_contact_approval` (32)；`test_scam_guest_access` (5)；`test_safety_hardening` (39) | 未拨真实电话、未复核当期热线服务；不做来电识别/监听 |
| FR SCM 05 Do Not Duplicate Caller Identification | 访客三步含不转钱/密码资料、批准联系人版本/到期核验及私有写入边界有覆盖 | `test_scam_contact_approval` (32)；`test_scam_guest_access` (5)；`test_safety_hardening` (39) | 未拨真实电话、未复核当期热线服务；不做来电识别/监听 |
| FR CMT 01 Browse Verified Activities | 部分：SmartPLAY活动、技能确认与诚实无结果/独立分享许可有覆盖 | `test_community_search_status` (8)；`test_smartplay_community_search` (54)；`test_agent_memory_community` (5) | G7真实群组与贡献机会供给仍未闭环；未联系机构或发布资料 |
| FR CMT 03 Discover a Skill from Memory | 部分：SmartPLAY活动、技能确认与诚实无结果/独立分享许可有覆盖 | `test_community_search_status` (8)；`test_smartplay_community_search` (54)；`test_agent_memory_community` (5) | G7真实群组与贡献机会供给仍未闭环；未联系机构或发布资料 |
| FR CMT 04 Recommend a Contribution Opportunity | 部分：SmartPLAY活动、技能确认与诚实无结果/独立分享许可有覆盖 | `test_community_search_status` (8)；`test_smartplay_community_search` (54)；`test_agent_memory_community` (5) | G7真实群组与贡献机会供给仍未闭环；未联系机构或发布资料 |
| FR MAP 02 Select Story Visibility | 条件范围未启用；本轮不交付或公开发布Memory Map | SRS条件范围；本轮不启用 | 启用前仍须位置/身份保护、可见性撤回、审核举报移除全链路验收 |
| FR MAP 03 Protect Location and Identity | 条件范围未启用；本轮不交付或公开发布Memory Map | SRS条件范围；本轮不启用 | 启用前仍须位置/身份保护、可见性撤回、审核举报移除全链路验收 |
| FR MAP 04 Community Moderation | 条件范围未启用；本轮不交付或公开发布Memory Map | SRS条件范围；本轮不启用 | 启用前仍须位置/身份保护、可见性撤回、审核举报移除全链路验收 |
| FR HLP 01 Offer Human Assistance | 人工求助入口/官方转介、每次所选内容与收件人确认、危机边界有覆盖 | `test_official_guidance` (33)；`test_safety_hardening` (39)；`test_family_message_preview` (11) | 未实际呼叫/发送或验证直连社工服务；仅沿用已批准来源 |
| FR HLP 02 Obtain Consent Before Contact | 人工求助入口/官方转介、每次所选内容与收件人确认、危机边界有覆盖 | `test_official_guidance` (33)；`test_safety_hardening` (39)；`test_family_message_preview` (11) | 未实际呼叫/发送或验证直连社工服务；仅沿用已批准来源 |
| FR HLP 04 Provide Referral Guidance | 人工求助入口/官方转介、每次所选内容与收件人确认、危机边界有覆盖 | `test_official_guidance` (33)；`test_safety_hardening` (39)；`test_family_message_preview` (11) | 未实际呼叫/发送或验证直连社工服务；仅沿用已批准来源 |
| FR HLP 05 No Automatic External Notification | 人工求助入口/官方转介、每次所选内容与收件人确认、危机边界有覆盖 | `test_official_guidance` (33)；`test_safety_hardening` (39)；`test_family_message_preview` (11) | 未实际呼叫/发送或验证直连社工服务；仅沿用已批准来源 |
| FR HLP 06 Emergency Boundary | 人工求助入口/官方转介、每次所选内容与收件人确认、危机边界有覆盖 | `test_official_guidance` (33)；`test_safety_hardening` (39)；`test_family_message_preview` (11) | 未实际呼叫/发送或验证直连社工服务；仅沿用已批准来源 |

## 嵌入在 SHOULD／非功能章节中的 MUST

| 门槛 | 证据与范围 | 剩余 |
|---|---|---|
| CON04 确认屏 MUST 显示事项/日期/时间/行为/收件人 | `test_action_confirmation_details`20；Flutter同名19。原offset日期/秒/UTC时差，缺项、歧义、非法/过期、点击再查、Skip/返回、幂等 | 不开启通知；真实通知送达与自然语言日期理解未验。DEMO无结构化due_at时明确要求补充，不假称已排程 |
| §12.2 guest过期清除；§11.4等待/取消重试 | `guest_privacy_lifecycle_test`22与`gates_combination_test`6；timer/resume、404/410、draft/voice边界、旧结果隔离 | 应用持有状态清除，不承诺GC/OS物理抹除；真机暂停/恢复/语音未验 |
| §11.3/11.4 header+body绝对超时 | `http_body_deadline_test`4；F10 journey的body停顿/取消/退出4；共享client不关闭 | 30ms等为测试预算，产品沿用60秒，不是产品SLA；真网/真实provider未验 |
| §11.2 权限与合成数据 | privacy/role/family/guest覆盖；本轮全部虚构账号/临时DB，模型transport mock，未调用真实电话/通知/权限 | TLS、静态加密、凭证运维及正式部署控制本轮未审计，不能宣称满足上线安全门槛 |
| §11.5 verified与suggestion分离 | 来源/日期/状态、审批绑定、F10未独立核验草稿及原文保留合同 | 真实模型医疗/法律/财务及语言质量未验；不得将演示内容当真实建议 |
| §12.2 数据保留、公开移除 | 记忆撤回与分享撤回自动化覆盖；本轮不发起公开发布 | 最终保留期、公开内容运营审核、源许可维护、用户研究仍待团队确认 |

## 可复现证据

- 完整组合：任务目录 `gates-combined-backend.log/.xml`（999）、`gates-combined-flutter-final.log`（875/5）、`gates-combined-analyze-final.log`、`gates-combined-web-build-final.log`。
- 跨组审查与修复：`gates-independent-review.md`、`gates-review-red.log`（404/410两个预期失败、四个保留通过）、`gates-review-green.log`。原三候选RED与handoff继续保留。
- 应用后定向读回：`gates-readback-backend.log/.xml`、`gates-readback-flutter.log`、`gates-readback-mock-bridge-result.json`（localhost→严格mock适配器，两会话；真实外部模型0）。尚未生成的文件表示未完成，不可提前记通过。
- 本表自动提取全部标注Priority MUST（含条件MUST）的FR标题，机器映射见任务目录`gates-must-coverage.json`。测试数量不是现实服务、真机或每条需求的完成率。

## 不能宣称全部完成

G7真实群组/贡献机会供给、真实模型简化语义等价与安全质量、真实设备/通知/麦克风/粤语语音、真实服务当前可用性与许可、用户研究、生产TLS/静态加密/密钥/保留期及运营审核均没有本轮验收证据。Memory Map和直连社工通知未启用；无配置简化应显示不可用。保留既有Wasm依赖兼容/Cupertino字体提示与后端两条弃用警告，仅确认JS Web构建。
