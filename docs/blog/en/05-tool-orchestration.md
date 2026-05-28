---
title: "Part 05: Tool Orchestration — Parallel / Serial / Interruptible"
slug: 05-tool-orchestration
date: 2026-06-02
series: harwork-agent-harness
series_index: 5
keywords: [tool orchestration, isConcurrencySafe, Promise.race, Bash sibling abort, Claude Code orchestrator, AbortController]
prev: 04-context-compaction-5-tiers
next: 06-long-term-memory
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/05-tool-orchestration.md
---

# Part 05: Tool Orchestration — Parallel / Serial / Interruptible

> Part 03 said each loop iteration lets the LLM emit 0~N tool calls and then invokes `executeTools`. This article answers: **how does `executeTools` actually decide which calls run in parallel, which serially, and who can cancel whom**? `await Promise.all` and two concurrent Edits on the same file will silently lose data; all-serial and 3 Reads waste 3× the latency. HarWork's `tool-executor.ts` (657 lines) gives a "two-stage scheduling + four-path cancellation" answer. This piece unpacks each piece.

**Jump to:** [Problem](#problem-statement) · [Naive approaches](#why-naive-approaches-fail) · [Two-stage scheduling](#core-solution-two-stage-scheduling) · [Cancellation paths](#four-cancellation-paths) · [Implementation](#key-implementation-details) · [Counterintuitive](#counterintuitive-conclusion) · [Production pitfalls](#three-production-pitfalls)

## Problem Statement

The LLM may emit 8 tool calls in a single turn. The orchestrator sitting between the LLM and the tools has to solve three concrete problems:

1. **Concurrency safety** — Which can run in parallel? Two Edits on the same file in parallel = data loss; two Reads on different files in parallel = totally safe.
2. **Failure cascade** — When one tool fails, do the others continue? No one-size answer: Bash `make build` failing makes the following `npm test` pointless; a failed Read doesn't affect Glob.
3. **Interrupt propagation** — User hits Ctrl-C / switches tabs / closes the browser. What happens to running subprocesses, open streams, in-flight DB transactions?

Naive approach #1 — **`Promise.all` everything** — leaks concurrency safety. #2 — **all-serial** — wastes latency. #3 — **let the LLM declare it** — the LLM will confidently tell you "these two `rm` commands can run in parallel" and someone has to backstop it.

## Why Naive Approaches Fail

**Naive 1: `Promise.all` everything**. Read + Read + Glob in parallel is fine, but the moment you mix in an Edit (or two Bashes touching the same dir) you get race conditions. Container concurrency saturates and everything drags.

**Naive 2: All-serial**. Simple and safe, but the LLM emits 5 Reads → 5 seconds of serial requests, and the UX breaks. The "instantly scan the repo" feel in Cursor / Claude Code is entirely thanks to parallelism.

**Naive 3: Let the LLM declare `parallel: true`**. Tried it — the LLM will confidently say "these two rm calls are independent." Its judgment of side effects is unreliable, so the harness must backstop.

**Naive 4: Each write-tool implements its own mutex**. Workable, but it requires every tool author to understand concurrency. Most tools are written by the LLM itself; counting on it to lock correctly is unrealistic.

Common failure: **all four put the concurrency decision in the wrong place** — either fully delegated to the scheduler (doesn't know what's inside the tool) or fully delegated to the tool (doesn't know what its siblings are doing).

## Core Solution: Two-Stage Scheduling

HarWork's split is clean: **the tool self-declares; the orchestrator batches.**

### Stage 1: Tool Self-Declares

Every tool implements two booleans on the `HarWorkTool` interface (`tools/types.ts:98-99`):

```typescript
export interface HarWorkTool {
  isReadOnly(input): boolean        // Is this call read-only?
  isConcurrencySafe(input): boolean // Can this call run concurrently with siblings?
}
```

Both are **per-call**, not per-tool — Bash's `cat large.log` is read-only; `rm -rf /` isn't. The same Bash tool returns different answers for different inputs.

How real tools declare:

| Tool | isReadOnly | isConcurrencySafe | Reason |
|------|-----------|-------------------|--------|
| Read | `true` | `true` | File reads don't conflict |
| Glob / Grep | `true` | `true` | Pure queries |
| Write | `false` | `false` | Any write can collide with a same-name write |
| Edit | `false` | `false` | Same |
| Bash | **depends on cmd** | **always `false`** | Even read-only `cat` runs in a subprocess that competes for container resources |

Bash is the only tool with a dynamic `isReadOnly` (`bash.ts:301-307` splits the command into subcommands and checks each one), but `isConcurrencySafe` is hard-coded `false` — **read-only ≠ concurrency-safe**, and Bash is special here.

### Stage 2: Orchestrator Batches

`partitionToolCalls` (`tool-executor.ts:40-75`) scans the call list and **accumulates consecutive "read-only + concurrency-safe" calls into a parallel batch**; everything else gets its own serial batch:

```typescript
const canParallel =
  permissionMode !== 'strict' &&
  tool != null &&
  tool.isReadOnly(call.args) &&
  tool.isConcurrencySafe(call.args)

if (canParallel) {
  currentParallel.push(call)
} else {
  // Flush the current parallel batch, open a new serial one
  if (currentParallel.length > 0) {
    batches.push({ parallel: true, calls: currentParallel })
    currentParallel = []
  }
  batches.push({ parallel: false, calls: [call] })
}
```

LLM outputs `[Read, Read, Glob, Edit, Read, Bash]` → orchestrator splits into 4 batches:
1. `[Read, Read, Glob]` parallel
2. `[Edit]` serial
3. `[Read]` parallel (size 1, but takes the parallel path)
4. `[Bash]` serial

**Key**: batching follows the call order, **no reordering** — from the LLM's perspective, what it asked for runs in the order it asked. The orchestrator only decides "which adjacent ones can fire together." This sets up the counterintuitive conclusion later.

## Four Cancellation Paths

This is where the 657 lines get complex. "Group and run in parallel" is ~50 lines; the remaining ~600 deal with "how to stop when things go wrong." HarWork has **four independent cancellation paths**, each at a different granularity:

### Path 1: Bash Sibling Abort (within parallel batch)

```typescript
// tool-executor.ts:249
const siblingAbort = new AbortController()

const results = await Promise.all(
  batch.calls.map(async (call) => {
    // ... permission check ...
    
    // tool-executor.ts:291-301 Race: tool vs sibling abort
    const toolPromise = runToolCall(call, tool, context)
    const abortPromise = new Promise<'aborted'>((resolve) => {
      siblingAbort.signal.addEventListener('abort', () => resolve('aborted'), { once: true })
    })
    const raceResult = await Promise.race([
      toolPromise.then((r) => ({ kind: 'done', ...r })),
      abortPromise.then(() => ({ kind: 'aborted' })),
    ])

    // tool-executor.ts:318-321 If this Bash erred, cancel all siblings
    if (result.isError && call.toolName === 'Bash') {
      siblingAbort.abort('sibling_error')
    }
  }),
)
```

Design point (**asymmetric trigger**): **only a Bash error fires `siblingAbort.abort()`** — Read / Glob failures never trigger sibling cancellation. Why? Bash commands often have implicit dependency chains (`make build && npm test` — if build fails, test is meaningless); failures of other tools are independent events.

But **once abort is triggered**, `Promise.race` cancels **every sibling that hasn't settled yet** — including a still-running Read. So in `[Bash(build), Bash(test), Read(file)]`, when build fails, test **and** Read both get cancelled — it's **not** "only Bash siblings die."

The source comment (`tool-executor.ts:246-248`) says "Non-Bash tools are independent and unaffected" — but "unaffected" there means "a non-Bash failure does not trigger cascade" (the trigger side), not "non-Bash tools survive when cascade fires." The comment can mislead; **trust the code, not the comment**.

### Path 2: Serial Bash Chain Cancellation

```typescript
// tool-executor.ts:373-388
if (bashErrored && call.toolName === 'Bash') {
  // Yield a cancelled result directly without calling the tool
  yield { type: 'tool_call_result', content: 'Cancelled: previous Bash command failed', isError: true, ... }
  continue
}
```

In a serial batch, once one Bash errors, **all subsequent Bash calls are cancelled (but other tools aren't affected)**. The `bashErrored` flag is turn-scoped — the next loop iteration resets it. This mirrors the parallel-batch logic: one uses race+signal, the other uses flag+skip.

### Path 3: Global Abort (user interrupt)

```typescript
// tool-executor.ts:355
if (context.abortController.signal.aborted) {
  yield { type: 'tool_call_result', content: 'Aborted', isError: true, ... }
  return  // Exit the entire generator
}
```

**Only checked at the top of the serial-batch loop** — why not in the parallel batch? Because parallel calls are already running; cancelling them depends on the tool itself responding to `context.abortController.signal` (Part 03's AbortSignal tree continues here). The executor can't "retract" requests already issued — it relies on tools to wire the signal into subprocess SIGTERM, stream close, DB rollback.

### Path 4: Hard Limits (rate limit + denial tracker)

```typescript
// tool-executor.ts:226-230
const maxToolCalls = options?.maxToolCalls ?? 50
const denials = createDenialTracker(5, 20)  // 5 consec / 20 total → abort
```

- **maxToolCalls = 50**: per-turn tool-call ceiling. The LLM occasionally loops "20 Reads looking for one line of code" — the ceiling pulls it out.
- **denials = (5 consecutive, 20 total)**: if the user denies 5 in a row or 20 total, the turn aborts. Prevents the "LLM keeps asking, user keeps denying" deadlock.

## Key Implementation Details

Five details that make or break this:

**1. Parallel batch still runs permission checks**

`tool-executor.ts:262-275` — even a read-only tool in a parallel batch still calls `tool.checkPermissions`. A common misconception: "read-only is always allowed." Wrong — Reading `.env` is blocked by bypass-immune rules (see Part 10 sandbox).

**2. Strict mode kills all parallelism**

`tool-executor.ts:52` — `permissionMode !== 'strict'` is the first condition for `canParallel`. In Plan mode / strict audit mode, **everything goes serial** — each tool needs its own permission prompt. This is deliberate: in strict mode, "fast" isn't the goal, "auditable" is.

**3. The buffered `emitEvent` pattern for sub-agent tools**

`tool-executor.ts:574-582` — when running a tool serially, the orchestrator sets `context.emitEvent` so the tool's internals (e.g., a sub-agent tool) can enqueue intermediate events. After the tool returns, it yields the main result first, then flushes the buffered events. **Order matters**: the user sees the main result first, then sub-agent details.

**4. EnterPlanMode/ExitPlanMode side effects**

`tool-executor.ts:600-607` — these tools don't just return a result; they **mutate `context.permissionMode`**. Because they go through the serial path, the mutation takes effect immediately for subsequent tools. If they could run in parallel, you'd get state contamination.

**5. PreToolUse hook can veto**

`tool-executor.ts:535-571` — before the tool actually runs, the PreToolUse hook fires; if it returns `blockingErrors`, the call is denied. This is the entry point for plugins like ECC to take over tools (see Part 14 hooks).

## Counterintuitive Conclusion

> [!IMPORTANT]
> **The orchestrator's real complexity isn't "concurrency algorithm" — it's "failure semantics."** Parallel grouping is ~50 lines of the 657; the other ~600 are all about "when to stop, who to stop, how to stop."

Put differently: **parallelism is optimization; cancellation is correctness**. An orchestrator missing sibling abort looks just as fast in a demo — but run it in production for a week and you'll see "compile failed yet the tests kept running, producing a bunch of false-positive errors fed back to the LLM" disasters.

The most counterintuitive part: **the LLM has no idea the orchestrator exists**. It outputs `[Read, Read, Edit]` and gets results in that order, as if all three ran serially. **The more invisible the orchestrator, the more stable the LLM**, because the LLM was trained on tool results that were serially ordered. Once you expose "these two ran in parallel" in the prompt, the LLM starts reasoning about concurrency, and hallucination probability spikes.

This also explains why `partitionToolCalls` never reorders: **only adjacent merging, never crossing a non-concurrent tool**. `[Read, Edit, Read]` must become `parallel[Read] → serial[Edit] → parallel[Read]`, never optimized to `parallel[Read, Read] → serial[Edit]` — the latter is faster but breaks the order illusion.

## Three Production Pitfalls

> [!WARNING]
> **Pitfall 1 — Declaring a non-idempotent tool `isConcurrencySafe: () => true`.**
>
> I've seen people write a "counter increment" tool, declare it concurrencySafe, run two in parallel, and end up with +1 (race). **HarWork's rule:** the default should be `false` — unless you can prove the call has no dependency on shared external state (pure functions like Read / Glob qualify).

> [!WARNING]
> **Pitfall 2 — Thinking "sibling abort = `AbortController.abort()` is enough".**
>
> Look at `tool-executor.ts:291-301` — you have to wrap toolPromise and abortPromise in `Promise.race`. Just calling `siblingAbort.abort()` without the race **lets the already-awaited tool keep running** — the signal is a notification, not a forceful interrupt of an in-flight Promise. Very common pitfall, because many people misread `AbortController`'s "cancel" semantics as forced termination.

> [!WARNING]
> **Pitfall 3 — Forgetting to reset `bashErrored` between turns.**
>
> `tool-executor.ts:228` declares `let bashErrored = false` at every `executeTools` invocation — so each new loop iteration auto-resets. If you "optimize" by hoisting this variable into ToolContext for reuse, you'll get the ghost bug "user's previous turn had a Bash failure → this turn all Bash calls are cancelled."

## Figures

1. ![Two-stage scheduling flow](../assets/img/05-two-stage-scheduling.svg)
2. ![Batch partitioning example](../assets/img/05-batch-partitioning.svg)
3. ![Bash sibling abort sequence](../assets/img/05-sibling-abort-sequence.svg)

## Next Article

→ [Part 06: Long-Term Memory — CLAUDE.md + auto memory](./06-long-term-memory.md)

Next we move from "how tools don't fight each other" to "what survives after the conversation ends." Every session starting from zero = the user repeats their preferences endlessly; cramming all history into the prompt = it overflows in a few turns. Claude Code / HarWork's answer is a two-layer mechanism: project-scoped `CLAUDE.md` + user-scoped auto memory. Part 06 unpacks how this "controllable, forgettable, layered" long-term memory actually works.

---

📌 Series reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/05-tool-orchestration.md](../zh/05-tool-orchestration.md)
