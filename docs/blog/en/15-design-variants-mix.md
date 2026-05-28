---
title: "Part 15: Multi-Variant Compare + Mix-and-Match — When the Agent Outputs 3 Designs, Users Drag Across to Compose a 4th"
slug: 15-design-variants-mix
date: 2026-08-11
series: harwork-agent-harness
series_index: 15
keywords: [AI design variants, mix and match, design comparison, variant compositing, design canvas, agent harness, harwork, multi-variant generation, design recipe, section-level mixing]
prev: 14-ai-artifact-rendering
next: 16-optimistic-lock-collab
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/15-design-variants-mix.md
---

# Part 15: Multi-Variant Compare + Mix-and-Match — When the Agent Outputs 3 Designs, Users Drag Across to Compose a 4th

> Last post unpacked "point at one artifact and edit it." But the real high-frequency scenario in a commercial design agent is **comparing 3 variants side by side** — hero from A, nav from B, footer from C. HarWork's multi-variant system isn't "3 independent iframes" — it makes **composition a first-class citizen**: the user picks, across 8 section dimensions, **which section comes from which variant**, then POSTs to `/variants/mix` to generate a 4th variant. This post unpacks 4 things: the 3-column compare layout strategy, the mix "recipe" protocol (not HTML synthesis), the `design_variants` schema's status state machine, and **why the "version tree" is actually just a linear log in the schema** — a total of **818 lines of code** (`variant-comparison-canvas.tsx` 94 + `variant-mix-panel.tsx` 133 + `variant-selector.tsx` 105 + `variant-utils.ts` 41 + `variants/route.ts` 143 + `variants/mix/route.ts` 125 + `[variantId]/route.ts` 177).

**Jump to:** [Problem](#problem-statement) · [Naive approaches](#why-naive-approaches-fail) · [4-step pipeline](#core-solution-4-step-pipeline) · [Counterintuitive](#counter-intuitive-takeaway) · [Pitfalls](#three-production-traps)

## Problem Statement

To get "the agent emits 3 designs and the user composes a 4th" right, you have to answer 4 questions:

1. **Will 3 iframes side-by-side blow up the viewport?** A desktop design is 1280px wide — 3 side-by-side is 3840px, and the user's 1440px screen can't hold it.
2. **Is mix-and-match real HTML compositing, or just "recipe" recording?** Real HTML compositing needs a section diff algorithm; recipe recording is just `{ variantId, sections: [...] }` for the agent to re-generate from on the next turn. Two paths, wildly different cost.
3. **3 variants share one overlay script, but how do click events know which variant they came from?** Part 14's postMessage protocol carries `source: 'harwork-design'`, but all 3 iframes send the same `source` — how do you demultiplex?
4. **Once a variant is "selected" by the user, how does the schema follow that?** Selecting A doesn't mean B/C should be deleted — the user might reverse course. State can't be a boolean.

These 4 questions = the engineering contract for AI multi-variant compare. HarWork's answers live in 4 files: `packages/web/components/design/variant-comparison-canvas.tsx` (3-column layout + iframe render), `packages/web/components/design/variant-mix-panel.tsx` (the 8-section selection UI), `packages/web/lib/design/variant-utils.ts` (recipe protocol + label generation), and `packages/web/app/api/design/projects/[id]/variants/mix/route.ts` (the mix endpoint implementation).

## Why Naive Approaches Fail

**Naive 1: render 3 iframes each at 1280px and let users scroll horizontally.** Visually "3 desktop designs in a row" exists, but UX collapses — to compare hero heights, the user has to **scroll inside each of the 3 canvases separately**. HarWork's approach (`variant-comparison-canvas.tsx:26`): `iframeWidth = Math.min(viewportWidths[viewport] || 1280, 400)` — **force width to ≤400px**, even desktop is squeezed down to 400. The cost is desktop designs render at a scale — but **comparison is about layout structure and proportion, not pixel fidelity**, so the trade-off pays.

**Naive 2: have the mix endpoint actually synthesize HTML — take 3 variants' HTML, slice by section, stitch a new HTML.** You'd have to write: what *is* a `section`? Is navigation `<nav>` or `<header>`? Is hero `<section class="hero">` or `<div class="hero-banner">`? The AI generates different structures every time — **the slicing algorithm is always chasing new shapes**. HarWork deliberately doesn't compose HTML: the mix endpoint (`variants/mix/route.ts:84-105`) writes a single metadata row `{ type: 'mixed', sources: [{ variantId, sections }] }` — **the recipe, not the artifact**. Actual HTML generation is left to the agent on a subsequent turn, using that metadata as reference.

**Naive 3: let the user drag-and-drop sections directly on the canvas to compose.** Sounds slick, but you'd need: drag hit-region detection, section boundary detection, cross-iframe drag (browser-native drag-and-drop **doesn't work between cross-origin iframes**)… dev cost 5× more, and **the user's notion of "section" may not match the AI's**. HarWork uses 8 **predefined** sections (`variant-mix-panel.tsx:13-22`): navigation / hero / content / sidebar / footer / colorScheme / typography / layout — **vocabulary collapses**, the agent reads them at a glance, and the UI is just a button grid.

**Naive 4: treat variants as one-shot generates — once the user picks A, delete B/C.** In practice users reverse course: "I picked A, but B's typography is actually better." HarWork's schema (`design-variants-schema.ts:14`) uses a 3-state enum `['active', 'selected', 'discarded']` — **"selected" doesn't delete the others**, and the DELETE endpoint is a soft delete (`variants/[variantId]/route.ts:166`: sets `status='discarded'` instead of physical delete). **Any "select == discard others" schema is wrong** — the user's face when reversing course will not be friendly.

**Naive 5: model the version tree with `parentVersionId` as a DAG.** Reasonable-looking: mix v2 out of v1, fork v3a and v3b out of v2, the DAG follows the user's thinking. HarWork's actual schema (`design-schema.ts:30-45`) **has no `parentVersionId`** — only a monotonically-increasing `versionNumber` (line 35). This is a **deliberate simplification**: trees need UI support (branch viz, merge conflicts), DB queries need recursive CTEs, but **90% of the time users iterate on the latest version**; the remaining 10% is "revert to v3" — linear history + the user manually forking a new project is enough. **People who say "version tree" usually haven't actually used one in anger.**

HarWork's actual choices: **forced 400px iframe + mix stores recipe only + 8 predefined sections + 3-state enum + linear version log**. Let's unpack.

## Core Solution: 4-Step Pipeline

### Step 1: 3-column compare canvas — CSS grid + forced narrow width (`variant-comparison-canvas.tsx:24-44`)

```tsx
const visibleVariants = variants.filter((v) => selectedIds.includes(v.id))
const columnCount = Math.min(visibleVariants.length, 3)
const iframeWidth = Math.min(viewportWidths[viewport] || 1280, 400)
// ...
<div
  className="grid gap-4 h-full"
  style={{ gridTemplateColumns: `repeat(${columnCount}, 1fr)` }}
>
```

3 key decisions: (1) **`columnCount = min(visibleVariants.length, 3)`** — at most 3 columns; more than 3 variants and the user toggles through the selector (`variant-selector.tsx:30-35` multi-select checkbox); (2) **`iframeWidth = min(viewportWidths, 400)`** — as above, forced narrow during compare; (3) **`grid-template-columns: repeat(N, 1fr)`** — CSS grid equal-split, not flex, so columns don't jitter when variants have different heights. This block is 21 lines (`variant-comparison-canvas.tsx:39-91`); the rest is chrome (title bar, "Select" button, loading placeholder).

### Step 2: mix recipe protocol (not HTML synthesis) (`variant-utils.ts:9-28`)

```typescript
export interface MixSource {
  variantId: string
  sections: string[]
}

export interface MixedVariantMetadata {
  type: 'mixed'
  sources: MixSource[]
  createdAt: string
}

export function buildMixedVariantMetadata(input: {
  sources: MixSource[]
}): MixedVariantMetadata {
  return {
    type: 'mixed',
    sources: input.sources,
    createdAt: new Date().toISOString(),
  }
}
```

**The protocol essence: a JSON recipe, not a composed artifact.** On the UI side (`variant-mix-panel.tsx:34-44`), the user's 8 section choices fold into a `Map<variantId, sections[]>`:

```typescript
const sourceMap = new Map<string, string[]>()
for (const [section, variantId] of Object.entries(selections)) {
  const existing = sourceMap.get(variantId) || []
  existing.push(section)
  sourceMap.set(variantId, existing)
}
const sources = Array.from(sourceMap.entries()).map(([variantId, sections]) => ({
  variantId, sections,
}))
```

After POSTing to `/variants/mix`, the server (`variants/mix/route.ts:84-110`) does 3 things: (1) validate each source has `variantId` and non-empty `sections` (lines 56-66); (2) use `inArray` to verify all variantIds belong to the current project (lines 70-82) — **prevents cross-project data theft**; (3) write a `designVariants` row with `metadata` = `JSON.stringify({ type: 'mixed', sources, createdAt })`, `status: 'active'`. **No HTML synthesis** — the `snapshotPath` field is just a placeholder (`variants/${id}/${variantId}.json`).

Downstream the agent reads this mixed variant's metadata, learns "hero from A, navigation from B," and **re-generates** the full HTML itself — that pipeline is **not yet automated** in the current codebase; the agent re-running with the metadata is manually triggered (the user says "regenerate based on the mixed variant" in chat). That's the cost of a **recipe protocol**: decoupling buys you flexibility but loses end-to-end automation.

### Step 3: 3-state enum variant lifecycle (`design-variants-schema.ts:14-16`, `variants/[variantId]/route.ts`)

```typescript
status: text('status', { enum: ['active', 'selected', 'discarded'] })
  .notNull()
  .default('active'),
```

3 states: **active** (default, candidate) / **selected** (user picked as main) / **discarded** (user gave up, soft delete). Transitions:
- `POST /variants` creates everything as `active` (`variants/route.ts:70`)
- `PATCH /variants/[variantId] body.status=selected`: user clicks "Select" in the comparison canvas (`variant-comparison-canvas.tsx:57`)
- `DELETE /variants/[variantId]`: **soft delete, no physical removal** — `variants/[variantId]/route.ts:166-167`: `db.update().set({ status: 'discarded' })`
- `GET /variants` filters discarded by default (`variants/route.ts:131-132`: `status === 'active'` is the default condition)

**Why not a boolean `isSelected`**: because the user's selection isn't mutually exclusive — they might "pick A but keep B around for mix reference." A boolean forces either "selecting A auto-unselects B" (intolerable UX) or "multiple can be `isSelected=true` at once" (semantically vague). A 3-state enum **separates "selection" and "deletion" into two independent dimensions** — selection is promote, deletion is demote, **not two ends of the same axis**.

### Step 4: variant label auto-generation + rate limit (`variant-utils.ts:1-7`, `variants/route.ts:20-25`)

```typescript
export function generateVariantLabels(count: number): string[] {
  const labels: string[] = []
  for (let i = 0; i < count; i++) {
    labels.push(`Variant ${String.fromCharCode(65 + i)}`)
  }
  return labels
}
```

`String.fromCharCode(65 + i)` = ASCII 'A' + i → `Variant A`, `Variant B`… up to `Variant E` (count capped at 5, `validateVariantCount` in `variant-utils.ts:37-41`). **Why letters instead of numbers**: in the mix-and-match UI, users verbally say "A's hero, B's nav" — letters are more conversational than numbers and don't collide with `versionNumber`.

Rate limit (`variants/route.ts:20-25`): 20 variant creates per user per minute, 10 mixes per minute (`variants/mix/route.ts:20-25`). **Mix is rate-limited tighter than generate** — because mix is user-driven and generate is agent-initiated; user-driven frequency should be slower than agent, otherwise impatient clicking blows past the limiter.

## Counter-Intuitive Takeaway

> [!IMPORTANT]
> **The real value of "AI outputs 3 variants at once" is not "providing 3 options" — it's "the elements of those 3 variants can be pulled apart and recombined."** If variants can't be decomposed, 3 variants = a beefed-up retry — the user picks one, throws two away, the agent burns 3× the tokens, the user gets 0× the upgrade. HarWork's mix-and-match makes "composition" a first-class citizen (8-section button grid), **turning "I want A's hero + B's navigation" from spoken description into structured input** — the agent's next turn input isn't text, it's `{ sources: [{ variantId: 'A', sections: ['hero'] }, { variantId: 'B', sections: ['navigation'] }] }`. Precise reference, no language understanding required.

More counter-intuitively: **the mix endpoint doesn't synthesize HTML.** When you first read `variants/mix/route.ts` you expect "input 3 variants, output 1 composed HTML" — actually it writes one metadata row and returns 201. **HTML synthesis is the LLM's job, not the server's** — the server doing section diff/merge would mean: every time the AI changes HTML structure (`<nav>` becomes `<header>`) the algorithm has to follow. Hand "what DOM node is hero?" to the LLM; the server only keeps **intent** (which variant, which sections) — that's the real decoupling.

The most counter-intuitive engineering detail: **what's called the "version tree" is actually a linear log in the schema.** Part 14's closing teaser said "the version tree is a DAG," but reading `design-schema.ts:30-45` reveals `design_versions` has **no `parentVersionId`** — only a monotonically-increasing `versionNumber` (line 35), and new versions are inserted with `max(versionNumber) + 1` (`versions/route.ts:48`). This is a **deliberate simplification**: 90% of AI design collaboration scenarios are linear iteration on the latest version, and a DAG is over-engineering before product shape stabilizes. **The "v4" from mix is sibling-equivalent to v1/v2/v3 in the schema; you trace its sources via the mix variant's metadata.** This near-DAG is enough; promoting to a real DAG = add a `parentVersionId` column. **Linear first, tree later — that's honest acknowledgment that product shape is still changing.**

## Three Production Traps

> [!WARNING]
> **Pitfall 1 — sandbox is inconsistent between snapshotHtml and previewUrl paths.**
>
> `variant-comparison-canvas.tsx:72` uses `srcDoc={variant.snapshotHtml}` with `sandbox="allow-scripts"` (matches Part 14, safe), but line 79 uses `<iframe src={variant.previewUrl}>` with `sandbox="allow-scripts allow-same-origin"` — Part 14 hammered repeatedly that both together **equals no sandbox**. **Why both exist**: `previewUrl` goes through HarWork's own nginx static preview (same-origin), so historically `allow-same-origin` was added so the parent could `querySelector` the iframe content. But **that opens a sandbox-escape door for same-origin static previews** — when the AI artifact writes `parent.location = '...'`, the previewUrl path succeeds, the srcDoc path is blocked. **Fix**: change line 79 to `sandbox="allow-scripts"` too, give up same-origin access on the previewUrl path, route everything through postMessage — consistent with srcDoc.

> [!WARNING]
> **Pitfall 2 — `variant.snapshotHtml` doesn't exist in the schema.**
>
> `variant-selector.tsx:10` defines the `Variant` interface with `snapshotHtml?: string`, but `design-variants-schema.ts` **doesn't have this column** — the variant table only has `snapshotPath` (path string placeholder) and `previewUrl`. Meaning: for the 3-column compare canvas to render variant HTML, the frontend has to inject the `snapshotHtml` from `design_versions` into the Variant object at runtime — that's what `app/design/project/[id]/page.tsx:110`'s `if (v.snapshotHtml) setCurrentHtml(...)` is gluing. **Production cost**: if a freshly-mixed variant has no one to populate `snapshotHtml` (and no one writes a matching `design_versions` row), the 3-column canvas displays "Generating..." forever (lines 84-86). **Fix**: in the variant lifecycle add a "mix → generate the corresponding design_versions row" automation, or actually store snapshotHtml on the design_variants table (accept the redundancy).

> [!WARNING]
> **Pitfall 3 — mix-panel's button grid becomes 40 buttons at 8 sections × 5 variants.**
>
> `variant-mix-panel.tsx:96-114` uses nested map for rendering: 8 rows of section × N columns of variant. When the user has 5 variants open, the UI is 40 buttons — **screen readers have no group semantics** (no `role="radiogroup"`), keyboard Tab order traverses 40 buttons before completing a selection. **Production cost**: accessibility audits flag red; on mobile, 40px buttons easily mis-tap neighboring sections. **Fix**: use a native `<select>` or `<radiogroup>` per section — gives a11y proper semantics and drops Tab count from 40 to 8.

## Diagrams

1. ![3-column compare canvas layout + forced narrow width strategy](../assets/img/15-comparison-canvas-layout.svg)
2. ![mix recipe protocol · JSON doesn't synthesize HTML](../assets/img/15-mix-recipe-protocol.svg)
3. ![variant 3-state machine + linear version log](../assets/img/15-variant-statemachine.svg)

## Next Up

→ Part 16: Optimistic locking real-time collaboration — why AI-artifact multi-user collab shouldn't use CRDT

Mix-and-match solves "single user composing across variants." But the more useful AI artifacts (design mocks, PRDs, HTML) become, the higher the demand for concurrent editing — A is editing hero while B edits footer, who overrides whom at commit time? Traditional CRDT (Yjs / Automerge) is great for plain documents, but **every edit to an AI artifact carries semantic decisions** ("I made this button red because of the brand primary color"); auto-merge hands semantic decisions to a diff algorithm. HarWork chose optimistic locking + explicit conflict UI — next post unpacks how `design_versions.versionNumber` plays the optimistic lock role, how the WebSocket `design-collab` channel demuxes, and organization-level share token TTL management.

---

📌 Reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/15-design-variants-mix.md](../zh/15-design-variants-mix.md)
