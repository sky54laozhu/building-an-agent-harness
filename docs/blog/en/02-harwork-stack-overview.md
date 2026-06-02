---
title: "Part 02: HarWork Harness in One Picture — All 16 Layers, Verified by cloc"
slug: 02-harwork-stack-overview
date: 2026-05-27
series: harwork-agent-harness
series_index: 2
keywords: [agent harness architecture, HarWork, AI coding assistant source, Claude Code alternative]
prev: 01-what-is-agent-harness
next: 03-agent-loop-async-generator
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/02-harwork-stack-overview.md
---

# Part 02: HarWork Harness in One Picture — All 16 Layers, Verified by cloc

> If you were building a Claude Code alternative, what would the stack look like? This article lays out HarWork's actual 16-layer stack on one page, and runs cloc to confirm a counterintuitive number: in the codebase you think of as "an AI product," the code that actually calls the LLM is **0.67%**.

**Jump to:** [Problem](#problem-statement) · [Naive approaches](#why-naive-approaches-fail) · [16 layers](#core-solution-harworks-16-layers) · [Implementation](#key-implementation-details) · [Counterintuitive](#counterintuitive-conclusion-cloc-on-an-ai-product) · [Reading paths](#how-to-read-this-series-two-paths)

## Problem Statement

Part 01 settled what an Agent Harness *is*: the runtime layer that wraps a stateless LLM API into something stateful, controllable, observable, and extensible. The next obvious engineering question — and the one I've actually been asked the most — is **"OK, so what does that runtime layer break down into? How many layers, how big is each, how do they talk to each other?"**

That's what this article answers. I use HarWork (an open-source Agent Harness, 90+ days of development, already runs daily coding tasks) as the sample. I lay the 16 layers out from the bottom (encrypted storage) to the top (CI/CD). For each layer I give three things: **why that layer must exist, how HarWork implements it, and which article in this series digs in.**

By the end you should be able to draw the skeleton of a production-grade Agent Harness on a whiteboard from memory — *then* you can dive into the rest of the series.

## Why Naive Approaches Fail

Lots of open-source Agent projects ship "frontend + LLM call" and call it done. Next.js on top, Express in the middle forwarding requests, Markdown rendering for the responses — 30 days, demo works. Then what?

- **Refresh the browser and 30 turns of context evaporate** — sessions weren't persisted.
- **Delete the container and the environment is gone** — every file the LLM edited, every dep it installed, every process it spawned.
- **Two users at once and tools cross-contaminate state** — concurrency was never thought through.
- **WebSocket drops and you lose the last tool result forever** — no replay, no sequence numbers.
- **Want a new tool? Edit the source.** — no Hook, no Skill, no Plugin, community contribution is dead.

These aren't "small bugs to fix before launch." They're **architectural omissions**. To fix them you have to layer the system from day one — from the LLM API up to CI/CD, every layer carrying a clear boundary and interface. Here are HarWork's current 16.

## Core Solution: HarWork's 16 Layers

I've ordered them bottom-to-top, dependency-to-consumption. **The bottom is what the model doesn't know about (encrypted storage). The top is what the LLM doesn't even participate in (CI/CD pipelines). The 14 layers in the middle are everything that turns individual LLM calls into a product.**

```
┌──────────────────────────────────────────────────────────┐
│ 16. CI/CD (canary + multi-probe auto-rollback)            │ → Vol VII
│ 15. Deployment (Docker Compose / K8s-ready)               │ → Vol VII
│ 14. Observability (structured logs + error reporting)     │ → Vol VII
│ 13. Quota & Audit (per user × model × tool billing)       │ → Vol VII
│ 12. Multi-model routing (5 vendors, 12+ models, failover) │ → Vol V
│ 11. Session management (WS + reconnect grace + replay)    │ → Vol V
│ 10. Streaming protocol (async generator → WS events)      │ → Vol V
│  9. Hook lifecycle (8 event types, community-extensible)  │ → Vol III
│  8. Skill system (bundled / managed / WebSocket states)   │ → Vol III
│  7. Tool Registry (18 tools, unified discovery + invoke)  │ → Vol III
│  6. Security analysis (138 Bash rules + path guards)      │ → Vol IV
│  5. Sandbox (per-user persistent Docker, fast pause/resume)│ → Vol IV
│  4. Context engine (5-tier progressive compaction)        │ → Vol II
│  3. Agent Loop (async generator + AbortController)        │ → Vol II
│  2. LLM Provider abstraction (unifies 5 vendor SDKs)      │ → Vol II
│  1. Database + encrypted storage (20+ tables)             │ → Vol VII
└──────────────────────────────────────────────────────────┘
```

One or two sentences per layer (deep dives live in the listed volumes):

1. **Database + encrypted storage**: session state must be persisted, otherwise you can't even implement "resume on reconnect." HarWork uses SQLite + Drizzle ORM with 20+ tables; conversations, API keys, and SSH private keys are AES-GCM encrypted at rest.
2. **LLM Provider abstraction**: Anthropic's tool use, OpenAI's function calling, and Google's Gemini fields are mutually incompatible. This layer unifies "message format / tool protocol / stream chunks" into HarWork's internal protocol; the business layer sees a single interface.
3. **Agent Loop**: Part 01 showed a 20-line skeleton. The real one adds AbortController, concurrent tool execution, error recovery, and Hook dispatch — HarWork's `agent/loop.ts` is the heart, and **the Loop + context code totals 2,058 lines**.
4. **Context engine**: Part 01 already unpacked the 5-tier progressive compaction. HarWork makes each tier an isolated strategy that can be toggled per user preference.
5. **Sandbox**: Claude Code runs in OS processes on your machine. HarWork chose per-user persistent Docker — one long-lived container per user, sub-second pause/resume, file state survives across sessions. The hard part of this layer isn't creating the container; it's keeping the git worktree state coherent across an unpause.
6. **Security analysis**: who blocks `rm -rf` when the LLM gets adventurous? HarWork runs 138 static rules + path guards before any Bash execution; suspicious commands queue for human approval.
7. **Tool Registry**: 18 built-in tools (Read/Write/Edit/Bash/Grep/Glob/...) sharing one shape: `name + description + schema + execute`. Skills and Hooks both plug in here.
8. **Skill system**: three states — bundled (in-repo), managed (DB-installed), WebSocket (remote RPC). The same Skill interface drives local code, remote npm packages, or in-IDE code.
9. **Hook lifecycle**: 8 event types (PreToolCall / PostToolCall / SessionStart / ContextCompact / ...). Third parties write one JS file and interpose anywhere in the lifecycle.
10. **Streaming protocol**: the Agent Loop is an async generator; events it yields must travel to the frontend over WebSocket. This layer maps "internal event stream" 1:1 to "network event stream" and tags every frame with a sequence number for reconnect replay.
11. **Session management**: a WebSocket drop must not lose context. HarWork gives every session a 30-second reconnect grace window during which events are buffered; on reconnect the client replays from last-seen sequence.
12. **Multi-model routing**: users configure 4 model aliases (fast/standard/strong/vision); the Harness picks which one to use per turn. Sonnet hits 429? Auto-failover to Haiku and keep going.
13. **Quota & Audit**: every LLM call, every tool execution, lands in an audit log keyed by user × model × tool. Enterprise procurement requires this.
14. **Observability**: structured logs + Sentry error reporting + Prometheus metrics. Every 401, every tool timeout in production traces back to a specific session_id and message_id.
15. **Deployment**: Docker Compose for single-box, k8s for multi-replica — pick one. Next.js standalone build for the frontend, engine in its own container, DB on its own volume.
16. **CI/CD**: GitHub Actions runs lint / test / build / e2e; on main-branch merge it auto-canary-deploys to staging, then promotes to production only after three probes (health check, critical API, critical UI) all pass.

Sixteen sounds excessive until you notice **each layer is forced by some user expectation**. Want sessions to survive disconnects? You need 1 + 11. Want extensible tools? You need 7 + 8 + 9. Want enterprises to legally buy this? You need 13 + 14. No layer is over-engineering.

## Key Implementation Details

To make the 16 layers actually run, the **package structure** falls out naturally. HarWork ships four npm packages:

| Package | Responsibility | Form |
|---|---|---|
| `@harwork/engine` | Layers 2–12 of the stack + standalone WebSocket service | Library + service (dual-form) |
| `@harwork/web` | Next.js app + all UI + API routes + DB schema | Application |
| `@harwork/cli` | Terminal entry point (analogous to `claude code`) | CLI |
| `@harwork/skills-catalog` | Seed library of official Skills | Data |

The most interesting piece is **`@harwork/engine`'s "dual-form" deployment**: the same code can be imported by `@harwork/web` as an npm library (embedded mode — frontend and backend in one process) *or* run as its own Docker container exposing a WebSocket port (service mode — frontend and backend decoupled). Switching modes is one environment variable: `WORKSPACE_BACKEND`. This means the same Harness serves both "single-user local" and "multi-tenant SaaS" without maintaining two codebases.

What makes the dual-form possible is the **Adapter pattern**. Engine defines three core interfaces: `DbAdapter` (persistence), `WorkspaceBackend` (sandbox execution), `Executor` (command execution). The Web side implements `DbAdapter` with Drizzle ORM and `WorkspaceBackend` with Docker Compose; swap them for SQLite + a local process and the entire stack runs bare-metal on a Mac — because the interfaces are stable, **every layer is replaceable**. That's exactly the value of layering.

## Counterintuitive Conclusion: cloc on an "AI Product"

The moment of truth. The series spec requires this article to forbid any unverified ratio claim, so I ran cloc across HarWork's `packages/engine/src` + `packages/web/{app,components,lib}` — all TypeScript business code, excluding node_modules, tests, and generated DB types. **Here are the actual numbers:**

| Slice | LOC | Share |
|---|---|---|
| **Code that actually calls the LLM** (engine/models/, SDK adapters for 5 vendors) | **228** | **0.67%** |
| Agent Loop core (engine/agent/) | 2,058 | 6.09% |
| Harness support stack (loop + tools + hooks + skills + sandbox + security + session + DB + observability) | 8,320 | 24.6% |
| Business / UI / API layer (web/components + web/app + web/lib/design) | 20,271 | 60.0% |
| Service entry points + glue (dev-server, ws-server, cron, preview-proxy) | ~5,200 | 15.4% |
| **Total TypeScript** | **33,807** | 100% |

With these numbers, Part 01's "80% engineering / 20% LLM" claim turns out to be too polite. **In 33,807 lines of TypeScript, the code responsible for actually calling the LLM is 228 lines — 0.67%.**

> [!IMPORTANT]
> **You think the hard part of an AI product is the AI; after you've actually finished one that works, the LLM-call code is under 1%.**

What's the other 99.33% doing? Making sure that 0.67% **actually runs, runs stably, runs safely, and is shippable.** This is why the Claude Code, Cursor, and Aider teams have each spent hundreds of person-months — calling the LLM isn't hard. **Making the call *look easy from the outside*** is hard.

It's also why "swap in a stronger LLM" delivers less product improvement than "rewrite the tool protocol." The 0.67% is the part you can swap; the other 99.33% you still have to write yourself.

## How to Read This Series: Two Paths

You now have the whiteboard-sized big picture. Two paths through the next 17 articles:

**Linear path** (recommended for a first complete read):
- Volume II: Core Loop (Parts 03–05 — Loop / context / streaming)
- Volume III: Tools & Extensions (Parts 06–08 — Tool / Skill / Hook)
- Volume IV: Sandbox & Security (Parts 09–11 — per-user Docker / 138 rules / path guards)
- Volume V: Session & Streaming (Parts 12–13 — reconnect grace / multi-model routing)
- Volume VI: Design Collaboration (Parts 14–16 — HarWork's design-mode specifics)
- Volume VII: DevOps (Parts 17–18 — from cloc to canary, end-to-end)

**Targeted path** (jump straight to your sore point):
- Worried about **reconnect resume**? → Part 12 (Vol V)
- Worried about **blocking `rm -rf`**? → Part 08 (Vol IV)
- Worried about **community-extensible tools**? → Part 07 (Vol III)
- Worried about **production deployment**? → Part 17 (Vol VII)

> Note **layer ≠ article**. The 16 layers are the technical dependency view; the 18 articles are the reader-experience view. A single layer can split into 2–3 articles (the security layer = static analysis + path guards + approval flow, three articles). A single article can span multiple layers (the design-collab article spans Hook + Skill + UI). So "look at the big picture first, then choose how to read" beats "read in numerical order."

## Figures

1. ![HarWork 16-layer stack diagram](../assets/img/02-stack-16layers.svg)
2. ![npm package dependency graph](../assets/img/02-package-deps.svg)
3. ![Engine dual-form: library vs service](../assets/img/02-engine-dual-form.svg)

## Next Article

→ [Part 03: Agent Loop — how an async generator carries an entire conversation](./03-agent-loop-async-generator.md)

Next time we drill from layer 3 into Volume II. We take that 20-line Loop skeleton and unpack it into the real `agent/loop.ts` — AbortController, concurrent tool calls, Hook dispatch, error recovery, all tangled together — and explain why the Loop *has* to be an async generator, not a regular async function.

---

📌 Series reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/02-harwork-stack-overview.md](../zh/02-harwork-stack-overview.md)
