---
title: "第 04 篇：上下文工程 —— 5 层压缩的真实触发条件"
slug: 04-context-compaction-5-tiers
date: 2026-05-29
series: harwork-agent-harness
series_index: 4
keywords: [上下文压缩, context compaction, LLM 窗口, Claude Code 源码, Agent 长对话]
prev: 03-agent-loop-async-generator
next: 05-tool-orchestration
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/04-context-compaction-5-tiers.md
---

# 第 04 篇：上下文工程 —— 5 层压缩的真实触发条件

> 第 03 篇说 Agent Loop 每轮第一件事是 `await compress(messages)`。这一篇要回答：**这个 compress 到底干了什么**？为什么 Claude Code、Cursor、HarWork 跑几百轮对话不爆窗口？答案不是「一个聪明的摘要算法」，而是**5 层在不同时机、用不同代价、做不同烈度的压缩组合**。本文用 HarWork 的 `compression.ts`（378 行）+ `llm-compact.ts`（133 行）把每层的真实触发阈值与压缩率全部摊开。

**章节跳转：**[问题](#问题陈述) · [朴素方案](#朴素方案为什么不行) · [5 层](#核心方案5-层叠加) · [实现要点](#关键实现要点) · [反直觉](#反直觉结论) · [生产坑](#三个生产坑)

## 问题陈述

让 Agent 跑长对话有两件硬伤：

1. **工具结果太大**——一次 `grep -r` 可能返回 8 万行，一次 `cat large.log` 可能 200KB。这些原文塞回 messages，2-3 次就把窗口撑爆
2. **历史太长**——50 轮以上的对话本身就有几万 token，即使每次工具结果都不大，累积也会过线

最朴素的策略——**「超了就丢旧消息」**——立刻让 Agent 失忆：可能丢掉的就是 5 轮前用户说的核心需求。Claude Code 的「对话永不溢出」印象不是靠运气，是 5 层渐进压缩堆出来的：**前 4 层不调 LLM**（不花钱不延迟），只有最严重的时候才调 L5（LLM 语义摘要）。

## 朴素方案为什么不行

我把所有「一招式」压缩策略都试过，每个都在某个场景下崩盘。

**朴素方案一：FIFO 丢旧消息**——「超了就把最早的扔掉」。问题是旧消息里常常藏着用户最初的需求陈述（「我们要做一个 OAuth2 登录」），丢掉之后 LLM 在第 30 轮突然问「请问我们在做什么功能？」——上下文连贯性直接死亡。

**朴素方案二：全局摘要**——每 N 轮调一次 LLM 把所有历史压成 200 字。问题是 LLM 调用本身要花 token + 几秒延迟，而且摘要时机选不准：太早→损失细节；太晚→已经溢出了再调，prompt-too-long 报错。

**朴素方案三：纯滑窗**——只保留最近 10 条消息。问题与 FIFO 同源，且滑窗丢掉的是**完整对话**，不是「冗余信息」——同样会把核心需求丢掉。

**朴素方案四：只压工具结果**——只截断超大的 `tool_result`，不管对话历史。问题是当对话本身（用户描述 + assistant 推理）就吃了 80% 窗口时，截工具结果救不了局。

四种方案的共同问题：**它们都试图用一种策略解决所有场景**。但「压缩」面对的是四种不同形状的膨胀——单条消息过大、工具结果连发、历史累积、突然超预算——每种形状需要不同的处理方式。

## 核心方案：5 层叠加

HarWork 的压缩链按「**便宜的先做、贵的最后做**」排序：

| 层 | 触发条件 | 烈度 | 调 LLM？ | 代码位置 |
|----|---------|------|---------|---------|
| **L1 Micro** | 单个 `tool_result` > 8KB | 截断为头 2KB + 尾 1KB | 否 | `compression.ts:142` |
| **L2 Snip** | 单消息中 ≥ 4 个连续 `tool_result` | 折叠为系统摘要（每条 100 字预览） | 否 | `compression.ts:166` |
| **L3 Auto** | `messages ≥ 10` 且 `tokens ≥ budget × 0.7` | 旧消息总结成一条 system message，保留最近 8 条原样 | 否（规则提取） | `compression.ts:239` |
| **L4 Reactive** | `tokens > budget`（已经超了！） | 暴力清除旧 tool_result、文本截 500 字 | 否 | `compression.ts:310` |
| **L5 LLM-Compact** | `tokens ≥ budget × 0.85` 且 `messages > 10` | 调 LLM 用 9 段语义摘要 | **是** | `llm-compact.ts:43`、`loop.ts:115` |

**关键洞察**：

- **L1-L4 都是 O(N) 字符串处理，零 LLM 调用**——意味着每轮 Loop 顶端 compress 几乎不花钱、不花时间
- L5 的阈值（0.85）**高于** L3（0.7）——L3 先用规则压一遍，如果还不够再让 L5 砸钱压
- L4 是「兜底」，专门处理「L1-L3 都做完了但还是超」的场景，直接暴力到丢失部分信息

来逐层拆。

### L1 Micro — 8KB 截断

```typescript
const MICRO_MAX_CHARS = 8192    // 8KB
const MICRO_HEAD_CHARS = 2048   // 头 2KB
const MICRO_TAIL_CHARS = 1024   // 尾 1KB

if (block.type === 'tool_result' && block.content.length > MICRO_MAX_CHARS) {
  const head = block.content.slice(0, MICRO_HEAD_CHARS)
  const tail = block.content.slice(-MICRO_TAIL_CHARS)
  return { ...block, content: `${head}\n\n... [${truncated} characters truncated] ...\n\n${tail}` }
}
```

针对场景：单次工具调用返回了超大输出（`cat` 一个 log、`grep` 一个大仓库）。**保头保尾是关键**——头部通常是元数据/错误信息，尾部通常是结论/最新条目，中间是重复内容。直接砍中间的 5KB，LLM 仍能理解工具做了什么。

触发频率：在跑代码任务的对话里这一层经常命中——主要来自 Bash 长输出和 Read 大文件。

### L2 Snip — 连发折叠

```typescript
const SNIP_MIN_TOOL_RESULTS = 4

// 当一条 user 消息里有 ≥4 个 tool_result 块（即一轮 LLM 调了 ≥4 个工具）
// 把它折叠成一条 system 摘要，每个 tool_result 只保留前 100 字预览
return {
  type: 'system',
  content: `[Compressed ${msg.content.length} tool results]\n${summaries.join('\n')}`,
  isCompactSummary: true,
}
```

针对场景：LLM 一轮调了 4 个 Read、5 个 Glob、6 个 Grep——结果回灌后 messages 里出现「user 消息里有 15 个 tool_result」。这种连发模式特别浪费 token，因为 LLM 已经基于这些结果做完决策，老结果只是「证据」。

L2 把整条消息折成一行系统摘要，搭配 L1（如果单条还 >8KB），可以把一个典型「扫描型 turn」从「上万 token」量级压回「几千 token」量级。

### L3 Auto — 旧消息规则摘要

```typescript
const AUTO_MIN_MESSAGES = 10
const AUTO_TOKEN_RATIO = 0.7
const AUTO_KEEP_RECENT = 8

if (opts.enableAuto && result.length >= AUTO_MIN_MESSAGES) {
  if (currentEstimate >= opts.maxTokenBudget * AUTO_TOKEN_RATIO) {
    // 把前 (N-8) 条压成一条 system 摘要，保留最近 8 条原样
  }
}
```

针对场景：对话已经超过 10 轮、token 占用突破 70%——这是「应该开始压历史了」的早期信号。L3 用**纯规则**提取每条消息的精华（user 的 text 取前 200 字 + tool_result 计数；assistant 的 text 取前 300 字 + tool_call 计数），拼成一条 system 摘要消息。

为什么不调 LLM？因为 L3 是**频繁触发的**——一旦突破 70% 阈值，每轮都会再次触发（除非用户开了新话题让占用回落）。如果每轮都调一次 LLM 摘要，本身就要烧几千 token + 几秒延迟。规则摘要虽然损失语义细节，但**保住了对话骨架**——足够 LLM 维持上下文连贯，剩下的细节用户在新轮次问起时还能引用原消息恢复。

### L4 Reactive — 已经超预算的兜底

```typescript
if (estimateTokens(result) > opts.maxTokenBudget) {
  // 暴力模式：把所有旧消息的 tool_result content 替换为 "[result truncated: N chars]"
  // 把所有 text 块超过 500 字的截到 500 字
  // 把所有 tool_use 的 input 替换为 "[truncated]"
}
```

针对场景：L1-L3 都做完了，估算 token 仍然超过预算——典型情况是 system prompt 自己就很大（CLAUDE.md + memory 加一起几千字），加上对话历史榨干了剩余空间。

L4 是**有损但救命**的——它直接砍掉 tool_result 的具体内容、把长文本截 500 字。LLM 看到的是「曾经调过这些工具，但结果只剩元数据」。这一层很少触发，但触发即关键——没有 L4，API 会直接返回 `prompt_too_long` 错误。

### L5 LLM-Compact — 语义摘要

```typescript
// 在 loop.ts:115 触发
if (currentTokens >= budget * 0.85 && messages.length > 10) {
  // PreCompact hook 可以否决
  // 调 LLM 用 9 段结构化提示词生成 <analysis>...</analysis><summary>...</summary>
  const { text } = await generateText({
    model,
    system: 'You are a conversation summarizer...',
    prompt: `Here is the conversation to summarize:\n\n${transcript}\n\n---\n\n${getCompactPrompt()}`,
  })
}
```

针对场景：对话已经被 L3 压过一次，但用户继续追问、新工具结果继续累积，占用又冲到 85%——这时 L3 已经救不了局（旧消息早压过了），需要**语义层面的重新组织**。

L5 用一段**精心设计的长 prompt**（提示词单独放在 `compact-prompt.ts`——它与上面触发逻辑所在的 `llm-compact.ts` 是两个文件，恰好都是 133 行），让 LLM 把整段历史压成 9 个结构化段落：① Primary Request and Intent ② Key Technical Concepts ③ Files and Code Sections ④ Errors and fixes ⑤ Problem Solving ⑥ All user messages ⑦ Pending Tasks ⑧ Current Work ⑨ Optional Next Step。

为什么是这 9 段？**因为这是 Claude Code 的开源原型**（HarWork 完整复刻并适配）——这套结构经过 Anthropic 团队在自己产品里跑了上万次对话验证，对「续写代码任务」的语义保留最好。

L5 的代价：调一次 LLM ≈ 烧几千输入 token + 1-2 秒延迟。所以**只有在万不得已**（85% 阈值 + 之前 4 层不够用）才触发。

## 关键实现要点

理论说完，落到 HarWork 真实代码上还有 5 个细节决定生死。

**1. 压缩判断必须在 LLM 调用之前**

`loop.ts:113-115` 顺序：先估算 token → 决定是否压 → 再调 LLM。如果反过来（先调 LLM 报错再压），用户已经付了一次 prompt-too-long 的 token 钱+延迟，而且重试逻辑变复杂。

**2. L1-L4 的幂等性**

`compression.ts:11` 注释明确写了「Each layer is idempotent and can run independently」。意思是：连续跑两次 L1 结果一样、跑 L1 再跑 L2 也一样。这保证 Loop 每轮无脑调 compress 不会越压越短最后空了。

**3. AUTO_KEEP_RECENT = 8 不是拍脑袋**

为什么保留 8 条？因为典型一轮是 user → assistant → tool_results → assistant，4 条算一轮。8 条 = 最近 2 轮 = 用户当前正在做的事 + 上一步反馈。这个数字直接抄了 Claude Code 默认值——你也可以调，但调小到 4 会丢上一轮反馈，调大到 16 会让旧消息总结失去意义。

**4. PreCompact hook 可以阻止 L5**

L5 触发前会调 PreCompact hook（见第 03 篇 hook 生命周期），第三方插件可以 `exit 2` 否决——典型用途：用户开启了「记录完整对话」的合规模式，禁止 LLM 摘要丢失原始内容。

**5. context_compressed 事件 yield 给前端**

L5 完成后，Loop 会 yield `{ type: 'context_compressed', from, to }`（from/to 是 token 数）——前端可以显示「上下文已压缩 12K → 3K，请继续」。这是用户感知压缩存在的唯一时机。

## 反直觉结论

> [!IMPORTANT]
> **上下文压缩不是「一个聪明算法」，是「一组在不同时机用不同代价做不同烈度的策略」。** 任何只讲「摘要算法」的方案都不解决问题——因为关键不是「怎么压」，而是「什么时候压」「该压到什么程度」「该不该花 LLM 调用的钱」。

换种说法：**压缩的本质是「预算管理」，不是「信息论」**。每层压缩都在回答一个具体的预算问题：
- L1：「这一条工具结果该不该值 8KB？」（答：太长就头尾截）
- L2：「这一轮 15 个 tool_result 该不该全保留？」（答：折叠成摘要）
- L3：「整段历史超过 70%，旧的 90% 该不该简化？」（答：规则提取骨架）
- L4：「已经超预算了，要不要砸烂部分历史保命？」（答：要）
- L5：「规则压完还不够，要不要花 2 秒+ 几千 token 让 LLM 重新组织？」（答：在 85% 阈值才划算）

每层都是独立决策、独立阈值、独立可关——HarWork 的 `CompressionOptions` 提供 `enableMicro / enableSnip / enableAuto / enableReactive` 四个开关让你单独调。这是为什么压缩系统能稳定服务上百轮对话的真正原因：**不是某一层有多聪明，而是 5 层互相兜底、独立失效不连锁崩**。

## 三个生产坑

> [!WARNING]
> **陷阱一 — 估算 token 用「字符数 / 4」会低估 30%。**
>
> HarWork 的 `estimateTokens` 在 `compression.ts:108` 用 `CHARS_PER_TOKEN = 4` 估算——对中文文本会低估很多（中文 token 化大约 1.5 字符/token）。**HarWork 的修复**：保留 13K 的 `AUTOCOMPACT_BUFFER`（见第 03 篇 effectiveBudget 公式）作为安全垫，宁可早压一些。

> [!WARNING]
> **陷阱二 — L2 Snip 会把工具调用对断开。**
>
> `compression.ts:197-216` 有一段「同时压上一条 assistant 的 tool_use」的代码——因为 Anthropic API 要求 `tool_use` 和 `tool_result` 必须配对，否则会报错 `tool_use_id mismatch`。如果你只压结果不动 tool_use，API 会拒绝整个请求。HarWork 早期版本就栽过这个坑。

> [!WARNING]
> **陷阱三 — L5 调 LLM 时如果用户中断，状态会卡住。**
>
> L5 的 `generateText` 调用接了 `abortSignal`——但如果用户在 L5 进行到一半按 Ctrl-C，已经发出去的 prompt 还是会被计费。**HarWork 的处理**：L5 不重试（与 LLM 主调用的 3 次重试不同），失败立刻 fallback 到「跳过本轮压缩、让 L4 在下一轮 yield error 之前救场」。

三个陷阱共同的教训：**压缩系统的所有数字（8KB / 0.7 / 0.85 / 8 条）都不是普适最优值，是 HarWork 在生产数据上微调过的「足够好的妥协」**。你换一种 LLM、换一种对话场景（短问答 vs 代码生成），这些数字都该重新校准。

## 配图

1. ![5 层压缩瀑布图](../assets/img/04-compaction-waterfall.svg)
2. ![触发阈值数轴](../assets/img/04-thresholds-axis.svg)
3. ![压缩前后对比](../assets/img/04-before-after.svg)

## 下一篇

→ [第 05 篇：工具调用编排 —— 并行 / 串行 / 中断](./05-tool-orchestration.md)

下一篇我们从「上下文如何不爆」走到「工具如何不打架」。LLM 一轮可能输出 8 个工具调用，编排器决定哪些并行（Read × 3 一起跑）、哪些串行（Edit 必须排队）、哪些能在出错时中断。第 05 篇会用 HarWork `tool-executor.ts` 真实代码展开「`isConcurrencySafe` 自报家门 + 编排器兜底」的两段式调度。

---

📌 系列阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/04-context-compaction-5-tiers.md](../en/04-context-compaction-5-tiers.md)
