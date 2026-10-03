# BOSS Contact Policy — Canonical Business Rules

本文件是 BOSS 联系业务的长期规则入口。目标不是“越严越安全”，而是在不触碰账号安全和永久业务红线的前提下，尽快联系更多真正适合的岗位。

## 1. 业务目标

- 正常批次目标：成功联系 5 个全新、最终审计通过的岗位。
- 0/1/2 个绝不能视为完成；默认 3/5、4/5 也继续到 5/5。
- 正常 `workflow:boss -- --send` 必须由同一 owner / 同一进程连续跨 wave 执行到 5/5，不允许因为一个 wave 返回、一次工具调用结束、普通 timeout/CDP/network 瞬时错误而把业务任务停在 1/5～4/5。
- 桌面入口采用**单批次 5/5 生命周期**：一次正常双击只负责一个 owner。若启动时发现上一 owner 尚未完成，则继续同一 owner / checkpoint 到 5/5；若上一 owner 已完成 5/5 + owner-bound `Production Close`，本次启动才创建新的 owner。当前批次 5/5 + `Production Close` 后脚本必须退出，禁止在同一次桌面启动里自动滚到下一 owner。每个 5/5 都保持独立 owner、checkpoint、Production Close 和永久 records 审计边界。
- `Production Close` 只验证当前批次业务终态：真实 5/5、同 owner `TERMINAL_HOLD`、无 pending、workflow/send lock 已释放、5 条物理 records 唯一、永久 records 无重复、current-rules final audit 仍有效。完整 `finalize:boss` 的 typecheck/tests/replay 属于开发/发布深度验收，必须保留，但连续 Production 不得每 5 条都重复跑完整开发回归。
- 只有外部明确授权 early handoff 时，才允许恰好 3/5 交接；4/5 永远不是完成。
- 时间预算、搜索次数多、zero-progress、普通工具超时都不是“完成”的理由；如果平台当前确实不存在足够的安全合格供给，只能报告 `DISCOVERY_EXHAUSTED` 为未完成阻塞，绝不能伪报完成。

## 2. 账号安全硬门（不可为提速放宽）

- 只使用页面可见控件，不使用隐藏接口、WebSocket、MQTT 或私有协议发送。
- 同一时刻只允许一个 workflow owner；发送严格串行，不并行开多个 BOSS 自动化发送链路。
- 桌面连续模式本身必须持有独立 `.boss-continuous.lock`；第二个连续 supervisor 必须在创建新 batch、Finalize/Close 或启动 canonical workflow 前被拒绝。该 supervisor 锁不能替代 workflow/send lock，也不得抢删活动 workflow/send lock。
- 任意两次真实自动页面切换至少间隔 20 秒；连续模式同时限制任意滚动 120 秒内最多 5 次真实自动页面切换。
- 任意两次成功联系至少间隔 240 秒。
- 验证码、操作频繁、登录失效、账号限制、页面安全结构无法确认时立即安全暂停，不绕过。
- 连续模式遇到硬门、人工停止、不可安全自动恢复错误、真实 discovery exhausted、显式 early handoff 或状态矛盾时必须明确显示：当前进度、停止原因、是否涉及账号安全、已自动处理内容和需要用户处理的下一步；不得只输出无法理解的通用 FAILED/HOLD 后静默退出。
- `records/boss-live-status.json` 是连续模式的人类可读 Read Model；它可以汇总 owner、5/5 进度、账号安全状态、当前阶段、自动处理和用户下一步，但不得成为任何发送/去重/资格判断的写入事实源。
- 240 秒冷却期间可以继续只读搜索、本地过滤、详情验证和草稿准备，但不能发送。

## 3. Production Run pause / resume 生命周期

- 正常 short transaction 到期但目标未完成属于 `TRANSACTION_BOUNDARY`，不是账号安全暂停；它必须绑定同一 owner 和同一 checkpoint 世代，并由 canonical workflow 自身在取得独占 workflow lock 后完成正式 resume transition。
- canonical resume 只能发生在目标未完成、checkpoint 非终态、owner/target/关联时间一致、无 send lock、当前进程独占 workflow lock，且 pause 明确属于可恢复 transaction boundary 时。
- `SAFETY_HOLD`（验证码、操作频繁、真实登录失效、账号限制或发送安全不确定）、`MANUAL_HOLD`、`TERMINAL_HOLD` 一律不得自动解除。`ERROR_HOLD` 默认也 fail closed；普通 browser/CDP/network/renderer runtime failure 可在同 owner 下有界恢复。`PAUSED`/`READY_TO_SEND` 只能在无 send lock 时恢复并重新走 Final Audit；`SENDING` 中断绝不能盲目重发，只允许在重新拉起同一专属 Chrome、登录态稳定、workflow/send lock 均释放后，通过 records + detail + recruiter + chat 可见证据完成 ambiguous-send reconciliation 后再恢复。任何证据不足、真实登录失效、平台安全提示或结构不确定仍 fail closed。
- `COMPLETED_5` 与显式授权形成的 `EARLY_HANDOFF_3` 是冻结终态；同 owner 不得重新打开。`DISCOVERY_EXHAUSTED` 也不得被当作普通 transaction boundary 自动重跑，必须先形成新的显式搜索/业务计划。
- 旧 pause/checkpoint 只有在能可靠证明属于旧 short-transaction boundary 时才兼容迁移；任何未知、矛盾、损坏状态 fail closed。
- orphan/stale workflow lock 由既有显式锁恢复流程处理；canonical workflow 不得一边启动一边抢删残留锁。
- 禁止外部 Agent、shell/Python/watchdog 直接改 `boss-workflow-pause.json` 来续跑；也禁止建立第二套 transaction loop/controller。
- DevSpace/宿主工具中，带 `--send` 的 canonical workflow 命令只允许作为一次真实 transaction 启动调用。启动后不得通过“重复提交同一条带 `--send` 命令”来轮询 session，因为宿主可能把轮询误判为新的外部发送动作。运行中状态优先通过 `bun run preflight:boss`、workflow/send lock、checkpoint、records 和 queue 做纯只读观察；Windows 进程枚举仅是辅助诊断，不是安全启动的必要前置。workflow 使用原子 `wx` 文件锁，sender 使用原子目录锁；因此即使宿主不允许进程枚举，第二个 canonical runner 也必须在取得业务控制权前被锁拒绝。只有 workflow/send lock 均释放且 checkpoint/pause 状态允许续跑时，才允许同 owner 发起下一 canonical transaction；如果启动瞬间另一个 runner 抢先取得锁，本次启动必须 fail closed 并退出。

## 4. 永久去重与永久黑名单

- `records/contacted-jobs.json` 是跨账号共用的永久去重事实源。
- 任意历史账号只要已经联系过同一 `jobId` 或同一公司，后续所有账号永久跳过。
- 已联系职位/公司不得再次打开沟通入口、发送默认问候或补发个性化消息。
- 永久排除以下公司及名称变体：
  - 嘉兴九州文化传媒
  - 九州文化传媒
  - 九州传媒
- 不因不同公司出现同名招聘者而误判为重复；招聘者同名只能在同公司会话内用于身份核验。

## 5. 地域与招聘者活跃

- 只联系杭州、嘉兴岗位；嘉兴优先，其次杭州。
- `searchCity` 只是搜索上下文，最终必须以职位详情真实工作地址为准。
- 招聘者必须从页面可见文字明确确认最近 72 小时内活跃；无法确认则不发送。

## 6. 优先联系的岗位

核心原则：AI 是岗位主体或核心业务能力，且现有实践可以迁移；不要求 JD 每一项都完全满足。

优先尝试：

- AI 产品经理 / AI 产品助理
- AI 项目助理 / AI 项目协调
- AI 实施 / 交付 / 解决方案 / 业务落地
- Agent / 智能体应用、配置、调试、业务落地
- RAG / 企业知识库
- Dify / Coze / 扣子 / n8n 的应用、配置、工作流搭建与落地
- Prompt / 提示词优化
- AI 工作流、AI 工具运营/支持/落地、AI 业务应用
- 轻开发、简单脚本、工具接入属于辅助能力而非岗位核心研发的 AI 岗位

注意：Dify/Coze/Agent **平台应用、配置、实施可以联系**；如果岗位本质是底层平台开发、框架/Runtime/Infra 研发或要求独立重代码开发，则排除。

## 7. 永久/明确排除方向

- 数据标注、训练数据采集、录入、审核
- 纯客服、售后客服
- 纯销售、电话销售、招商、获客、地推、投流、以成交/回款为核心的岗位
- 直播、短剧/漫剧、批量 AI 图文/视频/生图等低价值内容流水线
- 重算法研发、模型训练/微调、预训练、底层模型研发
- 要求独立承担重后端/前端/Python/Java/Go/C++ 工程开发的岗位
- 机器人训练、具身智能训练等明显不符合当前目标的方向
- 明确要求 5 年以上且不可放宽的硬经验门槛
- 明确硕博硬要求或当前资料完全不具备、无法迁移的专业硬门槛
- 明确杭州/嘉兴以外的实际工作地

## 8. 不要过度过滤

- 3–5 年经验本身不是拒绝理由；可迁移则进入详情检查。
- 用户资料中学历/正式工作年限字段为空，只代表未知，不代表不满足。
- Search 卡片摘要没有显式写 AI/Agent/RAG，只代表“证据未知”，不能仅凭这一点永久拒绝。
- 只有卡片已经明确证明非目标职业、普通非 AI 同词漂移、硬经验/学历/城市不符、黑名单或历史重复时，才应在打开详情前 cheap reject。
- 普通非 AI 岗位不能因为搜索词里带 AI，或标题里出现“配置 / 项目助理 / 智能”等模糊词就被放行；最终详情必须证明 AI 是岗位主体或核心职责。

## 9. 吞吐量原则

- Search 的目的只是尽快找到可验证候选，不是把搜索次数本身做大。
- 正常每个 discovery wave 默认最多 12 个高价值 query，随后必须依据真实 new/detail/eligible/final-valid 产出重新规划；禁止先把完整 city×keyword 空间机械扫完再转化。
- Queue 中已有可行动候选时优先转化，不重复 Search。
- 若没有 STRONG/MEDIUM 卡片，但已经有至少 2 个未命中硬拒绝的 plausible 弱证据候选，应先做 bounded detail probe，再继续大范围 Search。
- 240 秒发送冷却必须与 Search、详情验证、草稿准备重叠使用；不得在冷却期间纯等待。
- 普通 CDP/network/renderer/页面瞬时失败采用同 owner 有界自动恢复，不应直接结束整个 5-contact 业务批次。
- 正常供给下不再以 15–25 分钟作为硬吞吐目标；当前优先账号安全与稳定性。240 秒成功联系间隔决定了从第 1 条到第 5 条本身至少需要约 16 分钟，页面 pacing 还会增加额外时间；优化重点是减少无效搜索/空转，而不是压缩安全间隔。
- 详情阶段、招聘者活跃、真实工作地址、永久去重、聊天历史和 Final Audit 仍保持原硬门；提高吞吐量只能通过减少无效搜索/导航和过早 false negative 实现，不能通过降低发送安全门实现。
