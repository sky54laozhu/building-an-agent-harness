---
title: "Part 18：复盘 —— 49 天独立造 Harness 的得与失"
slug: 18-49-day-retro
date: 2026-09-01
series: harwork-agent-harness
series_index: 18
keywords: [solo founder retrospective, agent harness, harwork, indie developer, full stack AI, 49 days, technical debt, tech selection, postmortem, 独立开发, AI 平台, 工程复盘]
prev: 17-enterprise-cicd
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/18-49-day-retro.md
---

# Part 18：复盘 —— 49 天独立造 Harness 的得与失

> 系列收尾不该讲"我多牛"，应该讲"我下次会怎么不一样"。49 天、287 commits、60.7K 行代码、110 个测试、18 篇博客 + 54 张配图 —— 这就是 HarWork 一人作战的全部数字。这一篇不引代码不画 P95，只交付 **4 件做对的 / 5 件做错的 / 4 个选型反悔 / 4 个一人取舍**，外加系列收尾清单：阅读地图、关键词索引、致谢、联系方式。**诚实坦白是这套系列长尾流量的最后一根支柱**。

**章节跳转：**[时间线](#一时间线真实-git-log不是回忆) · [做对的](#二4-件做对的) · [做错的](#三5-件做错的) · [选型反悔](#四4-个选型反悔哪些回头看正确) · [一人取舍](#五4-个一人作战的取舍) · [反直觉](#反直觉结论) · [收尾清单](#系列收尾清单)

## 一、时间线（真实 git log，不是回忆）

```
2026-04-08  76d6456  Add HarWork product design spec       ← Day 1：先写 spec
2026-04-09  1496e4b  feat: scaffold pnpm monorepo          ← Day 2：第一行代码
2026-04-10  5559052  feat(engine): permission system 1A    ← Day 3：权限系统起步
2026-04-23  113a94c  feat: complete Phase 1 gaps           ← Day 16：Phase 1 收尾
2026-04-24  d53b4e9  docs: add Phase 3 implementation plan ← Day 17：拐点（设计阶段 2 跳 3）
2026-04-30  Phase 3 完成日                                  ← Day 23：单日 32 commits
2026-05-12  e8aebed  docs: Design Phase 1 MVP plan         ← Day 35：设计模块上马
2026-05-13  设计模块爆炸日                                  ← Day 36：单日 38 commits（全系列峰值）
2026-05-14  7c629a8  feat(design): PDF/PPTX export         ← Day 37：设计模块收口
2026-05-26  1de057d  docs: blog series execution plan      ← Day 49：决定写博客
```

49 天的曲线不是匀速 —— **137 commits 在 4 月、150 commits 在 5 月**，但 4 月的 commits 主要是 Phase 0-3 主干，5 月一半给了设计模块（commit 数据出自 `git log --pretty=format:'%ad' --date=format:'%Y-%m' | sort | uniq -c`）。**这不是"按周冲刺"，是"按主题井喷"**：Phase 跳转的那 2-3 天每天 20+ commits，主题之间的间隙每天 1-2 commits 写文档。

提交类型分布（来自 `git log --pretty=format:'%s' | grep -oE '^[a-z]+'`）：

| 类型 | 数量 | 占比 |
|------|------|------|
| feat | 178 | 62% |
| fix | 53 | 18% |
| docs | 32 | 11% |
| schema/test/infra/refactor/chore/security | 24 | 9% |

**62% feat / 18% fix = 3.4:1 比例**。教科书说"健康项目 feat:fix 应 1:1"——但那是协作团队。一人项目里 fix 大多是"自己写自己改的小修补"，不需要单独追踪、merge 进同一个 feat commit 即可，所以 fix 比例偏低不代表质量差，**代表测试覆盖到位 + 重构债被合并提交吸收**。

## 二、4 件做对的

**1. 从一开始就用 async generator 写 Loop（Part 03）。** 49 天里架构没改过 —— 这是回头看最值的判断。**`async function*` 让"边产生边消费"成为类型层强制契约**：消费者必须 `for await (const event of loop())`，生产者必须 `yield event`，背压 / 暂停 / cancel 直接靠 generator 天然语义。如果 Day 1 选了 EventEmitter，Day 49 必有重构 —— 跨进程 / WS 透传 / 中断恢复都要手撸状态机。**架构债的判断标准是"3 个月后还在不在改"——async generator 没改 = 选对了**。

**2. Adapter 模式提前抽象 DB / Workspace（Part 10）。** 49 天里 SQLite 没换、Workspace 还是 Docker volume —— 但 `DbAdapter` 接口（`packages/engine/src/db-storage.ts`）让"SQLite → PostgreSQL"是 1 周工程量、不是 1 个月重写。**Adapter 抽象的真正价值不在切换、在心理保险**：知道能切，比切了更重要 —— 不会因为"扛不住要重写"而过早优化。

**3. 测试金字塔从 Day 3 就建（110 个测试）。** Engine 单元测试 + Web 集成测试 + 关键路径 e2e —— Phase 3 改 Phase 1 代码时，**110 个测试拦住了 7 次破坏性改动**（看 `git log --grep='fix.*test'` 全是"改 Phase 1 时测试发现"的修复）。如果没测试，Phase 3 改 Phase 1 = 整个系统重新走 QA。**测试金字塔不是"为了 80% 覆盖率"，是"为了能放心改老代码"**。

**4. CLAUDE.md 早立规则。** Day 5 写了 `CLAUDE.md` 规定 "preserve existing architecture / minimal patches / no destructive ops"，**这让 AI 协助开发的 49 天里没发生"AI 大改架构"事故**。文档不是给人看的，**是给 AI 看的协作契约**——这是 2026 年 AI 协助开发的新工程实践。

## 三、5 件做错的

**1. 早期 `admin/page.tsx` 1233 行单组件膨胀。** 路径依赖："加一个 tab 就 + 100 行"，最终积累到 1233 行。后来拆成 `admin-triggers-tab.tsx`（233 行）等，但**重构债真实存在过**。教训：**"加 tab" 这种线性扩张场景必须 Day 1 就用 sub-component 分文件**，不能等 5 个 tab 后再拆。当前最大单文件 `message-bubble.tsx` 694 行 —— 还在但已经在重构计划。

**2. SQLite 单文件并发瓶颈。** 设计模块（Part 14-16）高频写 annotation / design-edit 时已经看到 `SQLITE_BUSY` 错误零星出现 —— 单写锁是结构性限制，不是 tuning 能救。**应该 Day 35 设计模块上马时就切 PostgreSQL**，而不是拖到博客系列结束。

**3. 单分支无 PR 流程。** 一人项目省事但**给未来协作埋了坑**：没有 PR review = 没有审视自己代码的强制时刻 + 没有 commit 之间的设计讨论沉淀。下一个 49 天必须开 PR 流，**哪怕 reviewer 只是另一个 AI agent**。

**4. OpenAPI 字段级 schema 没做全。** API 路由有 zod 校验，但**没生成 OpenAPI spec**，客户端类型只能手写 + 偶尔不同步。当前 `packages/web/lib/api-types.ts` 是手维护的——这是技术债的典型 "都知道该做但都没做" 项。

**5. 错误监控只做 webhook，没接 Sentry。** Engine 的错误 → webhook → 内网 IM，足够个人开发用，**但长尾错误（间歇性 / 难复现 / 多 step trace）没法定位**。Sentry 接入工作量 1 天，但拖到现在还没做。

## 四、4 个选型反悔（哪些回头看正确）

| 决策 | 当时选 | 现在看 | 备注 |
|------|--------|--------|------|
| ORM | Drizzle | ✅ 正确 | 类型推导比 Prisma 好，无 codegen 依赖 |
| 实时通道 | WebSocket | ✅ 正确 | SSE 单向不够，Part 12 30s 宽限必须双向 |
| Next.js | App Router | ⚠️ 中性 | 早期版本踩 Server Action 坑，但生态留下来值 |
| 运行时 | Node.js | ⚠️ 后悔 | Bun 性能红利没吃到，但 Docker 镜像 + 调试工具熟 |

**最大的"正确"是 Drizzle**：49 天里 schema 改了 30+ 次，没生成代码 = 没卡 codegen 步骤 = 重构 schema 是 30 秒不是 30 分钟。**最大的"后悔"是 Node.js**：不是 Bun 一定更快，是没花 2 天 benchmark 验证 = 留下了"可能错过性能红利"的心理债。

## 五、4 个一人作战的取舍

**没做的事**（清醒舍弃）：
- i18n 多语言完整支持 —— 中文用户优先，英文版只做博客
- 移动端原生 App —— Web responsive 够用，原生工程量太大
- LDAP / 自建 SSO —— 微信 OAuth + 企业 SSO 覆盖 95% 场景
- 完整管理后台 —— admin 只做最小必要（用户管理 + 触发器）

**不该自己写的事**（事后清醒）：
- 限流（应该用 Upstash Rate Limit）—— 自己写的内存 LRU 在多实例下要重写
- 健康探测（应该用 Better Uptime / UptimeRobot）—— 自己 cron + curl 重复造轮子
- 邮件发送（应该用 Resend）—— SMTP 直接打日志 = 调试成本爆炸

**必须自己写的事**（核心竞争力）：
- Agent Loop（Part 03）—— Cursor 都不开源，没人能给你
- 上下文压缩（Part 04）—— 商业模型差异化点
- 工具协议（Part 07）—— Claude Code 的 Bash/Read/Edit 契约也是自定义

**判断标准**：能用现成方案的全用，**核心循环 + 数据结构 + 协议接口必须亲手写**。这条线在 49 天里反复划过 —— 写权限系统时纠结过用 Casbin，最后选了"3 层防御自己写"（Part 08），现在看是对的；但写限流没纠结直接自己写，现在看后悔。

## 六、下一步（自我提醒，不是 PR 时间表）

1. **把这套系列写完**（18 篇，剩 0 篇，这就是最后一篇）
2. **Engine 拆开源 npm 包** —— 让 `@harwork/agent-loop` 单独可被嵌入
3. **找 1-2 位早期付费企业** —— 验证 SaaS 路径，不是融资
4. **不做**：融资 / 组团队 / Web3 + AI / 多模态生成

**核心是"不做"清单比"做"清单长**。49 天能跑出 60K 行是因为持续在砍 scope，**不是因为效率高**。

## 反直觉结论

> [!IMPORTANT]
> **49 天独立造 Harness 的真正秘诀不是"高效率"，是"高拒绝率"。**
>
> 我拒绝了完整管理后台、拒绝了 i18n、拒绝了移动端、拒绝了 LDAP、拒绝了 Bun 迁移、拒绝了 PostgreSQL 切换、拒绝了 Sentry、拒绝了 OpenAPI gen —— 49 天的产出全在"没拒绝的那 1/3 scope"。**一人项目的天敌不是"做不完"，是"什么都想做"**——独立开发者的核心技能是 say no，不是 code fast。

更反直觉的：**fix:feat 1:3.4 不代表质量好，代表"自己测自己改"的回环紧**。教科书 1:1 是给"PR review 把关 / QA 找 bug / 用户报 bug"的协作流程留出比例 —— 一人项目的 fix 大多在 feat commit 内部就消化了，统计上看不见。**所以一人项目的健康度不能拿团队指标套**，要看的是"3 个月前的代码现在还信不信" —— Day 3 的 `agent-loop.ts` 现在我还信，**这才是质量信号**。

最反直觉的工程结论：**做对的 4 件全是 Day 1-5 的决定（async generator / Adapter / 测试 / CLAUDE.md），做错的 5 件全是 Day 10+ 的路径依赖（admin 膨胀 / SQLite 没切 / 无 PR / OpenAPI 没生成 / Sentry 没接）**。**项目早期 5 天的架构决策权重 ≈ 后面 44 天工程决策的总和**——这不是"早起优化"，是"早期不优化无法收回"。下一个 49 天我会把 Day 1-5 的预算从 10% 提到 25%。

## 系列收尾清单

### ① 系列阅读地图（推荐顺序）

| 板块 | 篇 | 标题 | 一句话摘要 |
|------|----|----|----------|
| 立论 | 01 | [Agent Harness 是什么](01-what-is-agent-harness.md) | 7 个组件让裸 LLM 变成可信赖的 agent |
| 立论 | 02 | [HarWork 技术栈全景](02-harwork-stack-overview.md) | 16 层架构 / 双形态 Engine / 包依赖 |
| 核心循环 | 03 | [async generator Loop](03-agent-loop-async-generator.md) | 为什么不用 EventEmitter |
| 核心循环 | 04 | [5 层上下文压缩](04-context-compaction-5-tiers.md) | 阈值瀑布而非单阈值 |
| 核心循环 | 05 | [工具编排](05-tool-orchestration.md) | 两阶段调度 + 兄弟中断传播 |
| 核心循环 | 06 | [长期记忆](06-long-term-memory.md) | CLAUDE.md 加载链 + 3 路径 |
| 工具体系 | 07 | [工具系统](07-tool-system.md) | 9 方法接口 + Read/Edit 契约 |
| 沙箱安全 | 08 | [权限沙箱](08-permissions-sandbox.md) | 3 层防御矩阵 |
| 沙箱安全 | 09 | [Hooks 生命周期](09-hooks-lifecycle.md) | 事件时间线 + 聚合 |
| 会话存储 | 10 | [会话存储](10-session-storage.md) | 30 表 schema / 持久 vs 运行时 |
| 会话存储 | 11 | [持久 Docker](11-persistent-docker.md) | pause/stop 差异 + 闲置清扫 |
| 会话流式 | 12 | [WebSocket 30s 宽限](12-websocket-30s-grace.md) | 500 事件环形缓冲 |
| 会话流式 | 13 | [多模型路由](13-multi-model-routing.md) | 流统一 / 计价 / 注册表 |
| 设计协作 | 14 | [AI artifact 渲染](14-ai-artifact-rendering.md) | iframe overlay + postMessage |
| 设计协作 | 15 | [多版本对比 + 混搭](15-design-variants-mix.md) | 3 出 1 选 |
| 设计协作 | 16 | [乐观锁实时协作](16-optimistic-lock-collab.md) | 为什么 AI artifact 不能用 CRDT |
| 研发上线 | 17 | [企业级 CI/CD](17-enterprise-cicd.md) | canary + 多探针自动回滚 |
| 复盘 | 18 | [49 天复盘](18-49-day-retro.md) | **本篇** |

### ② 关键词索引

- **核心循环**：agent loop, async generator, context compaction, tool orchestration, long-term memory（Part 03-06）
- **工具沙箱**：tool interface, permission matrix, hooks, sandbox（Part 07-09）
- **会话流式**：session storage, persistent docker, websocket grace, multi-model routing（Part 10-13）
- **设计协作**：iframe overlay, design variants, optimistic locking, CRDT, share token（Part 14-16）
- **研发上线**：canary deployment, P95 latency, multi-probe rollback, solo founder DevOps（Part 17-18）

### ③ 数据兑现

- **真实代码**：60,700 行（engine 12,988 + web 36,627 + 其它 ~11K）
- **真实测试**：110 个
- **真实 commits**：287 个
- **真实周期**：49 天（2026-04-08 → 2026-05-26）
- **博客产出**：18 篇 / 54 张 SVG / 中文 ~18 万字 / 英文 ~4 万词

### ④ 致谢

- **Anthropic Claude Code 团队** —— 把 agent harness 工程范式公开化了
- **Cursor / Aider / Continue.dev 团队** —— 让"AI 协助开发"成为日常
- **Drizzle / Next.js / shadcn/ui** —— 让一人也能造产品级 UI
- **中文工程社区**（V2EX / 即刻 / Twitter 中文圈）—— 早期反馈与批评

### ⑤ 联系方式

- GitHub: [sky54laozhu/building-an-agent-harness](https://github.com/sky54laozhu/building-an-agent-harness)（这套博客的源仓库）
- HarWork 产品（在线体验）：http://47.107.103.144/
- 邮件：sky54laozhu@163.com（不放微信 / 微信群）

## 配图

1. ![49 天 commits/day 真实分布图](../assets/img/18-commits-per-day.svg)
2. ![代码行数分模块累积曲线](../assets/img/18-loc-cumulative.svg)
3. ![选型反悔矩阵 · 4 项决策回溯](../assets/img/18-tech-regret-matrix.svg)

---

📌 阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/18-49-day-retro.md](../en/18-49-day-retro.md)

**系列完。感谢读到这里的你 —— 如果有任何一篇让你少踩一个坑，这 49 天就值了。**
