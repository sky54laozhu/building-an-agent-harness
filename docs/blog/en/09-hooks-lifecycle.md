---
title: "Part 09: Hook Lifecycle — 8 events that safely run user code inside the loop"
slug: 09-hooks-lifecycle
date: 2026-06-30
series: harwork-agent-harness
series_index: 9
keywords: [hooks, lifecycle, PreToolUse, PostToolUse, agent extensibility, webhook, agent customization, hook timeout, HOOK_INPUT, agent harness]
prev: 08-permissions-sandbox
next: 10-session-storage
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/09-hooks-lifecycle.md
---

# Part 09: Hook Lifecycle — 8 events that safely run user code inside the loop

> Part 08 framed "what the LLM can't do." This part flips it: how the user **injects their own code into the middle of what the LLM is doing** — lint before commit, prettier after Edit, project context on UserPromptSubmit, Slack notification on SessionEnd. Claude Code popularized this through settings.json; HarWork's 1277-line TypeScript implementation lands the same lifecycle on its own agent loop: 8 events, shell command + HTTP webhook, parallel execution, "most restrictive wins" aggregation. **This part isn't "how to call a hook" — it's "how the agent loop safely calls someone else's code without taking itself down."**

**Jump to:** [Problem](#problem-statement) · [Naive approaches](#why-naive-approaches-fail) · [8 events](#core-solution-8-events--in-container-execution) · [Implementation](#key-implementation-details) · [Counterintuitive](#counterintuitive-conclusion) · [Production pitfalls](#three-production-pitfalls)

## Problem Statement

Letting the user inject code into the agent loop sounds simple but actually solves at least five problems:

1. **Where do you insert?** — Before PreToolUse? After PostToolUse? Before Compact? After Session start? The event points must be **enumerated completely**, or the user can't insert where they want.
2. **Where does it run?** — Engine process? User container? Host shell? Wrong place = either no permission or an instant security incident.
3. **How does data get in?** — stdin / argv / env var? And out? stdout / exit code / JSON?
4. **What if it crashes?** — User scripts time out, HTTP webhooks 504, JSON parsing fails — a hook crash can't crash the main loop.
5. **What if multiple hooks fire on the same event?** — One says allow, another says deny; one rewrites input, another also rewrites — there must be explicit **aggregation rules**.

All five matter. HarWork's answers all live in `packages/engine/src/hooks/` (**1277 lines TypeScript / 7 files**), with the core being: **8 enumerated events + HOOK_INPUT env var injection + exit code + JSON dual signaling + Promise.all parallelism + most-restrictive aggregation + mandatory output clamping**.

## Why Naive Approaches Fail

**Naive 1: let users register a JS callback to the agent.** Sounds flexible — but a callback runs in the Engine process, and one line of `process.exit(1)` brings the whole agent down, not to mention free access to globals. **In-process callbacks have no fault isolation.**

**Naive 2: configure each hook as a URL and POST on every event.** Sounds clean, but every hook means at least 10-50ms × 2 calls per tool (Pre/Post) × 100 calls = several seconds of extra latency. **Mandatory network round-trip can't be the only shape.**

**Naive 3: run hooks in the host shell.** `bash -c "user-script.sh"` runs on the machine hosting Engine — but Engine sits on your server, and user scripts shouldn't touch the host filesystem. **Host shell is privilege escalation.**

**Naive 4: multiple hooks on the same event run serially.** Serial is simple — but 8 PreToolUse hooks × 200ms each = 1.6s, and one stuck hook drags every subsequent tool call. **Serial doesn't scale.**

**Naive 5: only support exit code (0/1) for signaling.** 0 = success, non-zero = failure — but a hook needs to say "I deny this call," "I rewrote the input," "I have additional context for the LLM." **Exit codes aren't expressive enough.**

HarWork's answer: **enumerated events (8) + in-container execution (complete isolation) + HOOK_INPUT/stdout dual channel (command) or HTTP (webhook) + Promise.all parallel + most-restrictive aggregation (deny > ask > allow) + output clamp (OOM defense)**.

## Core Solution: 8 Events + In-Container Execution

### 8 event trigger points (`types.ts:10-19` + 5 call sites)

| Event | Trigger site | Input fields | Example use |
|---|---|---|---|
| `SessionStart` | `ws-server.ts:170` | source: 'startup' \| 'resume' | inject project README |
| `UserPromptSubmit` | `ws-message-handlers.ts:465` | user_prompt | inject project context, deny dangerous questions |
| `PreToolUse` | `tool-executor.ts:546` | tool_name, tool_input | custom permission, rewrite arguments |
| `PostToolUse` | `tool-executor.ts:646` | tool_name, tool_input, tool_response | trigger prettier, run lint |
| `PostToolUseFailure` | `tool-executor.ts:628` | tool_name, tool_input, error | report errors to Sentry |
| `Stop` | `loop.ts:334` | (no extra fields) | hook after LLM's main turn ends |
| `PreCompact` | `loop.ts:129` | trigger: 'auto' \| 'manual' | archive full conversation before compact |
| `SessionEnd` | `ws-server.ts:259` | reason | resource cleanup, notification |

**The 8 events cover the full agent loop lifecycle** — from session start to end, from user input to tool call, from compact to stop. Adding a new event means updating the enum + types + finding the right yield point — **you can't extend it ad hoc, because the LLM doesn't know about new events**.

### Layer 1: HOOK_INPUT injection (`executor.ts:182-188`)

How do you pass input to a shell command? HarWork doesn't use stdin (can be eaten by the command itself), doesn't use argv (fragile due to quoting), but uses **env var**:

```typescript
const jsonInput = JSON.stringify(input)
// escapeShellArg wraps it to prevent special characters in jsonInput from breaking the shell
const wrappedCommand = `export HOOK_INPUT=${escapeShellArg(jsonInput)}; ${hook.command}`
execResult = await executor.exec(wrappedCommand, {
  cwd: input.cwd,
  timeout: timeoutMs,
  signal,
})
```

User scripts only need `echo "$HOOK_INPUT" | jq '.tool_name'` to read the event input. **This one-line wrap is the happy path of the entire hook system** — so simple it's hard to get wrong.

`executor.exec()` is the user container's exec (introduced in Part 04 on Docker/K8s), so hook commands **run in the same container the LLM uses for Bash** — user scripts can access everything under /workspace, but never touch the host.

### Layer 2: exit code + JSON dual signaling (`executor.ts:227-243`)

How does a hook "veto" the call? Two channels:

**Channel A: exit code**

```typescript
if (exitCode === 0) {
  outcome = blockingError ? 'blocking' : 'success'
} else if (exitCode === 2) {
  outcome = 'blocking'  // ← Claude Code convention: 2 means blocking
  if (!blockingError) {
    blockingError = {
      blockingError: stderr || stdout || 'Blocked by hook (exit code 2)',
      command: hook.command,
    }
  }
} else {
  outcome = 'non_blocking_error'  // ← other non-zero = "hook itself crashed, but don't block the main flow"
}
```

**0=success / 2=blocking / other=hook itself crashed** — these semantics come from Claude Code's open convention; HarWork copies them. **Key design: non-zero and non-2 ≠ blocking**, because a hook's own failure shouldn't drag down the agent loop.

**Channel B: JSON stdout**

If stdout is JSON starting with `{`, it's parsed as `HookJSONOutput` (`types.ts:183-197`):

```typescript
interface HookJSONOutput {
  continue?: boolean  // false → preventContinuation
  decision?: 'approve' | 'block'
  reason?: string
  hookSpecificOutput?: {
    permissionDecision?: 'allow' | 'deny' | 'ask'
    permissionDecisionReason?: string
    additionalContext?: string  // ← extra context appended for the LLM
    updatedInput?: Record<string, unknown>  // ← rewrites the LLM's input
  }
}
```

`additionalContext` lets a hook "quietly slip" a line to the LLM ("user's project is a monorepo, use pnpm not npm"); `updatedInput` lets you directly rewrite the LLM's tool arguments (LLM wrote `npm install`, hook rewrites to `pnpm install`). **This is where hooks actually "inject their own code" into the LLM's decision-making** — not just deny/approve, but participating in the LLM's choices.

### Layer 3: parallel + most-restrictive aggregation (`executor.ts:352-410`)

Multiple hooks on the same event run via Promise.all:

```typescript
const results = await Promise.all(
  matchedHooks.map(({ hookName, hook }) =>
    executeSingleHook(hook, event, `${event}:${hookName}`, input, executor, signal, resolveSecret),
  ),
)
```

Aggregation rule — **most-restrictive wins on conflict**:

```typescript
const behaviors = results.filter((r) => r.permissionBehavior).map((r) => r.permissionBehavior!)
if (behaviors.includes('deny')) aggregated.permissionBehavior = 'deny'
else if (behaviors.includes('ask')) aggregated.permissionBehavior = 'ask'
else if (behaviors.includes('allow')) aggregated.permissionBehavior = 'allow'

// updatedInput: first one wins
const firstUpdated = results.find((r) => r.updatedInput)
if (firstUpdated) aggregated.updatedInput = firstUpdated.updatedInput

// additionalContexts: keep all but capped
const rawContexts = results.filter((r) => r.additionalContext).map((r) => r.additionalContext!)
const contexts = clampAdditionalContexts(rawContexts)
```

Three aggregation strategies map to three semantics:
- **permissionBehavior: most-restrictive wins** — `deny > ask > allow`, anyone can veto (prevents users from putting an allow hook first to wave through dangerous ops).
- **updatedInput: first wins** — multiple hooks that rewrite input aren't merged, avoiding speculation about conflicts.
- **additionalContext: keep all but cap** — `HOOK_MAX_ADDITIONAL_CONTEXT_ITEMS=8` items, `HOOK_MAX_ADDITIONAL_CONTEXT_TOTAL_CHARS=32768` chars (`output-limits.ts:13-14`), preventing prompt injection from blowing out the LLM context.

## Key Implementation Details

Five non-obvious details:

**1. Hooks run in the user container, not the Engine process**

Most people's first instinct: "just `child_process.exec` in Engine." Wrong. Engine runs on your server, and if hook commands ran inside Engine:

- ✗ user script could read Engine's own .env (secret leak)
- ✗ user script could kill other users' hooks
- ✗ user script could write the host filesystem

HarWork uses `executor.exec()` to push the hook into the **user's dedicated container** — sharing the container, /workspace, and permissions with the LLM running Bash. **Hooks and the LLM are "two roles within the same isolation unit"**, with fully equivalent privileges.

**2. Timeout is 60s, not 30**

`executor.ts:39`:

```typescript
const DEFAULT_HOOK_TIMEOUT_S = 60  // seconds, × 1000 = ms
```

HTTP hook timeout is 10s (`http-hook.ts:26`) — shell commands get more headroom because they might run npm install. **Hooks can override per-command**: the `timeout` field on the DB row supersedes the default.

**3. HTTP hook secret placeholders (`http-hook.ts:30 + 38-59`)**

```typescript
const SECRET_PLACEHOLDER_RE = /\$([A-Z][A-Z0-9_]*)/g
// hook.headers = { Authorization: "Bearer $SLACK_TOKEN" }
// actual request: Authorization: Bearer xoxb-real-token
```

`resolveSecret(secretName)` callback is injected by storage — secrets stay **in the DB**, hook config only stores placeholders. This separates "secret access ability" from "hook configuration ability" — users can configure hooks without seeing the real token.

**4. once: true session hooks (`session-hooks.ts:removeOnceHooks`)**

```typescript
// regular hooks go through DB; session hooks live in memory
addSessionHook(sessionId, event, hook, { once: true })
// after execution:
removeOnceHooks(sessionId, event)  // ← strips once=true from memory
```

This enables "one-shot hooks" — e.g., "Slack me after the next Bash call," self-cleans on execution. **Session hooks don't persist** — they're freed with the session, preventing config accumulation.

**5. updatedInput size limit + serialization check (`output-limits.ts:29-51`)**

```typescript
const serialized = JSON.stringify(updatedInput)
if (serialized.length <= HOOK_MAX_UPDATED_INPUT_CHARS) {  // 16384 chars
  return { value: updatedInput, dropped: false }
}
return { value: undefined, dropped: true, reason: 'oversize' }
```

Hooks can rewrite input — but over 16K chars and it's dropped (prevents a malicious hook from stuffing the LLM context with garbage); JSON.stringify is wrapped in try/catch to prevent circular references from crashing Engine. **All hook output is force-clamped** — hooks can't OOM the Engine through output explosion.

## Counterintuitive Conclusion

> [!IMPORTANT]
> **The hook system's core isn't "extensibility," it's "fault isolation."** Process isolation (run in user container), timeout isolation (60s force-kill), output clamping (anti-OOM), error aggregation (a crashed hook doesn't block main flow) — **all four isolation layers defend against "user script takes down the agent."** Only by treating "user code" as adversarial input can the hook system stay stable in production long term.

Put differently: **"non-zero exit ≠ blocking" is the key design**. User scripts segfault, syntax errors, missing commands — none of these should stop the LLM. **Only an explicit `exit 2` or explicit `{"decision": "block"}` is a real "I want to block" signal**. Separating "failure" from "blocking" at the protocol layer is what lets the hook system reach production.

Most counterintuitive: **hooks run in the user's container** — most people would implement hooks as "child_process.exec in Engine," but that turns hooks into a security hole between users and Engine. HarWork pushes hooks into the **user-dedicated container** so they share a permission baseline with the LLM — **hooks and the LLM share roots**.

## Three Production Pitfalls

> [!WARNING]
> **Pitfall 1 — Hook config without a default timeout.**
>
> `timeout: undefined` passed to fetch / exec — exec waits forever, hook stalls the entire agent loop. HarWork's `DEFAULT_HOOK_TIMEOUT_S = 60` and `DEFAULT_HTTP_TIMEOUT_S = 10` are **forced lower bounds**, defaults that apply even when the config row doesn't set them.

> [!WARNING]
> **Pitfall 2 — Merging additionalContext into one big string.**
>
> N hooks each return 100 chars of context, merge into one N×100 block — the LLM can't tell which segment is from which hook, and the prompt becomes hard to tune. HarWork preserves **list structure** (`additionalContexts: string[]`), capped by count + total chars (`output-limits.ts:13-14`).

> [!WARNING]
> **Pitfall 3 — Hook stdout dumped to console as "logs."**
>
> User script `cat /etc/passwd` lands directly in Engine logs — content leaks to ops dashboards. HarWork's `clampHookText(stdout, HOOK_MAX_STDOUT_CHARS)` caps to 64KB, and `hook_progress / hook_result` stream events cap to 2KB (`HOOK_STREAM_EVENT_MAX_CHARS=2000`) — **deliberately separates "hook output" from "system logs."**

## Figures

1. ![8 hook events on the agent loop timeline](../assets/img/09-hook-events-timeline.svg)
2. ![Engine container vs user container: where hooks actually run](../assets/img/09-hook-execution-boundary.svg)
3. ![Exit code + JSON dual signaling + aggregation rules](../assets/img/09-hook-aggregation.svg)

## Next Article

→ Part 10: Session Persistence — where Conversation / Container / Hook state lives

Hooks done, next we cover persistence — what HarWork keeps across sessions and how. SQLite + Drizzle ORM, conversation / message / hook table relationships, the storage interface that abstracts the backend, load / incremental update / soft-delete strategies — and why session state (permissionMode, sessionHooks, abortController) is actually **not persisted**.

---

📌 Series reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/09-hooks-lifecycle.md](../zh/09-hooks-lifecycle.md)
