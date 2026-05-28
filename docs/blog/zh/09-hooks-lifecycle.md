---
title: "第 09 篇：Hook 生命周期 —— 8 种事件如何安全跑用户代码"
slug: 09-hooks-lifecycle
date: 2026-06-30
series: harwork-agent-harness
series_index: 9
keywords: [hooks, lifecycle, PreToolUse, PostToolUse, agent extensibility, webhook, agent customization, hook timeout, HOOK_INPUT, agent harness]
prev: 08-permissions-sandbox
next: 10-session-storage
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/09-hooks-lifecycle.md
---

# 第 09 篇：Hook 生命周期 —— 8 种事件如何安全跑用户代码

> 第 08 篇把"LLM 不能做什么"框住了。这一篇切到另一面：用户怎么在 LLM 做事的**正中间塞自己的代码**——commit 前跑 lint、Edit 完触发 prettier、UserPromptSubmit 注入项目上下文、SessionEnd 给 Slack 发通知。Claude Code 通过 settings.json 把这套能力做成了主流，HarWork 用 1277 行 TypeScript 把这套生命周期落到自己的 agent loop 上：8 个事件、shell 命令 + HTTP webhook、并行执行、聚合"最严格优先"。**这一篇拆的不是"hook 怎么调"，而是"agent loop 怎么在不打断自己的情况下安全调用别人的代码"。**

**章节跳转：**[问题](#问题陈述) · [朴素方案](#朴素方案为什么不行) · [8 个事件](#核心方案8-个事件--容器内执行) · [实现要点](#关键实现要点) · [反直觉](#反直觉结论) · [生产坑](#三个生产坑)

## 问题陈述

让用户在 agent loop 里塞自己的代码听起来简单，做起来要解决至少 5 个问题：

1. **在哪儿插？** —— PreToolUse 之前？PostToolUse 之后？Compact 触发前？Session 启动后？事件点必须**枚举完备**，否则用户想插的位置插不进。
2. **跑在哪？** —— Engine 进程里？用户容器里？host shell？跑错地方就要么没权限要么直接出安全事故。
3. **怎么传数据进去？** —— stdin / 命令行参数 / env var？怎么传回来？stdout / 退出码 / JSON？
4. **跑挂了怎么办？** —— 用户写的脚本 timeout、网络 hook 504、JSON 解析失败——hook 出错不能让主流程崩。
5. **多个 hook 同时触发同一个事件怎么办？** —— 一个 hook 说 allow，另一个说 deny；一个改了 input，另一个也改了——必须有明确的**聚合规则**。

5 个问题缺一不可。HarWork 的回答全在 `packages/engine/src/hooks/`（**1277 行 TypeScript / 7 个文件**），核心是：**8 个枚举事件 + HOOK_INPUT env var 注入 + 退出码 + JSON 协议双信道 + Promise.all 并行 + 最严格优先聚合 + output 强制 clamp**。

## 朴素方案为什么不行

**朴素一：让用户写一段 JS callback 注册到 agent**。听起来灵活——但 callback 跑在 Engine 进程里，写错一行 `process.exit(1)` 整个 agent 就挂了，更别说访问任意全局变量。**进程内 callback 没有故障隔离**。

**朴素二：把 hook 配置成一个 URL，每次事件都 POST 过去**。听起来干净，但每个 hook 都 HTTP 一趟意味着至少 10-50ms 延迟 × 每个工具调用 2 次（Pre/Post）× 100 个调用 = 几秒钟的额外延迟。**强制网络往返不能作为唯一形态**。

**朴素三：把 hook 跑在 host shell**。`bash -c "user-script.sh"` 在 Engine 所在机器跑——但 Engine 部署在你的服务器上，用户脚本不能碰 host filesystem。**host shell 就是越权**。

**朴素四：同一事件多个 hook 串行跑**。串行简单——但 8 个 PreToolUse hook 每个 200ms 就是 1.6 秒，且第一个 hook 卡住会拖死所有后续工具调用。**串行不能 scale**。

**朴素五：只支持退出码（0/1）传信号**。0 = 成功、非 0 = 失败——但 hook 要传"我要 deny 这次调用"、"我改了 input"、"我有 additional context 要追加给 LLM"。**退出码语义不够用**。

HarWork 的方案：**事件枚举（8 个）+ 容器内执行（complete isolation）+ HOOK_INPUT/stdout 双信道（command）或 HTTP（webhook）+ Promise.all 并行 + 最严格聚合（deny > ask > allow）+ output clamp（防 OOM）**。

## 核心方案：8 个事件 + 容器内执行

### 8 个事件触发点（`types.ts:10-19` + 5 个调用点）

| 事件 | 触发点 | 输入字段 | 用途示例 |
|---|---|---|---|
| `SessionStart` | `ws-server.ts:170` | source: 'startup' \| 'resume' | 项目 README 注入 |
| `UserPromptSubmit` | `ws-message-handlers.ts:465` | user_prompt | 注入项目上下文、deny 危险问题 |
| `PreToolUse` | `tool-executor.ts:546` | tool_name, tool_input | 自定义权限、改写参数 |
| `PostToolUse` | `tool-executor.ts:646` | tool_name, tool_input, tool_response | 触发 prettier、运行 lint |
| `PostToolUseFailure` | `tool-executor.ts:628` | tool_name, tool_input, error | 错误上报到 Sentry |
| `Stop` | `loop.ts:334` | (无额外字段) | LLM 主回合结束后 hook |
| `PreCompact` | `loop.ts:129` | trigger: 'auto' \| 'manual' | 压缩前归档完整对话 |
| `SessionEnd` | `ws-server.ts:259` | reason | 资源清理、通知 |

**8 个事件覆盖了 agent loop 的完整生命周期**——从 session 启动到结束、从用户输入到工具调用、从压缩到停止。新加事件意味着改 enum + 改类型 + 找到正确的 yield 点——**不能私自扩展，因为 LLM 不知道有新事件**。

### Layer 1：HOOK_INPUT 注入（`executor.ts:182-188`）

shell 命令的输入怎么传？HarWork 不用 stdin（容易被命令本身吃掉），不用命令行参数（容易因为 quoting 出 bug），而是 **env var**：

```typescript
const jsonInput = JSON.stringify(input)
// 用 escapeShellArg 包一层，防止 jsonInput 里的特殊字符破坏 shell
const wrappedCommand = `export HOOK_INPUT=${escapeShellArg(jsonInput)}; ${hook.command}`
execResult = await executor.exec(wrappedCommand, {
  cwd: input.cwd,
  timeout: timeoutMs,
  signal,
})
```

用户写的脚本里只要 `echo "$HOOK_INPUT" | jq '.tool_name'` 就能拿到事件输入。**这一行包装是整个 hook 系统的 happy path**——简单到出错都难。

`executor.exec()` 是用户容器的 exec（第 04 篇讲 Docker/K8s 时讲过），所以 hook 命令**跑在和 LLM 调用 Bash 同一个容器**——用户脚本可以访问 /workspace 下的所有文件，但碰不到 host。

### Layer 2：退出码 + JSON 协议双信道（`executor.ts:227-243`）

hook 想"否决"这次调用怎么办？两条信道：

**信道 A：退出码**

```typescript
if (exitCode === 0) {
  outcome = blockingError ? 'blocking' : 'success'
} else if (exitCode === 2) {
  outcome = 'blocking'  // ← Claude Code 约定：2 表示 blocking
  if (!blockingError) {
    blockingError = {
      blockingError: stderr || stdout || 'Blocked by hook (exit code 2)',
      command: hook.command,
    }
  }
} else {
  outcome = 'non_blocking_error'  // ← 其他非 0 退出 = "hook 自己挂了，但不阻断主流程"
}
```

**0=成功 / 2=阻断 / 其他=hook 自己挂了**——这套语义是 Claude Code 的开源约定，HarWork 照抄。**关键设计：非 0 非 2 ≠ 阻断**，因为 hook 本身的故障不能拖死 agent loop。

**信道 B：JSON stdout**

stdout 如果是 JSON 而且以 `{` 开头，会被解析成 `HookJSONOutput`（`types.ts:183-197`）：

```typescript
interface HookJSONOutput {
  continue?: boolean  // false → preventContinuation
  decision?: 'approve' | 'block'
  reason?: string
  hookSpecificOutput?: {
    permissionDecision?: 'allow' | 'deny' | 'ask'
    permissionDecisionReason?: string
    additionalContext?: string  // ← 追加给 LLM 的上下文
    updatedInput?: Record<string, unknown>  // ← 改写 LLM 的输入
  }
}
```

`additionalContext` 让 hook 给 LLM "悄悄塞"一段话（"用户的项目是 monorepo，跑 pnpm 不要 npm"）；`updatedInput` 允许直接改 LLM 的工具参数（LLM 写 `npm install`，hook 改成 `pnpm install`）。**这是 hook 系统真正"塞自己代码"的地方**——不只是 deny/approve，而是参与到 LLM 的决策里。

### Layer 3：并行 + 最严格聚合（`executor.ts:352-410`）

同一事件多个 hook，Promise.all 并行：

```typescript
const results = await Promise.all(
  matchedHooks.map(({ hookName, hook }) =>
    executeSingleHook(hook, event, `${event}:${hookName}`, input, executor, signal, resolveSecret),
  ),
)
```

聚合规则——**冲突时最严格优先**：

```typescript
const behaviors = results.filter((r) => r.permissionBehavior).map((r) => r.permissionBehavior!)
if (behaviors.includes('deny')) aggregated.permissionBehavior = 'deny'
else if (behaviors.includes('ask')) aggregated.permissionBehavior = 'ask'
else if (behaviors.includes('allow')) aggregated.permissionBehavior = 'allow'

// updatedInput 只取第一个
const firstUpdated = results.find((r) => r.updatedInput)
if (firstUpdated) aggregated.updatedInput = firstUpdated.updatedInput

// additionalContexts 全保留，但用 clampAdditionalContexts capped
const rawContexts = results.filter((r) => r.additionalContext).map((r) => r.additionalContext!)
const contexts = clampAdditionalContexts(rawContexts)
```

三种聚合策略对应三种语义：
- **permissionBehavior：最严格优先**——`deny > ask > allow`，谁都能否决（防止用户把允许 hook 写在第一个就放行所有危险操作）。
- **updatedInput：第一个赢**——多个 hook 都改 input 不合并，避免冲突推测。
- **additionalContext：全保留但 capped**——`HOOK_MAX_ADDITIONAL_CONTEXT_ITEMS=8` 个、`HOOK_MAX_ADDITIONAL_CONTEXT_TOTAL_CHARS=32768` 字符（`output-limits.ts:13-14`），防 prompt injection 把 LLM context 撑爆。

## 关键实现要点

5 个非显然细节：

**1. hook 跑在用户容器里，不是 Engine 进程**

很多人第一反应是"在 Engine 里跑 child_process.exec 不就好了"——错。Engine 跑在你的服务器上，用户 hook 命令如果在 Engine 里跑：

- ✗ 用户脚本能读 Engine 自己的 .env（爆密钥）
- ✗ 用户脚本能 kill 其他用户的 hooks
- ✗ 用户脚本能写 host filesystem

HarWork 通过 `executor.exec()` 把 hook 推进**用户专属容器**——和 LLM 跑 Bash 共享同一个容器、同一个 /workspace。**hook 和 LLM 是"同一个隔离单位的两种身份"**，权限完全对等。

**2. timeout 是 60 秒，不是 30**

`executor.ts:39`：

```typescript
const DEFAULT_HOOK_TIMEOUT_S = 60  // 单位是秒，× 1000 = 毫秒
```

HTTP hook 的 timeout 是 10 秒（`http-hook.ts:26`）——shell 命令给得更宽松，因为可能跑 npm install 这种慢操作。**hook 可以 per-command override**：DB row 里的 `timeout` 字段直接覆盖默认值。

**3. HTTP hook 的 secret 占位符（`http-hook.ts:30 + 38-59`）**

```typescript
const SECRET_PLACEHOLDER_RE = /\$([A-Z][A-Z0-9_]*)/g
// hook.headers = { Authorization: "Bearer $SLACK_TOKEN" }
// 实际请求：Authorization: Bearer xoxb-real-token
```

`resolveSecret(secretName)` 回调由 storage 注入——把秘密**留在 DB**，hook 配置只存占位符。这是把"机密访问能力"和"hook 配置能力"分开的关键——用户能配 hook，但配 hook 时看不到真 token。

**4. once: true 的 session hook（`session-hooks.ts:removeOnceHooks`）**

```typescript
// 普通 hook 走 DB，session hook 走内存
addSessionHook(sessionId, event, hook, { once: true })
// 执行后：
removeOnceHooks(sessionId, event)  // ← 把 once=true 的从内存里清掉
```

这给了"一次性 hook"——比如"下次 Bash 执行后给我 Slack 通知"，执行完自动清。**session hook 不入库**，会话结束随 RAM 释放——天然防止 hook 配置堆积。

**5. updatedInput 大小限制 + 序列化检查（`output-limits.ts:29-51`）**

```typescript
const serialized = JSON.stringify(updatedInput)
if (serialized.length <= HOOK_MAX_UPDATED_INPUT_CHARS) {  // 16384 字符
  return { value: updatedInput, dropped: false }
}
return { value: undefined, dropped: true, reason: 'oversize' }
```

hook 想改 input？可以，但超过 16K 字符就丢弃（防止恶意 hook 把整个 LLM context 塞满垃圾）；用 try/catch 包 JSON.stringify 防 circular reference 让 Engine 崩。**所有 output 都强制 clamp**——hook 不能因为输出膨胀让 Engine OOM。

## 反直觉结论

> [!IMPORTANT]
> **Hook 系统的核心不是"扩展性"，是"故障隔离"。** 进程隔离（跑在用户容器）、超时隔离（60s 强制 kill）、输出 clamp（防 OOM）、错误聚合（hook 自己挂了不阻断主流程）——**4 层隔离都在防"用户脚本把 agent 拖死"**。只有把"用户代码"当成对抗性输入对待，hook 系统才能在生产环境长期稳定。

换句话说：**"非 0 退出 ≠ 阻断"是关键设计**。用户脚本 segfault、写错语法、找不到命令——所有这些都不应该让 LLM 停下来。**只有显式 `exit 2` 或显式 `{"decision": "block"}` 才是真的"我要阻断"信号**。把"故障"和"阻断"在协议层就分开，才能让 hook 系统进生产。

最反直觉的：**hook 跑在用户容器里**——大多数人会把 hook 实现成 "Engine 里 child_process.exec"，但那样一来 hook 就成了用户和 Engine 之间的安全漏洞。HarWork 把 hook 推进**用户专属容器**让它和 LLM 站在同一权限基线上——**hook 和 LLM 同根**。

## 三个生产坑

> [!WARNING]
> **陷阱一 —— hook 配置不带 timeout 默认值。**
>
> `timeout: undefined` 直接传给 fetch / exec——exec 会一直等，hook 卡住整个 agent loop。HarWork `DEFAULT_HOOK_TIMEOUT_S = 60`、`DEFAULT_HTTP_TIMEOUT_S = 10` 都是**强制的下限**，配置 row 没设也得有默认。

> [!WARNING]
> **陷阱二 —— 把 additionalContext 合并到一个大 string。**
>
> N 个 hook 各自返回 100 字符的 context，合并成一个 N×100 的大块——LLM 看不出哪段是哪个 hook 的，prompt 也变难调。HarWork 保留**列表结构**（`additionalContexts: string[]`），上限是数量 + 总字符两条线（`output-limits.ts:13-14`）。

> [!WARNING]
> **陷阱三 —— hook stdout 当成"日志"打到 console。**
>
> 用户脚本 `cat /etc/passwd` 直接打到 Engine 日志——内容被泄露到运维人员的日志查询面板。HarWork `clampHookText(stdout, HOOK_MAX_STDOUT_CHARS)` 限制到 64KB，且 `hook_progress / hook_result` stream event 限制到 2KB（`HOOK_STREAM_EVENT_MAX_CHARS=2000`）——**有意识地把"hook 输出"和"系统日志"分开**。

## 配图

1. ![8 个 hook 事件在 agent loop 上的触发点](../assets/img/09-hook-events-timeline.svg)
2. ![Engine 容器 vs 用户容器：hook 跑在哪](../assets/img/09-hook-execution-boundary.svg)
3. ![退出码 + JSON 协议双信道 + 聚合规则](../assets/img/09-hook-aggregation.svg)

## 下一篇

→ 第 10 篇：Session 持久化 —— Conversation / Container / Hook 状态都存哪

Hook 系统讲完，下一篇我们看"持久化"——HarWork 跨会话保存了什么、靠什么存。SQLite + Drizzle ORM、conversation 表 / message 表 / hook 表的关系、抽象掉存储后端的 storage interface、加载 / 增量更新 / 软删除策略——以及为什么 session 状态（permissionMode、sessionHooks、abortController）反而**不入库**。

---

📌 系列阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/09-hooks-lifecycle.md](../en/09-hooks-lifecycle.md)
