---
title: "Part 14: AI Artifact Rendering — iframe Overlay + postMessage So Users Can Point at LLM-Generated HTML"
slug: 14-ai-artifact-rendering
date: 2026-08-04
series: harwork-agent-harness
series_index: 14
keywords: [iframe sandbox, postMessage, artifact rendering, design canvas, overlay script, CSS selector path, AI artifact, element annotation, agent harness, harwork, allow-scripts, cross-document messaging]
prev: 13-multi-model-routing
next: 15-design-variants-mix
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/14-ai-artifact-rendering.md
---

# Part 14: AI Artifact Rendering — iframe Overlay + postMessage So Users Can Point at LLM-Generated HTML

> The first 13 posts of this agent harness series stayed in "invisible territory" — loops, context, tools, permissions, sessions, models. But commercial agents don't sell token streams to customers — they sell **artifacts**: HTML mockups, Mermaid diagrams, Markdown reports, SVG icons. **Artifacts only have value once they're seen**. HarWork's design canvas is the most "visual" subsystem in this series — the agent emits HTML, the browser renders it live, the user **points at a button on the page and says "this feels too cramped,"** and on the next turn the agent edits exactly that button. This post unpacks the 3 core techniques behind that path: **iframe sandbox isolation, overlay script injection, and a bidirectional postMessage protocol** — a total of **368 lines of code** (`design-canvas.tsx` 92 + `overlay-script.ts` 154 + `design-annotation-layer.tsx` 122).

## Problem Statement

To get "let users point at agent-generated HTML to edit it" right, you have to answer 4 questions:

1. **Can you just render the HTML directly into the main page?** The AI-generated HTML may include `<script>` tags, `position: fixed` popups, global CSS like `* { box-sizing }` — **any one of those will poison HarWork's own UI**.
2. **What about full iframe isolation?** Then how does the parent know which button the user clicked inside the iframe? Cross-origin `contentDocument` is **read-only** — the browser throws `SecurityError`.
3. **You need to inject your own script into the iframe to capture clicks — how do you stop the AI's artifact from interfering with it?** The AI might (by accident or design) write `window.parent.postMessage('hi', '*')` — your protocol has to distinguish "my injected script speaking" from "the artifact's code speaking."
4. **How do you decouple user annotations from the artifact itself?** When the agent regenerates the HTML on the next turn, the annotation "this button feels too cramped" **must still attach** — otherwise the user redraws annotations after every edit.

These 4 questions = the engineering contract a visualization layer for AI artifacts has to fulfill. HarWork's answers live in 4 files: `packages/web/components/design/design-canvas.tsx` (the iframe host + parent-side protocol), `packages/web/components/design/overlay-script.ts` (the script injected into the iframe, 154 lines), `packages/web/components/design/design-annotation-layer.tsx` (the annotation UI layer), and the `design_annotations` table for decoupled storage (`packages/web/lib/db/design-schema.ts:47-66`).

## Why Naive Approaches Fail

**Naive 1: `dangerouslySetInnerHTML` straight into the main page.** Three immediate failures: (1) AI writes `body { margin: 0 }` and blows up HarWork's layout; (2) AI writes `<script>alert('hi')</script>` which runs on the main page — zero XSS isolation; (3) AI pulls in `tailwindcss/dist.css` or similar global styles that override HarWork's own Tailwind classes. **The main page isn't a sandbox; you can't put untrusted code there.**

**Naive 2: iframe with `sandbox=""` (full isolation).** Looks safe, but `sandbox=""` disables **every capability** — the AI's React/Vue code won't even boot (no `allow-scripts`), forms don't submit, clicks aren't captured. **Full isolation = unusable.** HarWork picks `sandbox="allow-scripts"` (`design-canvas.tsx:86`) — **only scripts, no same-origin, no forms, no popups, no modals** — just enough to run AI-generated interactive logic without granting access to cookies, localStorage, or the parent DOM.

**Naive 3: iframe with `sandbox="allow-scripts allow-same-origin"`.** Adding `allow-same-origin` looks convenient (parent can do `iframe.contentDocument.querySelector(...)`), but **MDN warns explicitly**: when both `allow-scripts` and `allow-same-origin` are set, scripts inside the iframe can delete the sandbox attribute and become a fully-privileged iframe — **effectively no sandbox at all**. HarWork picks **`allow-scripts` only, no `allow-same-origin`** (see `design-canvas.tsx:86`) — the cost is that **any state sharing between parent and child must go through postMessage**.

**Naive 4: Have the iframe load a remote URL (`<iframe src="https://preview-cdn/...">`) instead of `srcdoc`.** You'd need a static hosting service, ephemeral preview URLs, CORS handling — **one more service, one more lifecycle**. HarWork uses `srcDoc={injectedHtml}` (`design-canvas.tsx:85`) — HTML is a string variable, **front-end props → iframe directly**, zero network roundtrips.

**Naive 5: When the user clicks an element, dump the selector into chat history and let the agent reason about it.** Looks expedient, but **the agent only sees text** — `<button class="bg-blue-500">Download</button>` outer-HTML it can read, but **"300px below the viewport" it can't**. HarWork stores annotations as **structured data** in the `design_annotations` table (`design-schema.ts:47`); the next turn agent receives not just text but `elementSelector: 'div.hero > button.cta'` — **precise reference without relying on the LLM's visual reasoning**.

HarWork's actual choices: **minimal `sandbox="allow-scripts"` + injectOverlay injects 154 lines of script + bidirectional postMessage protocol + annotations in a separate table**. Let's unpack.

## Core Solution: 4-Step Pipeline

### Step 1: injectOverlay — slip the overlay script in before `</body>` (`overlay-script.ts:147-154`)

```typescript
export function injectOverlay(html: string): string {
  const script = `<script>${OVERLAY_SCRIPT}</script>`
  const bodyCloseIdx = html.lastIndexOf('</body>')
  if (bodyCloseIdx !== -1) {
    return html.slice(0, bodyCloseIdx) + script + html.slice(bodyCloseIdx)
  }
  return html + script
}
```

8 lines. **`lastIndexOf('</body>')` finds the close tag** — why not regex, why not a DOM parser? Because this is on the hot path (runs every time `srcdoc` changes), wrapped in `useMemo` at `design-canvas.tsx:34-37`. **Regex risks backtracking; a DOM parser clones the entire tree**. `lastIndexOf` is one O(n) pass, n being HTML length — for a ~50KB AI-generated artifact, that's <1ms. **Plain string concat beats structured parsing** — assuming you trust the AI to emit at least a well-formed HTML doc (if there's no `</body>`, the function falls back to appending to the end).

### Step 2: CSS selector path serialization (`overlay-script.ts:9-28`)

```javascript
function getSelectorPath(el) {
  if (el.id) return '#' + el.id;
  var parts = [];
  while (el && el !== document.body && el !== document.documentElement) {
    var tag = el.tagName.toLowerCase();
    if (el.id) { parts.unshift('#' + el.id); break; }
    var cls = Array.from(el.classList).filter(function(c) { return !c.startsWith('__hw'); }).join('.');
    var selector = cls ? tag + '.' + cls : tag;
    var parent = el.parentElement;
    if (parent) {
      var siblings = Array.from(parent.children).filter(function(s) { return s.tagName === el.tagName; });
      if (siblings.length > 1) {
        selector += ':nth-child(' + (Array.from(parent.children).indexOf(el) + 1) + ')';
      }
    }
    parts.unshift(selector);
    el = parent;
  }
  return parts.join(' > ');
}
```

3 rules: (1) **stop at any element with an `id`** — `#hero-cta` is 4× shorter than `body > div.container > div.hero > button.cta`, and more stable; (2) **filter classes starting with `__hw`** — overlay's own highlight class (`__hw-highlight`) must not enter the selector, or the next pick of the same element collides with highlight remnants; (3) **add `:nth-child(N)` only when more than one sibling shares the tag** — single child = no index, **keeping the selector as stable as possible when the AI regenerates** (class names change but the tag + position survive).

The bet under this algorithm: **class names are stable, positions are stable, the AI doesn't randomly swap `<button class="cta">` to `<a class="cta">`** — empirically ~90% hit rate. The remaining 10% fail-to-match, HarWork keeps the annotation as `status: 'pending'` and lets the agent handle it (`design-schema.ts:60-62`).

### Step 3: bidirectional postMessage protocol — iframe ↔ parent (`overlay-script.ts:42-43`, `design-canvas.tsx:39-43`)

```javascript
function send(type, payload) {
  window.parent.postMessage({ source: 'harwork-design', type: type, payload: payload }, '*');
}
```

```typescript
const sendToIframe = useCallback((type: string, payload: unknown = {}) => {
  iframeRef.current?.contentWindow?.postMessage(
    { source: 'harwork-design', type, payload },
    '*',
  )
}, [])
```

**`source: 'harwork-design'` is the protocol namespace** — every HarWork message must carry that key. Both `handleMessage` on the parent (`design-canvas.tsx:49-60`) and the listener inside overlay (`overlay-script.ts:121-141`) check it first and **drop messages that don't match**. That blocks 3 categories of stray traffic: (1) `window.parent.postMessage(...)` from the AI artifact — no `source: 'harwork-design'`, dropped; (2) messages injected by browser extensions (React DevTools and friends) — same; (3) third-party iframes (e.g. a YouTube embed inside the AI artifact) — same. **Namespace fields beat origin checks in srcdoc-iframe scenarios** — because srcdoc iframe `origin` is the string `"null"`, origin checks are useless.

On message types, **parent → child** has 5: `enableOverlay` / `disableOverlay` / `previewStyle` / `resetPreview` / `highlightElement` (`overlay-script.ts:124-140`). **Child → parent** has 4: `elementHovered` / `elementSelected` / `scrollUpdate` / `overlayReady` (grep `send(` for the calls). **Few and flat** — no nested types, no RPC return values — `postMessage` is fundamentally fire-and-forget, **forcing RPC semantics on it just adds timeout and error-propagation complexity**.

### Step 4: annotations in their own table — `design_annotations` (`design-schema.ts:47-66`)

```typescript
export const designAnnotations = sqliteTable('design_annotations', {
  id: text('id').primaryKey(),
  projectId: text('project_id').notNull().references(() => designProjects.id, { onDelete: 'cascade' }),
  versionId: text('version_id').notNull().references(() => designVersions.id, { onDelete: 'cascade' }),
  userId: text('user_id').notNull().references(() => users.id),
  elementSelector: text('element_selector').notNull(),
  content: text('content').notNull(),
  status: text('status', { enum: ['pending', 'applied', 'dismissed'] }).notNull().default('pending'),
  createdAt: integer('created_at', { mode: 'timestamp_ms' }).notNull().$defaultFn(() => new Date()),
})
```

Annotations are **not embedded in the HTML** — the HTML lives in `design_versions.html_content`, annotations live in `design_annotations`, joined by `versionId` + `elementSelector`. That's why annotations **survive** when the agent regenerates HTML on the next turn: annotations are metadata, not part of the artifact.

The state machine has 3 states: `pending` → `applied` (agent has processed it) / `dismissed` (user withdrew it). The GET endpoint supports `?status=pending` filtering (`annotations/route.ts:104`); the PATCH on `[annotationId]` updates status (`[annotationId]/route.ts:50-52`). The agent-side hook lives at `design-iterate.ts:8` — that tool takes `elementSelector` as an arg, and line 60 weaves it into the LLM prompt as `Focus on element: <selector>.` — **precise reference comes from the selector, not from the LLM looking at screenshots**. Today's flow is 1 chat message → 1 design-iterate tool call → 1 selector; batch-feeding all pending annotations into one LLM call is a capability the schema is ready for but isn't auto-wired yet — if you fork HarWork, a small batch tool gets you there. **Without this decoupling, the agent would have to re-parse the full HTML every turn — cost explodes.**

## Counter-Intuitive Takeaway

> **The hard part of iframe sandbox isn't which capabilities to grant — it's not granting `allow-same-origin`**. When you see a PR with `sandbox="allow-scripts allow-same-origin allow-forms allow-popups"` you might assume the author knows their stuff — actually they're **disabling the sandbox**. HarWork deliberately enables only `allow-scripts` (`design-canvas.tsx:86`); the cost is that any state sharing must go through postMessage — but that's exactly the cost you want: **postMessage is an explicit, auditable protocol; same-origin access is implicit shared state and unauditable**. Same-origin is convenient, but when your iframe content is LLM-generated and untrusted, **an explicit protocol is the only moat**.

More counter-intuitively: **inside a `sandbox="allow-scripts"` iframe (no `allow-same-origin`), `window.origin === "null"`**. You cannot do `event.origin === 'https://harwork.example.com'` checks — origin is literally the string `"null"`. So HarWork uses a **namespace field** (`source: 'harwork-design'`) instead of origin checks (`design-canvas.tsx:52`, `overlay-script.ts:123`). If you ever see code like `if (e.origin !== window.origin) return` sandboxing a srcdoc iframe, **the code after that `return` never runs** — both sides are `"null"`. Namespace + `e.source !== iframeRef.current.contentWindow` (`design-canvas.tsx:50`) is the correct answer for srcdoc scenarios.

The most counter-intuitive detail: **the overlay script is a string literal, not a separate `.js` file**. `OVERLAY_SCRIPT` is the 144-line backtick template literal at `overlay-script.ts:1-145`. Why not place it at `public/design-overlay.js` and have the iframe `<script src="/design-overlay.js">`? Because **a srcdoc iframe's origin is `"null"`** — `<script src="/...">` resolves to `null/design-overlay.js`, which the browser **refuses to load**. Embedding the script **inside the srcdoc string** is the only way to inject code in sandbox mode. So HarWork keeps it as an ES module string literal — **TypeScript gives you syntax highlighting, the build bundles it into the HTML, zero network roundtrips, zero cross-origin issues**.

## Three Production Traps

**Trap 1: Two postMessage protocols co-exist.** `overlay-script.ts:43` sends `{ source: 'harwork-design', type: 'elementSelected', payload: {...} }`, but `lib/design/annotation-protocol.ts:1-8` defines a separate "prefix-style" protocol `{ type: 'harwork-design:element-clicked', payload: {...} }` — and `design-annotation-layer.tsx:55` checks for the latter via `isOverlayMessage`. **Why both exist**: the early version used source+type; a later refactor introduced the `harwork-design:` prefix style, but the design-canvas.tsx mainline never finished migrating. **Production cost**: annotation-layer doesn't receive messages directly from the design-canvas iframe (type mismatch); the current workaround is the parent component re-emitting the message. **If you fork HarWork**, recommend **collapsing the two into one** — pick the prefix style, it's easier to filter in Chrome devtools' "messages" panel.

**Trap 2: Events fired before `enableOverlay` are lost.** `design-canvas.tsx:66-68` sends `enableOverlay`/`disableOverlay` when `editMode` toggles, but the iframe loads asynchronously — **the parent might `sendToIframe` before the overlay script has even run** — that message **never arrives** (postMessage doesn't buffer). HarWork's current mitigation: overlay sends `send('overlayReady', {})` on boot (`overlay-script.ts:143`); the parent **should** key off that signal before firing `enableOverlay` — except design-canvas.tsx **doesn't listen for `overlayReady`** (grep `overlayReady` finds no consumer on the parent side). Result: on the first open of a design, **clicks sometimes don't surface the annotation popup**, and you have to toggle `editMode` once to recover. **Fixes**: have the parent `useEffect` listen for `overlayReady` before sending `enableOverlay`; or just `enabled = true` at script boot and drop the `enableOverlay` signaling altogether.

**Trap 3: `getSelectorPath` breaks after React remount in production.** When the AI regenerates HTML, class names usually shift only a little (handful of Tailwind classes), but **Tailwind JIT in a production build can give you `class="text-sm font-bold sm:text-base"` — four space-separated classes with colons**. `getSelectorPath` joins them with `.` into `text-sm.font-bold.sm:text-base` — a selector **containing `:`**, which `querySelector` interprets as a pseudo-class and **throws on**. HarWork currently doesn't `CSS.escape` the `:` — Tailwind responsive classes like `sm:`/`md:`/`lg:` make the selector blow up. **Fix**: at `overlay-script.ts:15` add `cls.replace(/:/g, '\\\\:')`, or wrap each class with `CSS.escape(c)`. **If your production deployment serves Tailwind output, you must fix this.**

## Diagrams

1. ![iframe sandbox + overlay injection architecture](../assets/img/14-iframe-architecture.svg)
2. ![CSS selector path serialization](../assets/img/14-selector-serialization.svg)
3. ![Annotation-vs-artifact decoupling data flow](../assets/img/14-annotation-decouple.svg)

## Next Up

→ Part 15: Multi-variant design — when the agent outputs 3 versions at once, how do users mix-and-match?

iframe overlay solves "point at one artifact and edit it." But the real high-frequency scenario in a commercial design agent is **comparing 3 variants side by side** — hero from A, nav from B, footer from C. HarWork's multi-variant system isn't "3 independent iframes" — it diffs the 3 HTML versions into sections, then lets users **drag-and-drop across variants**. This "AI artifact + human composition" collaboration model is more interesting than single-track iteration — next post unpacks the `design_variants` table, the version tree, and the cross-variant merge algorithm.

---

📌 Reading map: [reading-map.md](../reading-map.md)
🔗 中文版: [zh/14-ai-artifact-rendering.md](../zh/14-ai-artifact-rendering.md)
