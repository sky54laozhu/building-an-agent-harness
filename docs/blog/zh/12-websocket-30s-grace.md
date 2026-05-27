---
title: "第 12 篇：WebSocket 30 秒宽限期 —— 切 wifi 不打断 agent"
slug: 12-websocket-30s-grace
date: 2026-07-21
series: harwork-agent-harness
series_index: 12
keywords: [websocket reconnect, grace period, event buffer, ring buffer, exponential backoff, replay protocol, agent harness, abort controller, network resilience, real-time]
prev: 11-persistent-docker
next: 13-multi-model-routing
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/12-websocket-30s-grace.md
---

# 第 12 篇：WebSocket 30 秒宽限期 —— 切 wifi 不打断 agent

> 第 10 篇说"对话历史落 SQLite"，第 11 篇说"30 分钟空闲 pause 容器"。本篇切到中间那一层——**前后端之间的 WebSocket 连接**。Agent 在跑、用户合上电脑/切 wifi/Cmd-R 刷新，连接断了，**agent loop 要立刻 abort 吗？** HarWork 的答案是：**等 30 秒**。30 秒内重连回来无缝衔接、超过 30 秒确实是走了再 abort。这一篇拆 `session/manager.ts` 的 grace timer + EventBuffer(500) + 前端指数退避重连 + 服务端 ping/pong heartbeat 四件套，重点是**为什么"延迟 abort"比"立即 abort"或"永不 abort"都好**。

## 问题陈述

WebSocket 连接和 agent 的关系很微妙：

1. **agent 跑的时候连接断了怎么办？** —— 立刻 abort 吗？用户切个 wifi 就丢失 30 秒进度？永不 abort？用户关浏览器走了 agent 还在烧钱？
2. **重连回来怎么把"漏掉的事件"补上？** —— Agent 这 5 秒里跑了 20 条 stream event，重连后浏览器看到的是已经跑完一半的输出，怎么把缺的那段填回来？
3. **怎么区分"真断"和"假断"？** —— TCP 连接看起来还在但实际死了（NAT 超时、wifi 切换、手机锁屏），需要主动 heartbeat 探活。
4. **服务端的事件 buffer 多大才合理？** —— 太小补不全，太大占内存（N 个用户 × M 个 event × 每个 event ~1KB）。
5. **断线期间用户操作怎么办？** —— 用户在切 wifi 的瞬间发了一条消息，是丢掉还是排队等重连？

5 个问题加起来就是 HarWork 解决的核心问题：**网络不可靠时，怎么让 agent 体验感觉是可靠的**。答案落在 `packages/engine/src/session/manager.ts` 的 grace timer + EventBuffer + `packages/web/hooks/use-websocket.ts` 的指数退避，核心是：**30 秒延迟 abort + 500 条事件 ring buffer + 重连时 lastEventId 协议 replay + 客户端 25s/服务端 30s 双心跳 + 断线期间消息 pendingQueue**。

## 朴素方案为什么不行

**朴素 1：连接断了立刻 abort agent。** 简单粗暴。但用户的网络体验是脆弱的：地铁切换 4G/5G 短暂断开、wifi 路由器丢包、笔记本休眠 5 秒。每一次都把 agent 杀掉=每一次都让用户从头开始。**LLM 调用一次 10 秒，agent 跑一轮 30 秒，用户禁不起这种打断。**

**朴素 2：连接断了不管，让 agent 跑完。** 资源浪费——用户关浏览器走了你还在跑 LLM 调用、扣 token、占容器内存。**Agent 系统的成本结构里，"没人看的输出"是纯成本不是产出。**

**朴素 3：把所有 stream event 都缓存起来等重连。** 内存爆炸。一次长跑 agent 输出几百条 event、每个 1-5KB，乘以 1000 在线用户 = GB 级 RAM 等着重连。**事件流不能无限缓存。**

**朴素 4：重连后让前端从对话最初开始 replay。** 前端要重新解析几十条 stream event、重新渲染所有 tool call。**用户看的是一闪一闪的"重放动画"——不是"无缝衔接"。**

**朴素 5：只信 TCP 连接状态。** TCP 的"连接还在"和"对端进程还活着"是两件事——NAT 超时不会通知、wifi 切换 client 不感知、笔记本休眠 socket 看起来正常但 OS 早冻住了。**Heartbeat 是网络层之上的应用层探活，缺它必死。**

HarWork 的答案：**用户操作即触发**——连接断开 → grace timer 30 秒倒计时 → 30 秒内重连？取消 timer，replay 缺的 event → 30 秒过完？真 abort agent。事件用 EventBuffer ring buffer (500 条) 缓存，按 eventId 单调递增，重连时 client 发自己的 lastEventId、server 把后面的全推过来。

## 核心方案：30s grace timer + EventBuffer(500) + 双向 heartbeat

### Grace timer 状态机（`session/manager.ts:74-93`）

```typescript
addConnection(ws: WebSocketLike): void {
  this.connections.add(ws)
  if (this._graceTimer) {              // ← 重连回来：取消 grace
    clearTimeout(this._graceTimer)
    this._graceTimer = null
  }
}

removeConnection(ws: WebSocketLike): void {
  this.connections.delete(ws)
  // 关键 guard：只在 "全部连接断 + agent 正在跑" 才进入 grace
  if (this.connections.size === 0 && this._isAgentRunning) {
    this._graceTimer = setTimeout(() => {
      this._graceTimer = null
      // 30 秒后双检——可能用户又重连上了
      if (this.connections.size === 0 && this._isAgentRunning) {
        this.abort()
      }
    }, Session.GRACE_PERIOD_MS)         // ← 30_000ms
  }
}
```

**核心是三件事**：
1. **只有 agent 在跑才启动 grace**——agent 没跑的话连接断了直接什么都不用做，没什么要保护的
2. **重连即取消**——`addConnection` 第一件事就是 clearTimeout，所以重连越快越好（前端用指数退避 1s 起步）
3. **setTimeout 回调里再 check 一次**——30 秒过了但用户又重连上了的情况要排除（race condition）

### EventBuffer：500 条 ring buffer（`session/event-buffer.ts:3-32`）

```typescript
export class EventBuffer {
  private buffer: StreamEvent[] = []
  private _nextId = 1
  private capacity: number

  constructor(capacity = 500) { this.capacity = capacity }

  push(event: StreamEvent): StreamEvent {
    const stamped = { ...event, eventId: this._nextId++ }
    this.buffer.push(stamped)
    if (this.buffer.length > this.capacity) {
      this.buffer.shift()                    // ← FIFO 丢老的
    }
    return stamped
  }

  getAfter(eventId: number): StreamEvent[] {
    return this.buffer.filter((e) => (e.eventId ?? 0) > eventId)
  }
}
```

**3 个关键细节**：
- **eventId 单调递增、从 1 开始**——`_nextId++` 永不回退，断线重连按这个 ID 索引
- **500 条容量是 ring buffer**——超过就 `shift()` 弹掉最老的，**长跑 agent 出事件超过 500 条的 case，前面那段补不回来**（参见后面"生产坑 3"）
- **getAfter 是 filter 而不是 slice**——线性查找，O(n) 不是 O(1)。500 条规模下没问题，但如果有人改大到 5000+ 要重写。

### Broadcast：buffer 和广播是同一个动作（`session/manager.ts:95-101`）

```typescript
broadcast(event: StreamEvent): void {
  const stamped = this._eventBuffer.push(event)  // ← 入 buffer 拿到 eventId
  const data = JSON.stringify(stamped)
  for (const ws of this.connections) {           // ← 推给所有当前连接
    ws.send(data)
  }
}
```

**入 buffer 和分发不是两步——是同一个原子动作**。这意味着 buffer 里存的就是"已经发出去过"的事件序列，重连后重发的内容和 client 之前收到的一模一样（除了重复部分，client 按自己的 lastEventId 自动去重）。

### 重连协议：lastEventId 双向声明（`ws-message-handlers.ts:319-330`）

```typescript
function handleReconnect(msg: any, ctx: MessageHandlerContext): void {
  const lastEventId = Number(msg.lastEventId) || 0
  const missed = ctx.session.getEventsSince(lastEventId)
  for (const event of missed) {
    ctx.ws.send(JSON.stringify(event))           // ← 把缺的全推过去
  }
  ctx.ws.send(JSON.stringify({
    type: 'state_restore',
    isAgentRunning: ctx.session.isAgentRunning,
    lastEventId: ctx.session.lastEventId,
  }))
}
```

**协议是这样的**：
1. Client 重连成功后第一条消息就是 `{type:'reconnect', lastEventId:<自己最后收到的>}`
2. Server 查 EventBuffer 把 `> lastEventId` 的全推过去
3. 推完发一个 `state_restore` 帧告诉 client "agent 还在跑吗 / 当前最新 eventId 是多少"——前端用这个状态更新 UI（继续显示 streaming 还是 idle）

### 前端：指数退避 + 25s 心跳（`web/hooks/use-websocket.ts:12, 86-92, 132-146`）

```typescript
const RECONNECT_DELAYS = [1000, 2000, 4000, 8000, 16000]
const MAX_RECONNECT_ATTEMPTS = 10

// onopen 后：
const keepalive = setInterval(() => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'ping' }))    // ← 25 秒一次客户端主动 ping
  }
}, 25_000)

// scheduleReconnect:
const delay = RECONNECT_DELAYS[Math.min(attempt, RECONNECT_DELAYS.length - 1)]
```

**两个看似无关的数字背后是同一个道理**：服务端心跳是 30 秒（`ws-server.ts:184`），客户端 ping 25 秒——**客户端的 ping 总是早于服务端发现"对端没回应"**。这意味着即使 client 网络半挂、服务端 ping 在路上丢了，client 自己主动发的 ping 会顺便保活 TCP，**双方都尽量不要先把对方判死**。

```typescript
ws.onopen = () => {
  // ...
  if (lastEventIdRef.current > 0) {              // ← 之前断过、有 lastEventId
    ws.send(JSON.stringify({ type: 'reconnect', lastEventId: lastEventIdRef.current }))
  }
}
```

**只有 `lastEventIdRef > 0` 时才发 reconnect**——首次连接不需要这步。重连协议是叠加在普通连接之上的"如果你曾经在这里"。

### 服务端心跳 + 强制 terminate（`ws-server.ts:182-194`）

```typescript
let alive = true
const heartbeat = setInterval(() => {
  if (!alive) {
    clearInterval(heartbeat)
    ws.terminate()                                // ← 强杀 socket
    return
  }
  alive = false
  ws.ping()
}, 30_000)
ws.on('pong', () => { alive = true })
```

**典型的双重 flag 心跳模式**：每 30 秒 ping 一次、标记 alive=false、等 pong 回来才设 alive=true。下一轮 30 秒到了 alive 还是 false？socket 已经死了，`terminate` 直接掐——**不要等 OS 的 TCP keepalive 超时（默认 2 小时 11 分钟），那个等不起**。

## 关键实现要点

5 个不容易看出来的细节：

**1. grace timer 不会被普通断线触发——只有"agent 在跑"才会（`manager.ts:85`）**

```typescript
if (this.connections.size === 0 && this._isAgentRunning) {
```

用户关浏览器但 agent 不在跑？什么都不做——session 留着等下次回来、容器还在、buffer 还在、idle sweep 30 分钟后再 pause 容器。**Grace timer 是为"打断 agent"准备的，不是为"清理 session"**。这两个 lifecycle 在 HarWork 里是分离的。

**2. abort() 是真的杀，但 AbortController 会新建（`manager.ts:110-117`）**

```typescript
abort(): void {
  if (this._graceTimer) { clearTimeout(this._graceTimer); this._graceTimer = null }
  this._abortController.abort()                  // ← signal 发出去
  this._isAgentRunning = false
  this._abortController = new AbortController()  // ← 立刻换新的
  // ...
}
```

**Abort 后立刻 `new AbortController()`**——下次 chat 才有干净的 signal 用。如果不换新的，第二次 chat 拿到的 signal 还是 aborted 状态，agent 一启动就立刻退出。这种"用完即换"是 AbortController 的标准用法但容易漏。

**3. 待处理 permission 也会一起 reject（`manager.ts:118-127`）**

```typescript
for (const [, resolve] of this._pendingPermissions) {
  resolve('deny')                                // ← 等用户点 Allow 的 promise 全部 deny
}
this._pendingPermissions.clear()
for (const [, resolve] of this._pendingUserAnswers) {
  resolve({ rejected: true, feedback: 'Aborted' })
}
```

Agent 跑到"问用户要授权"那一步停下来等 [第 08 篇](08-permissions-sandbox.md) 的 permission UI——这时连接断了 grace 过完 abort 触发，等待的 promise 不能就这么悬着，全部 resolve 成 'deny'，让 agent 走"拒绝"分支正常退出。**Abort 不只是发 signal，还要清理所有"等用户"的状态**。

**4. 客户端 pendingQueue 缓存断线期间的 send（`use-websocket.ts:75-78, 157-163`）**

```typescript
const send = useCallback((msg: WsMessage) => {
  if (wsRef.current?.readyState === WebSocket.OPEN) {
    wsRef.current.send(JSON.stringify(msg))
  } else {
    pendingQueueRef.current.push(msg)            // ← 断了就排队
  }
}, [])

// onopen 后：
for (const queued of pendingQueueRef.current) {
  ws.send(JSON.stringify(queued))                // ← 全部 flush
}
```

用户在切 wifi 的瞬间敲了一条消息？React 已经把 send 调下来了但 WebSocket 还没重连——**进 pendingQueue 等重连**。重连成功后 `onopen` 先 flush 队列、再发 reconnect。**这保证"用户感觉"的连续性不被网络波动打破**。

**5. clearEventBuffer 跟 idle sweep 联动（`manager.ts:253`）**

```typescript
// 在 idle sweep 内：
session.clearEventBuffer()                        // ← pause 容器的同时清 buffer
```

第 11 篇的 idle sweep 触发 pause 容器时，顺手把 buffer 清掉。**为什么？** 因为 30 分钟没人连意味着用户不会再回来看"30 分钟前流过的事件"——留着只是浪费 500 个 slot。重新连上是一个新对话的开始，buffer 从 0 起步。

## 反直觉结论

> **"30 秒"既不是"够用了"也不是"业界惯例"——它是"对人友好的窗口" × "对成本残忍的边界"的交点**。比 30 秒短：用户 wifi 抖一下就触发 abort，体验破碎；比 30 秒长：用户走了半分钟你还在烧 LLM token，成本不可控。30 秒的本质是承认"用户的网络小波动"和"用户真走了"之间没有清晰边界，**用一个固定窗口把模糊地带覆盖掉**。

更反直觉的是：**这个 30 秒的窗口本身和"agent 在跑"绑定**。Agent 没跑你直接关浏览器我什么都不做（grace 不启动），等到 30 分钟后 idle sweep 把容器 pause 了——这是分钟级别。Agent 在跑你关浏览器，我等 30 秒确认你不回来再 abort——这是秒级别。**两个 lifecycle 用两套时间尺度因为它们保护的成本完全不同**：容器内存是连续小账单（可以 30 分钟决策一次），LLM token 是大颗粒尖刺账单（必须秒级响应）。把"什么时候 abort agent"和"什么时候 pause 容器"放在同一个时间尺度上，要么用户体验差（30 分钟还在跑 agent），要么内存浪费（30 秒还不 pause 容器）。

最反直觉的工程细节：**EventBuffer 是 ring buffer 而不是 unbounded list**。直觉是"为了 replay 完整性应该全存"——但 HarWork 接受"超过 500 条就丢老的"这个事实，**因为长跑超过 500 条事件的 agent 大概率已经不需要 replay**。用户切个 wifi 你需要补的是最近几秒、最多十几条 event；用户半小时后才回来你也不该 replay 30 分钟的输出，那应该是从 SQLite 里读对话历史而不是 buffer。**Ring buffer 的设计哲学是"只服务断线场景，不服务时间穿越"**。

## 三个生产坑

**坑 1：以为前端 `lastEventId` 准确反映 client 看到的状态。** `use-websocket.ts:115` 在 `onmessage` 里更新 `lastEventIdRef`——但 React state 还没更新、UI 还没渲染。**如果 client 中间崩了**（onmessage 走完但 React 渲染前 OOM），lastEventId 已经更新但用户看到的 UI 是旧的，重连时 client 说"我看到了 X"server 信以为真不再发 X——**用户其实没看到**。HarWork 的折中：先信 lastEventId、显示有冲突时手动 refresh 拉 conversation history（第 10 篇路径）。完美的方案是双方各报 lastEventId 取小，但实现复杂收益小。

**坑 2：MAX_RECONNECT_ATTEMPTS=10、最大 delay 16s。** 算一下：1+2+4+8+16+16+16+16+16+16 = 111 秒，约 2 分钟后就放弃了。**用户合上电脑 5 分钟回来发现页面显示 "Connection lost"——需要手动刷新**。这是有意的：超过 2 分钟基本是"用户走了"，自动重连有反向作用（手机弹窗每秒重试）。但是要在 UI 上明确提示"请刷新"，HarWork `use-chat.ts:313` 那条 'Connection lost, reconnecting...' 文案要在 attempt 满了之后换成 'Please refresh'。

**坑 3：长跑 agent 出 event 超过 500 条用户重连后丢失开头。** EventBuffer 是 ring buffer——agent 输出 600 条 event 用户 500 条之后才重连，前 100 条已经被 `shift()` 掉了。**重连后 client 看到的是"从中间开始"的 agent 输出**，没有 thinking、tool 调用都从一半开始。HarWork 的态度是这种情况下 client 应该直接 reload 对话从 SQLite 拉完整历史，而不是依赖 EventBuffer 补全——**Buffer 的承诺是"30 秒内的事件"，不是"全部事件"**。如果 agent 30 秒内能输出 500+ event 是 agent 太啰嗦的问题，不是 buffer 太小的问题。

## 配图

1. ![Grace timer 状态机](../assets/img/12-grace-state-machine.svg)
2. ![EventBuffer ring buffer + lastEventId 协议](../assets/img/12-event-buffer-ring.svg)
3. ![断线重连完整时间线](../assets/img/12-reconnect-timeline.svg)

## 下一篇

→ 第 13 篇：多模型路由 —— Claude / DeepSeek / Qwen / OpenAI 混用

WebSocket 连接侧讲完了，下一篇切回 agent 内部：HarWork 怎么让一个对话里既能用 Claude 跑 thinking、又能用 DeepSeek 跑代码、还能切到 Qwen 跑中文 reasoning？ModelRegistry 怎么注册、不同 provider 的 stream 协议怎么统一、token 计费怎么按模型分别记？这是连接层之上的"模型抽象层"。

---

📌 系列阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/12-websocket-30s-grace.md](../en/12-websocket-30s-grace.md)
