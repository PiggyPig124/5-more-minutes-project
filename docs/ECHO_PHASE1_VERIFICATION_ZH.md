# Echo 第一批实现验证记录

日期：2026-09-27。范围为新版需求的第一批基础实现，不代表整个 MVP 已完成。全部数据使用虚构账户和临时数据库。

后续已接入真实社区网页自动搜索；本文中的第一批空活动目录描述属于历史状态。最新实现与验收见 `COMMUNITY_AUTO_SEARCH_ZH.md`。

## 独立 HTTP 验收

- `acceptance/echo_mvp_phase1_acceptance.py`：34 项通过。验证游客对话不写账户、私人对话、消息和记忆表；关闭授权时不能保存；照顾者不能开启长者记忆；明确 Save 生成确认记忆；技能需要确认；关闭授权仍能查看旧记忆；结束及重启后游客会话不可恢复；删除原记忆后不再发现相关技能。
- 更新后的 `acceptance/interim_api_acceptance.py`：56 项通过。采用明确记忆授权和新 Save 接口；原有私有召回、修正、家庭分享去重、回复、删除撤回、权限撤销、资源来源与日期均通过。
- 更新后的 `acceptance/interim_restart_acceptance.py`：16 项通过。确认授权和已保存记忆可以跨重启恢复，删除与关联故事撤回跨重启保持生效。

重现命令（PowerShell，从项目根目录）：

```powershell
.\.venv\Scripts\python.exe acceptance\echo_mvp_phase1_acceptance.py
.\.venv\Scripts\python.exe acceptance\interim_restart_acceptance.py
```

中期 HTTP 脚本需指定临时运行的示范后端 `--base-url`；不要对真实账户数据库执行。

## 范围和限制

- 新聊天候选只在响应中给出，点击 Save 才写记忆库；旧候选接口保留兼容，不能宣称所有旧接口都已采用无持久候选设计。
- 记忆类别仍使用旧有 fact／experience／preference／emotion，尚未完整覆盖新版九类。
- 个性化技能采用有限词组规则，尚未完成真实 AI 技能抽取或香港长者用语评估。
- 社区资料没有默认虚构活动。活动来源审核、真实当前资料录入和维护人仍需补齐；无结果不等于已完成真实活动演示。
- 长者关闭记忆后保留旧记忆供本人管理；完整 Delete all 和所有编辑流程 Save 前无持久候选仍须追踪。
- 默认聊天仍是清楚标识的确定性演示；未验证真实模型、粤语语音、推送或实体 Android 设备。
- 官方 Answer Card 导出／打印、完整转介和家庭拒绝／阻止等见 `CURRENT_TASKS_ZH.md`。

## 后端自动测试

GPT-6-luna 执行完整后端测试：34 项通过。覆盖既有业务及新增游客、授权、Save 流程、旧数据库兼容、社区来源筛选与权限。旧测试用例已改为明确启用记忆，不改变生产默认关闭行为。

游客会话采用进程内存，不适合未经调整直接部署在多实例负载均衡后；需单实例或粘性路由。会话 30 分钟无活动后不可访问，后台最多下一次一分钟清理周期移除 RAM 中内容。

## 客户端验证

- Flutter analyze：无问题。
- Flutter test：33 项通过、2 项可选 live API 测试跳过。包含五个主导航、大字号英文界面、游客结束后的迟到回复丢弃，以及记忆保存请求不能填回下一账号的回归验证。
- 网页构建：最终构建通过，输出 `app/build/web`，后端地址为 `http://127.0.0.1:8000`。现有 secure-storage 依赖产生 WebAssembly 兼容性预检查提示；本次交付为常规 JavaScript 网页构建。未发布网站，未生成本轮 Android 安装包，也未进行浏览器手动或实体设备验收。
- 测试使用已有 Flutter SDK `D:\zendiary\tmp\flutter`。普通权限无法访问其缓存锁，允许缓存访问后已完成上述分析与测试。

二项 live API 客户端测试没有计入通过数量；独立 HTTP 验收覆盖后端服务，不应替代客户端与真实服务的完整端到端验收。
