---
title: "Part 01: What Is an Agent Harness — How AI Coding Tools Like Claude Code Are Actually Built"
slug: 01-what-is-agent-harness
date: 2026-05-26
series: harwork-agent-harness
series_index: 1
keywords: [agent harness, building claude code, AI coding assistant architecture]
prev: null
next: 02-harwork-stack-overview
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/01-what-is-agent-harness.md
---

# Part 01: What Is an Agent Harness — How AI Coding Tools Like Claude Code Are Actually Built

> Claude Code, Cursor, and Aider all call the same Claude API. So why do they feel so different? The answer lives in the engineering shell wrapped around the LLM.

## Problem Statement

If you open the source code or public material for Claude Code, Cursor, Aider, and Continue, you notice something striking: **they're all riding the same underlying LLMs** — mostly Claude Sonnet/Opus, GPT-4 variants, Gemini, plus some in-house fine-tuned smaller models. Yet their product feel, extensibility, security boundaries, and reconnect behavior diverge wildly.

The difference is not the model. The difference is **the shell wrapped around the model**: how you turn a stateless `POST /v1/messages` call into an engineering tool that can "read code, edit files, run commands, remember context across sessions, and recover from network drops."

That shell, in the English engineering community, is increasingly called an **Agent Harness**. It's not an LLM, and it's not a class in some Agent framework. It's a **runtime** that treats the LLM like a CPU, tools like peripherals, and the conversation like session state.

This series takes the harness apart. Today's article nails down what an Agent Harness actually is.

## Why Naive Approaches Fail

There are three intuitive ways to build an AI coding assistant. None of them go the distance.

**Approach 1: Just `curl` the LLM API.** You paste the entire codebase into the prompt and ask the model to return a diff you patch yourself. Demo works in ten minutes. But any non-trivial project breaks it: the context window can't hold the code, the model can't see runtime output, and there's no way for it to "grep first, then decide what to change." This path effectively blindfolds the LLM.

**Approach 2: Bolt on a LangChain Agent or ReAct template.** This was the 2023 default. The problem is shallow abstraction — it solves "let the LLM call tools in a loop" but not "how do tool results feed back to the next turn," not "how do we compress a 50-turn conversation," not "who blocks `rm -rf /`," not "how does streaming resume after a disconnect," not "how do we cleanly cancel mid-execution." Run it in production for a week and a dozen edge cases bite.

**Approach 3: Hand-roll your own ReAct loop.** Looks flexible. Then you discover: every new tool needs prompt surgery, every new model needs custom tool-call parsing (Anthropic's tool use and OpenAI's function calling have incompatible schemas), every new safety rule means a full regression. Three months later you've shipped **a stunted version** of a harness — and nobody can maintain it.

The shared bug across all three is treating "calling the LLM" as the central problem. In real engineering, **calling the LLM is maybe 20% of the work**. The other 80% — the part that actually determines product feel and stability — lives in everything around the call: deciding which tools are available, which paths are off-limits, turning token streams into events, splitting tool calls into cancellable sub-tasks, replaying results back to the LLM, compressing context, structuring logs. The harness is the container for that 80%.

A concrete failure mode that hits every naive build: your ReAct loop lets the LLM run `grep -r "error" .` to investigate, the repo happens to have tens of thousands of matches, and the tool dumps 5MB of JSON straight back into the context — the next LLM call exceeds the window and the whole session errors out. Handling this cleanly takes at least three things: truncate tool output by line/token count before replay, persist the truncated remainder as an attachment, and let the agent retrieve from that attachment on demand. None of those is "prompt engineering" — all three are plain engineering. A working harness is the container that fills dozens of holes like this one.

## Core Definition

Here's a precise definition:

> **Agent Harness: the runtime layer that wraps a stateless LLM API into a "stateful, controllable, observable, and extensible" engineering Agent.**

All four adjectives matter. Drop one and users leave:

- **Stateful**: sessions survive disconnects and container restarts; context can be compressed, replayed, retrieved; a 30-turn conversation doesn't evaporate on browser refresh.
- **Controllable**: users can interrupt, undo, change their mind at any moment; dangerous operations (deleting files, outbound network calls, writes to sensitive paths) go through approval; token budgets and concurrency limits are enforced, so a single bad prompt can't take down the service.
- **Observable**: every LLM call, tool invocation, context compaction, and hook fire emits a structured log; production errors trace back to the exact prompt and tool response that caused them; bills can be sliced by user, model, and tool.
- **Extensible**: third parties extend without forking — hooks and skills add new tools, triggers, and models; community extensions install like browser plugins; the same harness can drive a general coding agent or a domain-specific one (medical, legal, ops).

Meeting all four requires 7 core components, which map directly to the seven volumes of this series:

| Component | Problem It Solves | Volume |
|-----------|-------------------|--------|
| Agent Loop | how multi-turn tool calls terminate safely | II |
| Context Engine | how a long conversation avoids blowing the window | II |
| Tool Protocol | how tools are discovered, invoked, interrupted | III |
| Extension Points | how users extend without forking | III |
| Sandbox & Security | how dangerous commands, path traversal, secrets are contained | IV |
| Session & Streaming | how disconnects, concurrency, and multi-model are absorbed | V |
| DevOps | how a solo dev or small team runs this in production | VII |

Each component is straightforward on its own. The hard part is **making the seams between them not leak** — exactly what the remaining 18 articles will dissect. These seven components nest like concentric rings, from the innermost LLM API outward to the user and production environment (see Figure 2 below).

## What Does the Harness Loop Look Like?

The definition above is still abstract. Here's the minimum runnable skeleton — once you see it, you'll notice the core is small and the hard parts all live outside it. Claude Code's real loop is ten times more elaborate, but at its heart it's an async generator:

```typescript
async function* runAgentLoop(initialMessages, tools, abortSignal) {
  let messages = initialMessages;
  while (true) {
    if (abortSignal.aborted) return;

    // 1. Call the LLM — get back text and/or tool_use blocks
    const response = await callLLM(messages, tools);
    yield { type: 'assistant', content: response };

    // 2. No tool_use blocks means the LLM wants to stop
    const toolCalls = response.filter(b => b.type === 'tool_use');
    if (toolCalls.length === 0) return;

    // 3. Run tools concurrently, every one honors abortSignal
    const results = await Promise.all(
      toolCalls.map(tc => executeTool(tc, abortSignal))
    );
    yield { type: 'tool_results', content: results };

    // 4. Feed results back into messages, next iteration
    messages = [
      ...messages,
      { role: 'assistant', content: response },
      { role: 'user', content: results },
    ];
  }
}
```

The loop body is 20 lines. But making those 20 lines "survive a disconnect, cleanly cancel when a tool hangs, not blow the window when context grows past 100K tokens, not leave dirty files when the user hits Ctrl-C, not cross-contaminate state under concurrency" — that's a stack of engineering work far larger than the loop itself. That stack is what the remaining 18 articles unpack.

## Key Implementation Details

The trade-offs between different harnesses are visible at a glance (the table below has a visual companion in Figure 1). The table below is distilled from reading [Anthropic's official guide on building effective agents](https://www.anthropic.com/research/building-effective-agents), the [two-hour Cursor team interview on Lex Fridman #447](https://lexfridman.com/cursor-team-transcript/), [Aider author Paul Gauthier's benchmark showing LLMs are worse at returning code wrapped in JSON](https://aider.chat/2024/08/14/code-in-json.html), and our own scars from building the HarWork harness:

| Dimension | Claude Code | Cursor | Aider | HarWork |
|-----------|-------------|--------|-------|---------|
| Loop shape | terminal + async generator | editor-embedded | terminal + Git | terminal + Web (dual) |
| Context compaction | 5-stage progressive | editor-side retrieval | repo map + selective injection | 5-stage progressive |
| Tool protocol | Anthropic tool use | editor protocol | diff application | tool use + custom extensions |
| Sandbox | OS process | editor process | Git worktree | per-user persistent Docker |
| Extension points | Hook + Skill + Plugin + MCP | in-editor | CLI flags | Hook + Skill + Plugin |

The surface differences look large, but **underneath everyone is solving the same seven-component problem** — they just prioritize differently. Cursor foregrounds editor UX; Aider keeps Git integration the cleanest; Claude Code goes deepest on extensibility; HarWork takes "one person or a small team can still run enterprise-grade DevOps" as the starting point (the proof for that claim lands in Volumes 6-7, not here).

If you want to read source to verify the framing, the HarWork project keeps 16 internal reverse-engineering notes on Claude Code under `docs/claude-code-analysis/`, covering Agent Loop, context compaction, the permission system, the hook system, and Skill/Plugin internals — this series unpacks each of them.

Let me also unpack the "5-stage progressive" cell in the table, so it doesn't sit there as a black box until Part 02. Claude Code and HarWork compress context in five tiers, from light to heavy:

1. **System-prompt slimming**: strip secondary metadata (username, shell type, timezone) from the prompt header — saves 500-2000 tokens per call
2. **Tool-result summarization**: long tool outputs (grep with thousands of matches, large `cat`) get folded into "first N lines + last N lines + total count" — saves 5K-50K tokens per call
3. **Message history folding**: completed sub-tasks get replaced with 1-2 sentence summaries; the last ~8-10 raw turns are kept by relevance
4. **Retrieval re-injection**: folded history is vector-indexed and the 3-5 most relevant chunks are pulled back into context for the current question
5. **Hard truncation fallback**: if still over budget, drop oldest assistant replies first, preserve user prompts, recent tool results, and recent dialogue

The five tiers fire progressively: under 50% token budget nothing kicks in; at 70% stages 1+2 activate; at 85% stages 3+4 add on; only above 95% does stage 5 trigger. Part 02 lays out the exact thresholds, trigger conditions, and measured compression rates per tier.

With the trade-offs in view, here's one counterintuitive conclusion.

## Counterintuitive Conclusion

> **The hardest part of a harness is not when the LLM is calling — it's when the LLM isn't. How tool results flow back, when compaction fires, how disconnects resume, how the user's mind-change rolls cleanly back. Harness ≈ 80% engineering problems + 20% LLM problems.**

What this means: **building a working AI coding tool is mostly classic distributed systems, OS, and database engineering — not prompt engineering.**

A concrete example. Claude Code handles user Ctrl-C interrupts via a three-layer dance: AbortController + async generator protocol + tool cleanup hooks. The signal propagates to the Loop; the Loop marks the running tool as cancelled; the tool itself is responsible for cleaning up half-written files, closing spawned subprocesses, committing rollback-safe transactions. Any layer that drops the ball leaves dirty state. Cursor's team in the Lex Fridman interview spent considerable time on Merkle trees for repo semantic indexing and KV cache sharing for transformer attention — all to resolve the engineering tension "context big enough, latency low enough." **Every one of these is an engineering problem, not an LLM problem.**

Now a counter-example. Aider author Paul Gauthier ran a benchmark: asking LLMs to return code wrapped in JSON dropped code-pass rates **for all four tested models** (Claude 3.5 Sonnet, DeepSeek Coder V2, two GPT-4o builds), with Sonnet and DeepSeek Coder hit hardest. A subtler finding: even when Sonnet produced **no syntax errors** under JSON wrapping, its benchmark score still dropped — meaning JSON escaping doesn't just break code syntax, it **steals reasoning budget** from the model while it's writing code. You cannot fix this by "upgrading the model"; you can only route around it by picking the right protocol. That's why Aider chose plain text + diff blocks over function calls, and why HarWork's file-edit tool feeds Sonnet search/replace blocks rather than "full file inside a JSON string." The harness's value is right here: it accumulates "which protocol works best with which model" so you don't pay the cost again on the next swap.

In the other direction: swap a more powerful LLM into the harness and you'll typically fix 5% of bugs; convert your tool protocol from sync to async streaming and you'll fix 30% in one shot. This is why Cursor, Aider, and Claude Code can all share the same Claude models and still feel completely different products — the shell sets the ceiling.

That's why across the 19 articles in this series, only 1-2 are about "how to call the LLM." The other 17 are about loops, context, tools, sandboxes, streaming, sessions, observability, and DevOps — **which is the actual body of the harness**.

## When Should You Build Your Own Harness?

By now you might be doing the ROI math — "should I build my own?" Here's a quick decision table:

| Scenario | Recommendation |
|----------|----------------|
| Solo dev or small team, mostly coding tasks | Use Claude Code / Cursor / Aider — don't build |
| Embedding an Agent into your own product for end users | Build, or fork an open-source harness like HarWork |
| Domain-specific (medical, legal, manufacturing, ops) | Must build — tool protocol, sandbox rules, approval flow are all industry-unique |
| Regulated environment (finance, government, defense) | Must build — third-party harnesses usually can't pass compliance certification |
| Want to sell an Agent framework to other developers | Must build — otherwise you're reselling someone else's shell |
| Just want to write code faster yourself | First row — don't build |

The core call: **a harness isn't a tool, it's a platform**. If your goal is "I want to code faster," use what exists. If your goal is "let *other people* use Agents to do work in my industry," you need your own — and the rest of this series is a tour of the engineering land mines on that road.

## Figures

1. ![Same problem, different answers — Claude Code / Cursor / Aider / HarWork stack comparison](../assets/img/01-comparison.svg)
2. ![Concentric-circle diagram of the seven Harness components](../assets/img/01-seven-components.svg)
3. ![Naked LLM vs Harness: the fate of one identical prompt](../assets/img/01-naked-vs-harness.svg)

## Next Article

→ [Part 02: HarWork Harness — the 16-layer stack in one picture](./02-harwork-stack-overview.md)

Next time we use real HarWork code as the sample, lay the full 16-layer stack from LLM API down to CI/CD on one page, and report the cloc-measured ratio of business code vs supporting infrastructure — you'll see a counterintuitive number.

---

📌 Series reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/01-what-is-agent-harness.md](../zh/01-what-is-agent-harness.md)
