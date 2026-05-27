---
title: "第 03 篇：Agent Loop —— 为什么必须是 async generator，不能是普通 async function"
slug: 03-agent-loop-async-generator
date: 2026-05-28
series: harwork-agent-harness
series_index: 3
keywords: [Agent Loop, async generator, AbortController, AI Agent 架构, Claude Code 源码]
prev: 02-harwork-stack-overview
next: 04-context-compaction-5-tiers
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/03-agent-loop-async-generator.md
---

# 第 03 篇：Agent Loop —— 为什么必须是 async generator，不能是普通 async function

> [!NOTE]
> **TL;DR**
> - Agent Loop 同时被四个约束撕扯——流式 / 异步 / 可中断 / 可分支——任意两个叠加，普通 `async function` 就开始打架。
> - `async function*`（async generator）是 JavaScript 里把**控制流**和**数据流**用一个关键字统一起来的最小原语——`yield` 不是"返回"，是"暂停"。
> - Claude Code、Cursor、HarWork 不约而同选了 async generator——**不是它最强，而是它最不会让你后悔**。

**章节跳转：**[问题](#问题陈述) · [朴素方案](#朴素方案为什么不行) · [核心方案](#核心方案async-generator) · [实现要点](#关键实现要点) · [反直觉结论](#反直觉结论) · [生产陷阱](#async-generator-在生产中的三个陷阱)

第 01 篇我给了一个 20 行的 Loop 骨架。HarWork 真实的 `agent/loop.ts` 是 640 行——差出来的 620 行，没有一行是"逻辑"，全是为了让那 20 行**在断线、超窗、并发、中断时不崩**。本文要回答的问题是：为什么 Loop 必须用 `async function*`，普通 `async function` 会死在哪一步？

## 问题陈述

写一个 Agent Loop 看起来很简单——"调 LLM，看有没有 tool_use，有就执行工具，没有就退出"。第 01 篇我就是这么写的。

但真实场景下，Loop 同时面对**四个互相打架的约束**：

1. **流式**：LLM 是 token-by-token 吐出来的。你必须**边收边发**给前端，不能等整段攒齐——否则用户看着一个空白屏幕等 10 秒，体验直接崩。
2. **异步**：每个工具调用都是异步的，可能是 50ms 的内存查询，也可能是 5 分钟的 `pnpm install`。Loop 不能阻塞，得让上层（WebSocket / UI）一边等工具一边干别的。
3. **可中断**：用户按 Ctrl-C、关浏览器、超时——任何时刻都可能要求"立刻停"。停的时候不能留半截的子进程、半写的文件、半提交的事务。
4. **可分支**：工具结果回灌后，LLM 可能继续调更多工具（一轮多 tool）；也可能调子 Agent（Agent 工具开一个嵌套 Loop）。深度不可预知。

四个约束任意叠两个，普通 `async function` 就开始打架了。

## 朴素方案为什么不行

我把四种最常见的 Loop 实现都试过一遍，每种都死在不同的地方。

**方案一：`while (true) { msgs.push(await callLLM(...)); ... }`** ——同步阻塞的循环。问题是 `await callLLM()` 必须等整段返回才能继续——LLM 吐 1000 个 token 你就等满整段时间，前端在屏幕上看到的只能是"一段完整文本突然冒出来"。流式约束直接挂掉。

**方案二：Promise 链 + `.then` 回调**——把每一步串起来。代码迅速变成意大利面条：错误处理散在七八个 `.catch` 里，`abortSignal` 没法穿透到内层调用栈（你得给每个 `.then` 单独传 signal），重试逻辑需要把整条链复制一遍。第二个工具就开始无法维护。

**方案三：状态机（XState、自己实现的 FSM）**——把每个状态显式声明。听起来漂亮，但实际上"等 LLM 流"、"等工具结果"、"等中断信号"是三个并发等待，不是顺序状态。一个状态里要 await 三个 Promise.race，状态机本身的代码量就超过业务逻辑。再加一个工具，状态爆炸。

**方案四：RxJS / Observable**——能流式、能并发、能 backpressure。但社区熟悉度太低，新人加入项目要花两周学 Observable 的冷僻 operator。Claude Code 团队、Cursor 团队、Aider 团队都没选这条路，背后是同样的理由：**调试痛、堆栈难读、生态分裂**。

四种方案的共同问题：它们都把"循环的控制流"和"输出的数据流"绑在一起了。`while + return` 只能输出一次；`.then` 只能往后传一次；状态机里"输出"是 side effect。但 Agent Loop 的本质是——**一个会一边运行一边吐数据的过程**，这个形态在 JavaScript 里恰好有个专门的语言原语：`async function*`。

## 核心方案：async generator

来 30 秒入门一下 `async function*`（async generator）。它和普通 `async function` 的唯一区别是：

- 普通 `async function` 用 `return` 一次性返回一个 Promise
- `async function*` 用 `yield` 多次返回值，返回的是一个**异步迭代器**（AsyncIterator）

调用方用 `for await ... of` 消费它：

```typescript
async function* counter() {
  for (let i = 0; i < 3; i++) {
    await new Promise(r => setTimeout(r, 1000))
    yield i  // 每秒吐一个数字
  }
}

for await (const n of counter()) {
  console.log(n)  // 0, 1, 2，分别在 1s/2s/3s 时打印
}
```

关键洞察：`yield` 不是"返回"，是"暂停"。Generator 把局部变量、循环位置、await 状态全部保留下来，等下次调用 `.next()` 时恢复。这意味着 Loop 可以写成线性代码，但每一步的输出都即时流给消费者。

把 Agent Loop 改写成 async generator，骨架变成：

```typescript
async function* agentLoop({ messages, tools, abortSignal }) {
  while (true) {
    if (abortSignal.aborted) return                    // ① 顶层中止检查
    await compress(messages)                           // ② 上下文压缩

    for await (const chunk of llmStream(messages)) {   // ③ 流式 LLM
      yield { type: 'text_delta', text: chunk }        //    每个 token 立即吐出
    }

    const toolCalls = extractToolCalls(messages)
    if (!toolCalls.length) {                           // ④ 没工具调用 = 结束
      yield { type: 'message_complete' }
      return
    }

    yield* executeTools(toolCalls, abortSignal)        // ⑤ 工具执行子 generator
    // ⑤ 的 yield* 把子 generator 的事件透传给上游
  }
}
```

为什么这个形态正好抗住了四个约束？

- **流式天然**：`yield` 把每个 token 直接送给消费者（WebSocket），零中间缓冲；前端在 token 进入 LLM provider 的瞬间就能看到字。
- **中断天然**：每轮顶端检查 `abortSignal`，不需要给每个 await 传 signal；中断后 `return`，generator 自动清理栈。
- **背压天然**：如果 WebSocket 写得慢（用户网络差），消费方 `for await` 卡住，生产方 `yield` 自动等——LLM 的下一段 token 不会堆积在内存里。
- **测试天然**：`generator → toArray` 一行把所有事件收下来，然后断言每个 event 的顺序和内容。HarWork 的 `loop.test.ts` 就这么写的。

更关键的是——**子 generator 可以用 `yield*` 委托**。当 Agent 调用 Agent 工具（嵌套 sub-agent），sub-agent 自己是一个 async generator，外层 Loop 用 `yield* runSubAgent(...)` 一行把子事件流接上来。递归深度不限，调用栈不爆。

## 关键实现要点

HarWork 的 `packages/engine/src/agent/loop.ts` 是 640 行。我把骨架和 20 行版本一对比，多出来的 620 行干了五件事：

**1. 多层重试与回退（line 32-33, 211-220）**

```typescript
const MAX_RETRIES = 3
const RETRY_BASE_DELAY_MS = 1000

// 出错时 yield 一个 retry 事件，前端能展示"第 2 次重试中..."
yield { type: 'retry', attempt, maxAttempts: MAX_RETRIES, retryInMs: delay, error: err.message }
await sleepWithAbort(delay, context.abortController.signal)
```

注意 `sleepWithAbort`——连"等下次重试"这件事都是可中断的。如果用户在重试间隔里按了 Ctrl-C，sleep 立刻返回，Loop 在下一轮顶端检测到 abort 后退出。

**2. 上下文预算与压缩触发（line 102-128）**

```typescript
const MAX_OUTPUT_RESERVE = 8_000
const AUTOCOMPACT_BUFFER = 13_000
const effectiveBudget = contextWindow
  ? contextWindow - MAX_OUTPUT_RESERVE - systemPromptTokenEstimate - AUTOCOMPACT_BUFFER
  : undefined

if (currentTokens >= budget * 0.85 && messages.length > 10) {
  // 触发 L5 语义压缩（调 LLM 摘要旧消息）
}
```

第 04 篇会详细拆这 5 层压缩。这里只看一个事实：**压缩判断在 LLM 调用之前**——避免"压缩本身把窗口撑爆"的悖论。

**3. Hook 生命周期触发（line 116-120, 325-354）**

```typescript
// 压缩前触发 PreCompact hook，第三方可以阻止压缩
const hookGen = context.executeHooks('PreCompact', compactInput)
let hookResult = await hookGen.next()
while (!hookResult.done) {
  yield hookResult.value   // hook 自己的输出也流给上游
  hookResult = await hookGen.next()
}
```

Hook 本身也是 generator——hook 的事件无缝拼接进主 Loop 的事件流。前端看到的"工具调用前停顿审批"，就是 hook generator 在中间 yield 了一个等待事件。

**4. 工具执行的子 generator（line 405-416）**

```typescript
for await (const event of executeTools(internalToolCalls, tools, context, ...)) {
  yield event                          // 透传给上游
  if (event.type === 'tool_call_result') {
    toolResults.push({...})            // 同时收集进 messages
  }
}
```

`executeTools` 是另一个 async generator，里面处理工具并发、`isConcurrencySafe` 分组、单工具中断（详见第 05 篇）。主 Loop 用 `for await` 一边透传事件、一边收集结果——这是 async generator 唯一能干净表达"流式输出 + 结果聚合"的地方。

**5. 9+ 种事件类型，都靠 `yield` 吐**

HarWork 的 Loop 一共会 yield 这些事件类型（来自 `StreamEvent` 联合类型）：`text_delta` · `thinking_delta` · `tool_call_start` · `tool_call_result` · `usage_update` · `message_complete` · `retry` · `error` · `hook_event`。WebSocket 层不需要懂 Loop 内部状态，它只负责把 generator 的输出原样转发到前端——`for await (const e of loop()) { ws.send(JSON.stringify(e)) }`，**第 13 篇会展开这条事件流的完整映射**。

## 反直觉结论

> [!IMPORTANT]
> **`yield` 不是"输出"，是"暂停"。**
>
> Agent Loop 真正难的不是"循环本身"，而是"把循环之间发生的事情（流式 token、工具结果、压缩、中断、重试、hook）做成可暂停可观测"。async generator 是目前 JavaScript 里**最便宜的实现**——一个语言关键字，零外部依赖。

换种说法：**Agent Loop 的本质不是一个"算法"，是一种"事件流形态"**。你可以用状态机、Observable、回调金字塔写出同样行为，但代码量会膨胀 3-5 倍，可读性掉到 30%，调试一个 NPE 要打 6 个断点。换用 async generator，整个 Loop 是一段从上往下读的线性代码，每个 `yield` 是一个观察点，每个 `await` 是一个可中断点。这是为什么 Claude Code、Cursor、HarWork 不约而同选了 async generator——**不是它最强，而是它最不会让你后悔**。

更进一步：**async generator 同时定义了"控制流"和"数据流"**。`for await` 既能让你顺序执行，又能让数据按顺序流出。普通 async function 只能让你顺序执行；Observable 只能让数据流出但控制流隐式。两件事用一个原语表达，调试时栈帧、断点、错误堆栈全部对齐——这是它最大的工程价值。

## async generator 在生产中的三个陷阱

理论说完，给三个 HarWork 真实踩过的坑——你迟早也会踩：

> [!WARNING]
> **陷阱一 — `for await` 提前 break，generator 未必清理。**
>
> 如果消费方在 generator 还有未完成的 await 时退出循环，generator 会卡在那个 await 上，永远不释放。**HarWork 的修复**：给所有阻塞 await 都接 `abortSignal`，generator `return()` 时信号触发，内部 await 抛 AbortError 立刻退出。

> [!WARNING]
> **陷阱二 — `yield` 之后，generator 暂停的状态会持有所有局部变量。**
>
> 如果你在 yield 之前持有了一个大对象（比如 50 MB 的 grep 结果 buffer），yield 暂停期间内存不会释放。**HarWork 的修复**：工具结果先写入磁盘 attachment，messages 里只存"前 500 字 + attachment_id"，避免长 yield 卡住内存（详见第 04 篇 L2 压缩层）。

> [!WARNING]
> **陷阱三 — 错误从 generator 抛出的位置不直观。**
>
> 在 `yield` 之后抛错，错误堆栈指向的是消费方的 `for await`，不是 generator 内部的真正出错行。**HarWork 的修复**：在每个可能抛错的位置都先 `yield { type: 'error', code, message }`、然后再 `return`——错误成了数据，不再依赖 throw 机制。

这三个陷阱合起来想表达的事：**async generator 不是免费的**——它把"控制流 + 数据流"用最简洁的语法表达出来，但代价是你必须理解暂停语义、生命周期、错误传播这三件事。如果你只会用普通 async function，硬切 generator 半年内会有六次"莫名其妙的 hang 死"事故。

## 配图

1. ![四种 Loop 方案对比](../assets/img/03-loop-approaches.svg)
2. ![Agent Loop 单轮 11 步时序图](../assets/img/03-loop-timeline.svg)
3. ![AbortSignal 传播树](../assets/img/03-abort-propagation.svg)

## 下一篇

→ [第 04 篇：上下文工程 —— 5 层压缩的真实触发条件](./04-context-compaction-5-tiers.md)

下一篇我们钻进第 16 层栈的第 4 层。第 01 篇承诺过的"5 层渐进压缩"，第 04 篇要用 HarWork 真实代码（`compression.ts` + `llm-compact.ts` + `memory.ts`）把每一层的触发阈值、压缩烈度、实测压缩率全部列出来——你会看到为什么"压缩本身不能消耗预算"才是这套系统的灵魂。

---

📌 系列阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/03-agent-loop-async-generator.md](../en/03-agent-loop-async-generator.md)
