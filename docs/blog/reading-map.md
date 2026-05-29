# HarWork Agent Harness 系列阅读地图

> **18 篇 / 54 张 SVG / ~18 万中文字 / ~4 万英文词 / 49 天独立开发的工程沉淀**
>
> 数据兑现：287 commits · 60,444 LOC · 110 测试 · 2026-04-08 → 2026-05-26

## 中文版 · 推荐阅读顺序

| 板块 | 篇 | 标题 | 一句话 |
|------|----|------|--------|
| **立论** | 01 | [Agent Harness 是什么](zh/01-what-is-agent-harness.md) | 7 个组件让裸 LLM 变成可信赖的 agent |
| | 02 | [HarWork 技术栈全景](zh/02-harwork-stack-overview.md) | 16 层架构 / 双形态 Engine / 包依赖 |
| **核心循环** | 03 | [async generator Loop](zh/03-agent-loop-async-generator.md) | 为什么不用 EventEmitter |
| | 04 | [5 层上下文压缩](zh/04-context-compaction-5-tiers.md) | 阈值瀑布而非单阈值 |
| | 05 | [工具编排](zh/05-tool-orchestration.md) | 两阶段调度 + 兄弟中断传播 |
| | 06 | [长期记忆](zh/06-long-term-memory.md) | CLAUDE.md 加载链 + 3 路径 |
| **工具沙箱** | 07 | [工具系统](zh/07-tool-system.md) | 9 方法接口 + Read/Edit 契约 |
| | 08 | [权限沙箱](zh/08-permissions-sandbox.md) | 3 层防御矩阵 |
| | 09 | [Hooks 生命周期](zh/09-hooks-lifecycle.md) | 事件时间线 + 聚合 |
| **会话存储** | 10 | [会话存储](zh/10-session-storage.md) | 30 表 schema / 持久 vs 运行时 |
| | 11 | [持久 Docker](zh/11-persistent-docker.md) | pause/stop 差异 + 闲置清扫 |
| **会话流式** | 12 | [WebSocket 30s 宽限](zh/12-websocket-30s-grace.md) | 500 事件环形缓冲 |
| | 13 | [多模型路由](zh/13-multi-model-routing.md) | 流统一 / 计价 / 注册表 |
| **设计协作** | 14 | [AI artifact 渲染](zh/14-ai-artifact-rendering.md) | iframe overlay + postMessage |
| | 15 | [多版本对比 + 混搭](zh/15-design-variants-mix.md) | 3 出 1 选 |
| | 16 | [乐观锁实时协作](zh/16-optimistic-lock-collab.md) | 为什么 AI artifact 不能用 CRDT |
| **研发上线** | 17 | [企业级 CI/CD](zh/17-enterprise-cicd.md) | canary + 多探针自动回滚 |
| **复盘** | 18 | [49 天复盘](zh/18-49-day-retro.md) | 得失 / 反悔 / 系列收尾 |

## English · Recommended Order

| Section | # | Title | One-liner |
|---------|---|-------|-----------|
| **Thesis** | 01 | [What is an Agent Harness](en/01-what-is-agent-harness.md) | 7 components turn a bare LLM into a trustworthy agent |
| | 02 | [HarWork Stack Overview](en/02-harwork-stack-overview.md) | 16-layer architecture / dual-form Engine / package deps |
| **Core Loop** | 03 | [async generator Loop](en/03-agent-loop-async-generator.md) | Why not EventEmitter |
| | 04 | [5-tier context compaction](en/04-context-compaction-5-tiers.md) | Threshold waterfall, not single threshold |
| | 05 | [Tool orchestration](en/05-tool-orchestration.md) | 2-phase scheduling + sibling interrupt propagation |
| | 06 | [Long-term memory](en/06-long-term-memory.md) | CLAUDE.md loading chain + 3 paths |
| **Tools & Sandbox** | 07 | [Tool system](en/07-tool-system.md) | 9-method interface + Read/Edit contract |
| | 08 | [Permission sandbox](en/08-permissions-sandbox.md) | 3-layer defense matrix |
| | 09 | [Hooks lifecycle](en/09-hooks-lifecycle.md) | Event timeline + aggregation |
| **Session Storage** | 10 | [Session storage](en/10-session-storage.md) | 30-table schema / persistent vs runtime |
| | 11 | [Persistent Docker](en/11-persistent-docker.md) | pause/stop diff + idle reaper |
| **Streaming** | 12 | [WebSocket 30s grace](en/12-websocket-30s-grace.md) | 500-event ring buffer |
| | 13 | [Multi-model routing](en/13-multi-model-routing.md) | Stream unification / pricing / registry |
| **Design Collab** | 14 | [AI artifact rendering](en/14-ai-artifact-rendering.md) | iframe overlay + postMessage |
| | 15 | [Variants + remix](en/15-design-variants-mix.md) | 3-out-of-1 |
| | 16 | [Optimistic-lock collaboration](en/16-optimistic-lock-collab.md) | Why AI artifacts can't use CRDT |
| **DevOps** | 17 | [Enterprise CI/CD](en/17-enterprise-cicd.md) | canary + multi-probe auto-rollback |
| **Retro** | 18 | [49-day retrospective](en/18-49-day-retro.md) | What worked, what didn't |

## 按"我想了解 X"反查

- **Agent 内核怎么转**：03 → 04 → 05
- **工具协议怎么定**：07 → 05 → 09
- **怎么不让 LLM 删库**：08 → 07 → 11
- **怎么保住会话**：10 → 11 → 12
- **多模型切换怎么做**：13 → 10
- **AI 生成 UI 怎么渲**：14 → 15 → 16
- **怎么上线不炸**：17 → 18
- **一人项目工程取舍**：18 → 02 → 17

## 关键词索引

- **核心循环**：agent loop, async generator, context compaction, tool orchestration, long-term memory（03-06）
- **工具沙箱**：tool interface, permission matrix, hooks, sandbox（07-09）
- **会话流式**：session storage, persistent docker, websocket grace, multi-model routing（10-13）
- **设计协作**：iframe overlay, design variants, optimistic locking, CRDT, share token（14-16）
- **研发上线**：canary deployment, P95 latency, multi-probe rollback, solo founder DevOps（17-18）

## 系列说明

- **写作周期**：2026-08-04 → 2026-09-01（4 周）
- **代码周期**：2026-04-08 → 2026-05-26（49 天 / 287 commits / 110 测试）
- **真实代码**：60,444 LOC（engine/src 12,988 + web 36,627 + 其它 ~10,829）
- **代码引用基准**：全系列所有 `文件:行号` 引用（如 `loop.ts:115`、`compression.ts:142`）对应 HarWork 源码在 commit [`5c11da1`](https://github.com/sky54laozhu/building-an-agent-harness)（2026-05-26）时的快照;代码持续演进后行号可能漂移几行,以该快照为准。
  _All `file:line` references in this series point to the HarWork source at commit `5c11da1` (2026-05-26); line numbers may drift by a few lines as the code evolves._
- **配图**：54 张原创 SVG（含 `<title>` / `<desc>` 无障碍标注）
- **配套**：[seo-matrix.md](seo-matrix.md) · [publishing-checklist.md](publishing-checklist.md) · [DECISIONS.md](DECISIONS.md)

## 仓库 / 反馈

- 源码仓库：[sky54laozhu/building-an-agent-harness](https://github.com/sky54laozhu/building-an-agent-harness)
- 任何一篇让你少踩一个坑，这 49 天就值了。
