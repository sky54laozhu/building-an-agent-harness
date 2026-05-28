---
title: "Part 11: Per-User Persistent Docker — pause/unpause to skip cold starts"
slug: 11-persistent-docker
date: 2026-07-14
series: harwork-agent-harness
series_index: 11
keywords: [docker pause, container lifecycle, cgroup freezer, persistent container, per-user sandbox, idle sweep, dockerode, agent runtime, cold start, agent harness]
prev: 10-session-storage
next: 12-websocket-30s-grace
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/en/11-persistent-docker.md
---

# Part 11: Per-User Persistent Docker — pause/unpause to skip cold starts

> Part 10 parked session data in SQLite — when users return, their conversation history is intact. But what about the **runtime environment**? The Linux sandbox the AI runs commands in — do we spin up a new container per conversation? HarWork's answer: **one persistent container per user, `docker pause` after 30 idle minutes to freeze CPU, `docker unpause` to wake instantly when they're back**. Cold-starting a fat image (ubuntu + node + python + code-server + ssh) takes 10+ seconds; pause uses the cgroup freezer, unpause is sub-second. This post dissects HarWork's container lifecycle table (**`packages/web/lib/workspace/docker.ts` 271 lines + the idle sweep in `packages/engine/src/session/manager.ts` + the two-layer guard in `dev-server.ts`**), with the central question being **why pause, not stop**.

**Jump to:** [Problem](#problem-statement) · [Naive approaches](#why-naive-approaches-fail) · [Persistent containers](#core-solution-per-user-persistent-containers--30min-idle-sweep--two-layer-pause-guard) · [Implementation](#key-implementation-details) · [Counterintuitive](#counterintuitive-conclusion) · [Production pitfalls](#three-production-pitfalls)

## Problem Statement

Giving every user a Linux sandbox to run commands in sounds simple. To make it work, you need to solve at least 5 problems:

1. **What's the granularity?** Per-request containers (new one per HTTP call)? Per-session? Per-user? The first two have visible cold-start latency. The last forces "who pays for memory while users are offline?"
2. **How do we save when idle?** A base image ≈ 2GB, running takes 1–3GB RAM. N online users = N × 3GB. Should idle containers free resources?
3. **How do we wake fast?** Stopping and restarting reruns entrypoint + sshd + code-server — 10+ seconds. How do we make "idle → resume" feel instant?
4. **How do we know they're back?** Browser open, WebSocket reconnect, SSH connect, cron trigger fire, preview proxy serving 8080 — all five entry points must "wake the container before serving."
5. **Can backends swap?** Single-node Docker isn't enough for production. What about K8s? K8s has no native pause — backend swaps can't kill the idle-sweep logic.

All five must be solved. HarWork's answer lives in **`packages/web/lib/workspace/docker.ts` (271 lines) + `packages/engine/src/session/manager.ts` (265 lines) + the backend selector in `packages/engine/src/dev-server.ts`**, with the core being: **per-user persistent containers + 30-minute idle sweep + cgroup freezer pause + 5 ensureRunning entry points + Docker/K8s dual-backend abstraction**.

## Why Naive Approaches Fail

**Naive 1: Per-request containers.** Spin up a new container per user message, tear it down after. Maxes isolation, but every cold start takes 5–13 seconds (ubuntu + node + code-server + ssh aren't cheap to boot). **A user types three sentences and is gone after 30 seconds of waiting.**

**Naive 2: Always running, never pause.** 1000 users = 1000 × 3GB = 3TB RAM permanently allocated. Most of the time these containers do nothing, just burning money to stay open. **Unit price vs. concurrency ratio is wrong.**

**Naive 3: Use `docker stop` instead of pause.** Stop releases memory — looks great — but **processes get SIGTERM'd**. Dev server takes 3–5s to restart, node JIT cache is gone, code-server browser tab needs to click back to where it was. Pause uses **the cgroup freezer (SIGSTOP)** — processes are frozen in memory, waking is a SIGCONT, milliseconds back to where they were. **Stop saves memory but loses warm state; pause keeps the warm state, the scheduler just skips it.**

**Naive 4: Hard pause after 30 minutes.** User has an SSH terminal open mid-vim, code-server browser tab open — hard pause and the terminal freezes, the IDE spins. **The pause decision can't only look at last activity — it must also check process-layer connections.**

**Naive 5: Engine talks to dockerode directly.** The Engine package gets bound to Docker. K8s migration means rewriting `SessionManager.startIdleSweep`. HarWork chose callback injection: `pauseContainer?: (id) => Promise<void>` is passed in — `dev-server.ts` reads `WORKSPACE_BACKEND` and picks the impl. Docker and K8s both enter through the same callback.

HarWork's answer: **per-user container name `harwork-${userId}` + container_id stored in users table + 60-second sweep tick + 30-minute idle threshold + pause-time `pgrep sshd` + `ss` check for code-server connections + five ensureContainerRunning entry points + Docker/K8s dual backend via callback injection**.

## Core Solution: Per-User Persistent Containers + 30min Idle Sweep + Two-Layer Pause Guard

### Container naming and persistence (`web/lib/workspace/docker.ts:19-61`)

```typescript
async provision(userId: string): Promise<string> {
  const containerName = `harwork-${userId}`
  // ... reuse if it already exists
  const container = await docker.createContainer({
    Image: BASE_IMAGE,           // 'harwork-base:latest'
    name: containerName,
    Cmd: ['sleep', 'infinity'],   // ← process does nothing, container just stays open
    Env: [...],
    HostConfig: {
      NanoCpus: 2_000_000_000,    // 2 cores
      Memory: 3 * 1024 * 1024 * 1024,  // 3GB
      Binds: [`harwork-data-${userId}:/workspace`],  // ← per-user volume
      RestartPolicy: { Name: 'unless-stopped' },
      NetworkMode: NETWORK_NAME,
    },
    User: 'worker',               // ← non-root
    WorkingDir: '/workspace',
  })
  await container.start()
  return container.id
}
```

**Key design: the container name is derived from `harwork-${userId}`** — repeated `provision()` calls return the existing container (the try/catch at `docker.ts:23-29`), never duplicate. The container ID lands in `users.container_id` (`schema.ts:11`), so next time we read DB instead of querying docker.

**Cmd is `sleep infinity`** — the container doesn't run an app, it's just an idle Linux sandbox. The AI wants to run a command? Engine uses `docker.exec` to start an ephemeral process in this container ([Part 07](07-tool-system.md)'s BashTool takes this path).

**Volume `harwork-data-${userId}:/workspace`** is the per-user persistent volume — even after container stop/remove, the volume survives, and the next `provision` mounts it back. This is where user data is truly persisted.

### Idle sweep: 60s heartbeat + 30min threshold (`session/manager.ts:234-257`)

```typescript
startIdleSweep(opts: IdleSweepOptions): void {
  const intervalMs = opts.intervalMs ?? 60_000
  const idleThresholdMs = opts.idleThresholdMs ?? 30 * 60 * 1000

  this._sweepTimer = setInterval(async () => {
    const now = Date.now()
    for (const [userId, session] of this.sessions) {
      if (
        session.connectionCount === 0 &&         // ← no WebSocket connections
        !session.isAgentRunning &&                // ← no agent running
        session.containerId &&                    // ← container provisioned
        now - session.lastActivityAt > idleThresholdMs  // ← 30 min of no activity
      ) {
        try {
          await opts.onIdle(userId, session.containerId)  // ← dispatch pause
          console.log(`[idle-sweep] Paused container for user ${userId}`)
        } catch (err) { ... }
        session.clearEventBuffer()  // ← drop buffer, reconnect starts fresh
      }
    }
  }, intervalMs)
}
```

**All 4 AND conditions must hold to pause**:
- No WebSocket connections (user closed the tab)
- No agent currently running (not in the middle of an LLM call)
- Container is provisioned (not a new user)
- More than 30 minutes since last activity

Every 60 seconds, sweep all sessions (Map) and dispatch matching ones to pause. **This is a cooperative sweep** — SessionManager doesn't know about Docker; it goes through the `onIdle` callback (`ws-server.ts:74-81`) down to the lower layer.

### Two-layer pause guard: connection + process (`dev-server.ts:538-574`)

A green light from SessionManager isn't enough — the container might still have an SSH terminal logged in, or a code-server browser connection that didn't close. `dev-server.ts`'s `pauseContainerFn` is the **real decision point**:

```typescript
pauseContainerFn = async (containerId: string) => {
  const container = docker.getContainer(containerId)
  const info = await container.inspect()
  if (!info.State.Running || info.State.Paused) return  // ← already stopped/paused

  // Guard 1: check SSH sessions
  const sshCount = await containerExec(container, ['pgrep', '-c', '-u', 'worker', 'sshd'])
  if (parseInt(sshCount) > 0) {
    console.log(`[idle-sweep] Skipping pause — ${sshCount} active SSH session(s)`)
    return
  }

  // Guard 2: check established code-server connections (port 8443)
  const wsCount = await containerExec(container, [
    'sh', '-c', "ss -tn state established '( sport = :8443 )' | tail -n +2 | wc -l"
  ])
  if (parseInt(wsCount) > 0) {
    console.log(`[idle-sweep] Skipping pause — ${wsCount} active code-server connection(s)`)
    return
  }

  await container.pause()  // ← real pause goes here
}
```

**The two guards check different things**:
- SessionManager knows whether **the user's WebSocket is connected** (HarWork's own connection)
- The pause guard knows whether **anything is alive inside the container** (SSH terminals, code-server IDEs) — neither goes through WebSocket, so SessionManager can't see them

**Both guards run `docker exec` inside the container** to pgrep/ss for the real state. If guard exec throws (catch swallows), we proceed (it means the container is unhealthy, pause is meaningless anyway).

### Resume: 5 entry points all call ensureRunning (`dev-server.ts:532-537`)

```typescript
ensureContainerRunningFn = async (containerId: string) => {
  const container = docker.getContainer(containerId)
  const info = await container.inspect()
  if (info.State.Paused) await container.unpause()         // ← paused → wake
  else if (!info.State.Running) await container.start()    // ← stopped → start
}
```

Only one line of core logic — but **callers come from 5 entry points** (grep `ensureContainerRunning`):
- WebSocket receives a user message (`ws-message-handlers.ts:193, 377`)
- Preview proxy forwards a request (`preview-proxy.ts:154`)
- SSH gateway accepts a connection (`ssh-gateway.ts:301`)
- Cron / trigger fires on schedule (`trigger-executor.ts:274`)
- HTTP API hits the container (`dev-server.ts:467`)

**Every entry point calls ensureRunning first, then does the real work** — no matter which door the user comes back through, the container wakes automatically. pause/unpause is completely transparent to callers.

### Docker vs K8s: backend injected via callback (`dev-server.ts:506-575`)

```typescript
const WORKSPACE_BACKEND = process.env.WORKSPACE_BACKEND || 'docker'

let pauseContainerFn: (containerId: string) => Promise<void>
let ensureContainerRunningFn: (containerId: string) => Promise<void>

if (WORKSPACE_BACKEND === 'k8s') {
  const k8s = new K8sWorkspaceBackend({ ... })
  ensureContainerRunningFn = async (userId) => { await k8s.ensureRunning(userId) }
  pauseContainerFn = async (userId) => { await k8s.pause(userId) }
} else {
  ensureContainerRunningFn = async (containerId) => { /* docker.unpause/start */ }
  pauseContainerFn = async (containerId) => { /* docker.pause + guards */ }
}
```

The K8s backend's `pause` is a no-op (the comment at `workspace/k8s.ts:160-161` literally says "K8s doesn't support pause natively") — the K8s alternative is scale-to-zero or sidecar-injected freezing. **SessionManager doesn't know any of this** — it just calls `onIdle`; where pause lands is the backend's concern.

This is the 4th appearance of the "interface in core, implementation in wrapper" pattern in this series (Tool interface → Hook protocol → Storage interface → Workspace backend).

## Key Implementation Details

Five details that aren't obvious from a casual read:

**1. Where lastActivityAt gets updated (`session/manager.ts:46-48`)**

```typescript
recordActivity(): void {
  this._lastActivityAt = Date.now()
}
```

`recordActivity()` is called when a WebSocket message arrives, when an agent starts running, or when ensureContainerRunning fires. **Real interaction stamps the timestamp** — passively keeping a WebSocket open doesn't count (30 minutes of no messages and you still get paused).

**2. Mid-flight agents are never paused (`manager.ts:243`)**

```typescript
session.connectionCount === 0 && !session.isAgentRunning && ...
```

The `!session.isAgentRunning` guard ensures **a running agent never gets paused mid-flight**. Even past 30 minutes, if the agent loop hasn't returned, sweep skips this session. Per Part 03, the agent loop's finally block resets `isAgentRunning` to false — only the next sweep tick gets a shot.

**3. Container name "resurrection" mechanism (`docker.ts:23-32`)**

```typescript
try {
  const existing = docker.getContainer(containerName)
  const info = await existing.inspect()
  const onCorrectNetwork = !!info.NetworkSettings.Networks[NETWORK_NAME]
  if (onCorrectNetwork) {
    return info.Id  // ← reuse the existing container directly
  }
  try { await existing.stop({ t: 5 }) } catch { /* may already be stopped */ }
  await existing.remove()  // ← old container on wrong network → remove & recreate
} catch {
  // Container doesn't exist, create it
}
```

`provision()` is really an **idempotent get-or-create** — repeated calls return the same container. But a container on the wrong docker network (network renamed during upgrade) is detected as "stale" and rebuilt. **Stable container name + stable data volume = user data is naturally recoverable**.

**4. Double-check in resolve (`resolve.ts:18-44`)**

```typescript
export async function resolveContainerId(userId: string): Promise<string> {
  const user = await db.query.users.findFirst({ ... })
  if (user?.containerId) {
    const status = await containerManager.getStatus(user.containerId)
    if (status.status !== 'not_found') return user.containerId
    // ↑ container was manually `docker rm`'d → DB still has stale ID
    await db.update(users).set({ containerId: null })
  }
  const containerId = await containerManager.provision(userId)
  await db.update(users).set({ containerId })
  seedSkillsToContainer(containerId).catch(() => {})  // ← async seed, don't block
  return containerId
}
```

**Trust the DB-cached containerId, but verify** — `getStatus` actually queries docker daemon, and 'not_found' means someone manually `docker rm`'d it. Clear the stale ID and re-provision. `seedSkillsToContainer` is **not awaited** — users get their container immediately and can start working while skills trickle into `/workspace/.claude/skills`. Late arrivals don't block the hot path.

**5. K8s pause is a no-op, not a throw (`workspace/k8s.ts:160-161`)**

```typescript
async pause(_workspaceId: string): Promise<void> {
  // K8s doesn't support pause natively.
  // Scale-to-zero or sidecar freeze should be configured at the cluster level.
}
```

After switching to K8s, `pause` becomes a no-op rather than a throw. **Why not just throw?** Because SessionManager shouldn't have to know backend differences — a pause failure can't crash the sweep loop. This is the "interface contract minimum" principle: implementations can "acknowledge missing capability" but cannot "break the contract."

## Counterintuitive Conclusion

> [!IMPORTANT]
> **The key to persistent containers isn't "reuse the container" — it's "separate activity signals by source layer."** SessionManager watches WebSocket (HarWork's own connection); `pauseContainerFn` watches SSH process count + code-server network connections (inside the container). Both must be zero to pause, neither alone is sufficient — **looking at only one signal means you either pause too eagerly (user SSH'd in gets frozen) or never pause (container has activity that's invisible)**.

In other words: **the pause decision can't be made on a single signal**. WebSocket closed doesn't mean the user is gone, 30 minutes idle doesn't mean the container is empty, `pgrep` showing no sshd doesn't mean nobody will ssh in next minute. HarWork's answer is **multi-signal consensus**: SessionManager is gate 1, the container's internal pgrep+ss is gate 2, both must clear to pause. The wake path is the opposite — **any single entry point** (WebSocket / SSH / preview / cron / API) can trigger unpause. **Tighten the pause decision, broaden the wake doors** — this "strict in, loose out" is the key balance of persistent container systems.

Most counterintuitive: **pause uses less memory than stop**. Intuition says stop releases process memory, so it should be cheaper than pause (where processes stay frozen in memory). But after pause, the kernel can swap cold pages to disk and keep hot ones resident. After stop, everything is released, and wake-up has to re-read binaries from disk, fork everything fresh, re-warm JIT — **stop saves memory at the cost of CPU and latency, pause keeps warm state at the cost of slight memory inertia**. Agent systems are CPU/IO-bound. Stop is the wrong optimization.

## Three Production Pitfalls

> [!WARNING]
> **Pitfall 1 — Assuming a TCP connection during pause will auto-unpause the container.**
>
> Wrong. `docker pause` freezes the cgroup — **not a single line of code in the container will execute**. TCP connections come in, even SYN-ACK can't be sent — the client errors out after TCP retries time out. HarWork explicitly hooks unpause into every entry point's "receive side": before WebSocket handshake, before preview proxy forwards, before SSH accepts — all call `ensureContainerRunning` first. **The container must wake to serve; client retries cannot wake it.**

> [!WARNING]
> **Pitfall 2 — Tuning sweep interval and idle threshold the wrong direction.**
>
> "30 minutes is too long, let's drop to 5 minutes, save more memory" — but a 60-second sweep + 5-minute threshold means **users come back from refilling their coffee and find the container just paused**, the next message waits for unpause. **The idle threshold should be much greater than typical user-away durations** (lunch 30–60min, meetings 30–90min) — that's the balance point between UX and resource use. Don't blindly shrink it.

> [!WARNING]
> **Pitfall 3 — Synchronously awaiting `seedSkillsToContainer` during first provision.**
>
> Tens of skills, each writing a file — seeding can take 2–5 seconds. If you await it before returning containerId, first-time users wait docker create + seed = 15+ seconds. HarWork chose **async seed, don't await** (`resolve.ts:36`: `seedSkillsToContainer(containerId).catch(() => {})`) — the user gets the container, skills flow in afterwards. The cost: skill list might be empty for the first second. Most users don't need skills immediately. **Async init vs. sync prep is a tradeoff — pick based on "user-expected P95 wait time."**

## Figures

1. ![Container lifecycle 5 states](../assets/img/11-container-lifecycle.svg)
2. ![Idle sweep timeline with multi-signal gate](../assets/img/11-idle-sweep-timeline.svg)
3. ![pause vs stop memory/latency comparison](../assets/img/11-pause-vs-stop.svg)

## Next Article

→ Part 12: WebSocket 30-second grace — switching wifi doesn't interrupt the agent

We've covered how the container side decides who's active. Next, we'll switch to the **connection side**: why a WebSocket disconnect doesn't immediately abort the agent. How the 30-second grace timer + EventBuffer(500) work together so that switching wifi, closing the laptop, or pressing Cmd-R doesn't interrupt a long-running agent. This is where Part 10's in-memory fields and this post's idle sweep actually meet at runtime.

---

📌 Reading map: [reading-map.md](../reading-map.md)
🔗 中文版本: [zh/11-persistent-docker.md](../zh/11-persistent-docker.md)
