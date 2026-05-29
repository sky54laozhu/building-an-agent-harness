---
title: "Part 06: Long-Term Memory — CLAUDE.md + auto memory, three paths"
slug: 06-long-term-memory
date: 2026-06-09
series: harwork-agent-harness
series_index: 6
keywords: [CLAUDE.md, auto memory, MEMORY.md, agent memory, long-term memory, Claude Code memory, agent harness]
prev: 05-tool-orchestration
next: 07-tool-system
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/06-long-term-memory.md
---

# Part 06: Long-Term Memory — CLAUDE.md + auto memory, three paths

> Part 03 said the Agent Loop rebuilds the system prompt from scratch every turn — which raises the question: **every session starts at zero, and the user has to teach the AI their preferences over and over**. Stuff the whole history into the prompt? It overflows in a few turns. Hope the LLM "remembers" what the user likes? It doesn't have that receptor. HarWork (mirroring Claude Code) answers with **long-term memory** — but it's not one path; it's three: CLAUDE.md (instructions), file-based auto memory (user/model collaboration), and DB-based extraction (optional). This piece unpacks all three.

**Jump to:** [Problem](#problem-statement) · [Naive approaches](#why-naive-approaches-fail) · [Three paths](#core-solution-three-memory-paths) · [Implementation](#key-implementation-details) · [Counterintuitive](#counterintuitive-conclusion) · [Production pitfalls](#three-production-pitfalls)

## Problem Statement

Cross-session state comes in three distinct shapes with very different requirements:

1. **Project conventions** ("use pnpm, not npm"; "tests live in packages/*/test/") — shared with the team, should be in git, visible to every contributor.
2. **Personal preferences** ("I like terse replies", "I use Vim") — personal, cross-project, shouldn't be committed.
3. **Ephemeral facts** ("X said do Y first last time"; "yesterday's bug was fixed by Z") — changes fast, must be forgettable.

If you pick one mechanism to cover all three, you get either too-coarse granularity (everything goes in one CLAUDE.md) or too-fine overhead (a file per preference = 100 files).

## Why Naive Approaches Fail

**Naive 1: Let the LLM remember on its own**. LLMs have no cross-session state — every API call is stateless. "Remembering" means putting memory back into the prompt.

**Naive 2: Stuff all history into the prompt**. Part 04 covered this in detail: the context window is finite, and the LLM itself "forgets" as the conversation grows (attention decay). Dead end.

**Naive 3: Vector store + RAG**. Workable but heavy — you have to deploy an embedding model, vector DB, tune similarity thresholds. Overkill for a single-user workflow. Claude Code / HarWork picked something more primitive: **just files**.

**Naive 4: User writes the system prompt themselves every time**. High overhead, and they'll forget to update it.

## Core Solution: Three Memory Paths

HarWork's memory system **isn't one path** — it's three independent channels, each opt-in:

| Path | Writer | Storage | System prompt heading | Source |
|------|--------|---------|----------------------|--------|
| 1. **CLAUDE.md instructions** | User (git tracked) | Multiple fixed paths | `# Project instructions` | `claudemd.ts` 144 lines |
| 2. **File memory** | Model via Write tool | `.claude/memory/*.md` + `.claude/MEMORY.md` | `# Saved Memories` | `memory-files.ts` 128 lines |
| 3. **DB memory** (optional) | Model via LLM extraction | `StorageProvider` (database) | `# Memory` | `memory.ts` 122 lines |

The loop top (`loop.ts:47-70`) loads all three, then passes them to `buildSystemPrompt` (`prompts.ts:182-188`). The three are non-blocking: any one throwing won't sink the conversation (each is wrapped in try/catch + skip silently).

### Path 1: CLAUDE.md — 6 file locations + override priority

`claudemd.ts:42-103 loadInstructionFiles` scans these 6 paths in order:

```
0a. ~/.claude/CLAUDE.md              ← user-level, global
0b. ~/.claude/rules/*.md             ← user-level rule files
1.  /workspace/CLAUDE.md             ← project root (in git)
2.  /workspace/.claude/CLAUDE.md     ← project dot-dir (in git)
3.  /workspace/.claude/rules/*.md    ← project rule files
4.  /workspace/CLAUDE.local.md       ← local-private (**.gitignore'd**)
```

Load order = priority — later files override earlier ones (they appear later in the prompt and the LLM weighs them more). Some details:

- **0a/0b user-level**: skipped when home == workspace (avoid duplicate loads) — `claudemd.ts:48,51`
- **Every file passes through `stripHtmlComments`** (`claudemd.ts:109-111`), so authors can use `<!-- ... -->` for notes invisible to the AI
- **Path + type go into the prompt together**: `## /workspace/CLAUDE.md (project instructions, checked into the codebase)` — the LLM knows whether a rule is from git or local-private

The injected prompt is prefaced with a strong override clause (`claudemd.ts:128-131`):

> "Codebase and user instructions are shown below. Be sure to adhere to these instructions. **IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.**"

This sentence matters — it elevates CLAUDE.md priority **above the default system behavior**. That's why writing "never use git push --force" in CLAUDE.md actually works on Claude — it's not a suggestion; it's an override.

### Path 2: File memory — model writes, module reads

The `memory-files.ts` module is **read-only** (the source comment at L5 is explicit: "Writing is done by the model via the Write tool — this module is read-only"). How does the model write? Through the system prompt instructions in `prompts.ts:191-206`:

```typescript
// prompts.ts:191-206 the built-in "Memory management" instructions (abbrev.):
1. Create a memory file using the Write tool at .claude/memory/<topic-slug>.md
2. Use frontmatter:
   ---
   name: <descriptive title>
   description: <one-line summary for relevance matching>
   type: <user|feedback|project|reference>
   ---
   <content>
3. Update the index at .claude/MEMORY.md — each entry: - [Title](memory/<file>.md) — hook
4. Prefer updating existing over creating duplicates
5. Memory types: user / feedback / project / reference
```

**4 types** (per system prompt doc):
- `user`: user's role, preferences, knowledge background
- `feedback`: user corrections of the AI's approach ("don't do X" / "yes exactly")
- `project`: current-project ephemeral facts, decisions, deadlines
- `reference`: pointers to external resources (Linear project ID, Grafana dashboard URL)

The model decides "this is worth remembering" and proactively writes via the Write tool. Next session, `loadMemoryFiles + formatMemoryPrompt` (`loop.ts:65-70`) injects those files + the index back into the prompt. **The write-read loop is self-contained — no intermediate state machine.**

`MEMORY.md` is an index file, one entry per line (like a README TOC). HarWork's system prompt (`prompts.ts:191-206`) only tells the model to "keep it concise / prefer updating over creating duplicates" — there's no code-level line truncation; it relies on the model's discipline. But each memory file's full content goes into every prompt, so a long index → many files → token cost grows fast.

### Path 3: DB memory — optional LLM extraction

`memory.ts:39 extractMemories` is another path, **completely independent of file memory**:

```typescript
// memory.ts:55-58 call the LLM to extract
const result = await generateText({
  model,
  system: EXTRACTION_PROMPT,  // the long prompt at memory.ts:15-33
  messages: [{ role: 'user', content: truncated }],  // last 4000 chars
})
// Parse JSON array → MemoryEntry[]
// Persist via StorageProvider.saveMemories
```

The extracted entries have **4 categories** (note: **completely different** from file memory's 4 types):

| `memory.ts` category | `memory-files.ts` type |
|---------------------|-----------------------|
| `fact` | `user` |
| `preference` | `feedback` |
| `context` | `project` |
| `correction` | `reference` |

**This is a real footgun** — two sets of four categories with no overlap. The first reads from "the LLM's perspective" (is this a fact? a preference?); the second from "the user's perspective" (is this about me? about the project?). If you extend HarWork, unify them — otherwise you'll maintain two category constants in two places.

The DB path triggers extraction at session end (or via a hook); each invocation caps at 20 entries (`memory.ts:112` `.slice(0, 20)`), and only looks at the last 4000 chars (`memory.ts:50-51`) — both hard limits exist to **prevent "auto extraction" from blowing up the context on its own**.

## Key Implementation Details

Five details that make or break this:

**1. User-level CLAUDE.md is skipped when home == workspace**

`claudemd.ts:48` — when user home and workspace are the same path, skip loading `~/.claude/CLAUDE.md`. This is for the local-dev scenario: you're running HarWork on your own machine, home is workspace, you don't want the same instructions loaded twice. In Docker (different paths) the user-level files load normally.

**2. HTML comments are stripped — author notes don't enter the prompt**

`claudemd.ts:109-111` — every `<!-- ... -->` block is removed before injection. So you can write:

```markdown
<!-- Note to the team: this project uses pnpm because npm hoisting has a monorepo bug -->
- Use pnpm to install dependencies
```

The `<!-- -->` is for humans; the AI only sees the rule below. Tokens not wasted.

**3. CLAUDE.local.md is the escape hatch for private instructions**

`claudemd.ts:97-100` loads `CLAUDE.local.md` (**should NOT be in git**). Common usage: "my SSH port is 2222"; "production DB password is in 1Password under entry X" — **only useful to me, must not be committed**. Each project should add it to `.gitignore`.

**4. The three paths are non-blocking**

`loop.ts:46-71` — all three loads are wrapped in try/catch. Any one throwing just `console.warn`s (CLAUDE.md) or silently skips (the other two). **Memory is enhancement, not critical path** — a failed memory load can't block the user's question.

**5. memory.ts is mounted optionally**

`loop.ts:55` checks whether `storage.getMemories` exists — if your StorageProvider doesn't implement it, DB memory is fully disabled. HarWork's default SQLite impl does, but swap in an in-memory provider and it auto-degrades to file memory only.

## Counterintuitive Conclusion

> [!IMPORTANT]
> **The real difficulty of a memory system isn't "how to remember" but "drawing clean boundaries."** CLAUDE.md / file memory / DB memory all look like "long-term memory," but their writers, readers, lifecycles, and sharing scopes are all different — mix them and three months later you can't tell which path a given rule came from.

Put differently: **memory is a state machine the LLM reads, and state machines are at their worst when "two variables express the same concept."** HarWork's two sets of category constants (`fact/preference/context/correction` vs `user/feedback/project/reference`) are a live specimen of this trap — two devs writing into both sides, and `grep` can't even tell you which side to grep.

The most counterintuitive part: **the writer is the model itself**. File memory isn't user-managed — the model proactively calls the Write tool when it judges something is "worth remembering." This means you can trigger it via "please remember that ..." in your prompt, and constrain it via system prompt clauses ("don't save anything about my passwords"). **The model is both the consumer and the producer of memory** — a closed loop other RAG schemes can't pull off, because there the embedding model and the chat model are separate and can't share contextual judgment.

## Three Production Pitfalls

> [!WARNING]
> **Pitfall 1 — Treating CLAUDE.md like a product doc.**
>
> I've seen people stuff 5000 words of "project vision + team intro + decision history" into CLAUDE.md — and that gets pasted into every prompt every turn. Budget gone instantly. **CLAUDE.md is instruction, not documentation**: write "what to do, what not to do," not "why we did this." The latter goes in README.

> [!WARNING]
> **Pitfall 2 — Replacing hand-curated CLAUDE.md with DB extraction.**
>
> `memory.ts`'s LLM extraction **only sees the last 4000 chars** (`memory.ts:50-51`), and confidence is the LLM's own estimate — unreliable. **Rules that truly must be obeyed every turn belong in CLAUDE.md** (hand-curated), not in hopes that the LLM will extract them. DB memory fits "the user mentioned a preference in passing" — secondary signal.

> [!WARNING]
> **Pitfall 3 — Committing `.claude/memory/` to git.**
>
> File memory is **written by the model** and may contain user-uttered ephemeral preferences or stale context. Commit it and every contributor gets polluted with noise. Correct: add `.claude/memory/` to `.gitignore`; put team-shared rules in `CLAUDE.md`. **Only CLAUDE.md / .claude/CLAUDE.md / .claude/rules/ belong in git** — `CLAUDE.local.md` and `.claude/memory/` should both be ignored.

## Figures

1. ![Three memory paths overview](../assets/img/06-three-memory-paths.svg)
2. ![CLAUDE.md 6-file loading & override priority](../assets/img/06-claudemd-loading.svg)
3. ![File memory's write-read loop](../assets/img/06-file-memory-loop.svg)

## Next Article

→ Part 07: Tool System — design commonalities of Read / Write / Edit / Bash / Glob / Grep

Next we move from "session-level state" to "tool-level atomic operations." Claude Code ships 12 built-in tools; HarWork mirrors and extends to 20+. They all look mundane (Read just reads a file, right?), but each one's `description` runs 100+ lines and the `prompt()` method explains "when to use me instead of Bash" — these details decide whether the LLM uses the tool at all, and whether it uses it right. Part 07 unpacks the real difficulty in "tool prompt engineering."

---

📌 Series reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/06-long-term-memory.md](../zh/06-long-term-memory.md)
