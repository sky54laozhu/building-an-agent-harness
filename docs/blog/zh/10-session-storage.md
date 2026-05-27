---
title: "第 10 篇：Session 持久化 —— Conversation / Message / Memory 都存在哪"
slug: 10-session-storage
date: 2026-07-07
series: harwork-agent-harness
series_index: 10
keywords: [session persistence, Drizzle ORM, SQLite, libsql, agent state, conversation storage, message JSON, idempotent migration, storage abstraction, agent harness]
prev: 09-hooks-lifecycle
next: 11-persistent-docker
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/10-session-storage.md
---

# 第 10 篇：Session 持久化 —— Conversation / Message / Memory 都存在哪

> 第 09 篇讲完 hook 怎么塞用户代码，跨 session 的话题就摆在眼前：用户关掉浏览器、容器 pause、Engine 重启，**下次回来对话还能继续吗？** 这一篇拆 HarWork 的 30 张表 SQLite + Drizzle ORM 持久化层（**`schema.ts` 383 行 + `adapter.ts` 271 行 + `migrate.ts` 550 行**）。比"用 SQLite 存对话"更值钱的发现是：**session 运行时状态——AbortController / pending permission resolvers / event buffer / permissionMode——HarWork 故意不持久化**。Engine 进程重启 = 在飞的请求全部 deny，但 conversation 历史完整。这是"进程生命周期"和"用户可见状态"之间的一道刻意分隔。

## 问题陈述

让 agent 能"记住"上次的对话听起来直接，做起来要解决至少 5 个问题：

1. **存什么？** —— ContentBlock[] 是嵌套结构（text / tool_use / tool_result / thinking），messages 是树状（parentUuid 指向父消息），怎么存进关系型数据库？
2. **数据库选哪个？** —— 自建 PG 太重（运维成本高），Redis 不持久（断电丢数据），SQLite 单机够但能横向扩展吗？
3. **schema 怎么改？** —— 上线后加新字段，老数据怎么迁移？跑不跑 down migration？crash 中途的库怎么恢复？
4. **session 运行时状态存吗？** —— AbortController、pending Promise resolver、in-memory Map 这些跨进程根本没法序列化，硬存只能存死状态。
5. **Engine 和数据库怎么解耦？** —— Engine 跑在容器里，数据库可能是 SQLite / libsql / Turso / PG，Engine 怎么不依赖具体后端？

5 个都要解。HarWork 的全部答案落在 **`packages/web/lib/db/`（1401 行 TypeScript / 8 个文件，30 张表）** + **`packages/engine/src/storage/`（384 行 / 2 个文件，存储抽象层）**，核心是：**Drizzle ORM + libsql + SQLite 后端 + Engine StorageProvider 接口抽象 + content 字段存 JSON 字符串 + 30s 宽限 + AbortController/pending 完全不持久化**。

## 朴素方案为什么不行

**朴素 1：ContentBlock 拆多张表。** text 一张表、tool_use 一张表、tool_result 一张表——LLM message 包含 N 个 block 就要 N 次 INSERT，读消息要 N 次 JOIN。**关系型范式套上嵌套结构，复杂度直接爆炸。**

**朴素 2：用 better-sqlite3 同步 API。** 单进程同步读写很快，但 Engine 用 async generator 跑 agent loop（[第 03 篇](03-agent-loop-async-generator.md)），同步阻塞 I/O 会把整个 yield 链卡住。**Node 异步生态里同步 I/O 是反模式。**

**朴素 3：每次启动跑 `drizzle-kit migrate`。** drizzle-kit 是 CLI 工具，不适合 production runtime。上线时跑 `npx drizzle-kit migrate` → 容器层加一步、CI 又加一步、回滚没标准动作。**migration 应该是代码一部分，而不是部署一部分。**

**朴素 4：把 AbortController 序列化进 Redis。** AbortController 是 native 对象，根本不能 `JSON.stringify`。退一步用 sessionId → cancellation_requested boolean，但 in-flight 的 fetch / exec 怎么取消？**跨进程取消 = 重新设计协议。**

**朴素 5：Engine 直接 import Drizzle。** Engine 包变成绑定 SQLite/libsql 的胖包，想换 PG 就要重写 Engine。**抽象漏了 = 后端绑定 = 切不动。**

HarWork 的答案：**StorageProvider 接口（Engine 侧）+ DrizzleDbAdapter 实现（Web 侧）+ ContentBlock 整体 JSON.stringify 进 messages.content + libsql async client + 版本化 idempotent migration + session 运行时状态完全内存态 + 30s grace period 兜底重连**。

## 核心方案：两层存储抽象 + 30 张表 + 内存态 session

### 30 张 SQLite 表的责任分工（`schema.ts`）

主 schema 22 张表 + 4 个 design 模块共 8 张表 = 30 张表，按用途分 5 组：

| 组 | 表 | 干什么 |
|---|---|---|
| **核心对话** | conversations, messages, memories | 用户的对话历史、消息树、长期记忆 |
| **身份认证** | users, auth_tokens, setup_tokens, jwt_blacklist, ssh_keys | 用户、token、JWT 黑名单、SSH 公钥 |
| **配置策略** | settings, secrets, notification_config, quotas, rate_limits, platform_settings | 用户偏好、加密 secret、配额限速 |
| **扩展机制** | skills, hooks, triggers, trigger_executions | Skill 市场、hook 配置、触发器 |
| **审计计费** | audit_log, usage_events, exposed_ports, integration_settings | 操作审计、用量、端口、第三方集成 |
| **Design 模块** | designProjects, designVersions, designAnnotations, designSystems, designHandoffs, designPages, designShares, designVariants | UI 设计协作模块独立 8 张表 |

`conversations` 表是核心（`schema.ts:21-42`），列含 `id` (nanoid) / `userId` (FK→users) / `model` / `projectPath` / `source` ('cli'\|'web'\|'trigger') / `status` ('active'\|'archived' —— **soft delete**) / `totalTokens` / `totalCostUsd` / `checkpointSha`。`messages` 表（`schema.ts:59-77`）的关键是 **content 字段存 JSON 字符串**：

```typescript
content: text('content').notNull(), // JSON string: ContentBlock[]
isMeta: integer('is_meta', { mode: 'boolean' }).notNull().default(false),
isCompactSummary: integer('is_compact_summary', { mode: 'boolean' })
  .notNull()
  .default(false),
```

`parentUuid` 列做消息树（reply chain），`isCompactSummary` 标记 compact 产物（[第 04 篇](04-context-compaction-5-tiers.md)的产物落库），`isMeta` 标记系统注入消息（不喂给 LLM 但展示给用户）。

### 两层存储抽象（`engine/src/storage/types.ts` + `web/lib/db/adapter.ts`）

Engine 不知道 SQLite、不知道 Drizzle、不知道 libsql。Engine 只定义两个接口：

```typescript
// engine/src/storage/types.ts:30-63
export interface StorageProvider {
  saveMessage(conversationId: string, msg: Message): Promise<void>
  getMessages(conversationId: string): Promise<Message[]>
  createConversation(params: CreateConversationParams): Promise<string>
  updateConversationTitle(conversationId: string, title: string): Promise<void>
  updateConversationUsage(conversationId: string, tokens: number, costUsd: number): Promise<void>
  saveMemories?(userId: string, conversationId: string, entries: MemoryEntry[]): Promise<void>
  getMemories?(userId: string): Promise<MemoryEntry[]>
  // ... 12 个方法
}
```

```typescript
// engine/src/storage/db.ts:7-161
export interface DbAdapter {
  insertMessage(row: { ... }): void | Promise<void>
  getMessagesByConversation(conversationId: string): Array<{ ... }> | Promise<...>
  // ... 16 个低层 SQL 操作
}
```

**StorageProvider 是业务层接口**（"存一条消息"），**DbAdapter 是数据层接口**（"INSERT INTO messages..."）。Engine 内置 `DbStorageProvider` 类实现 StorageProvider，转发到 DbAdapter（`db.ts:163-321`）。Web 侧实现 DbAdapter：

```typescript
// web/lib/db/adapter.ts:11
export class DrizzleDbAdapter implements DbAdapter {
  constructor(private db: DB) {}

  async insertMessage(row: { ... }): Promise<void> {
    await this.db.insert(messages).values({
      id: row.id, conversationId: row.conversationId, ...
    })
  }
  // ... 实现 16 个方法
}
```

**Engine 包不依赖 drizzle-orm、不依赖 @libsql/client**。换 PG？换 Turso？换内存 mock？只要实现 DbAdapter 就能注入。这是博客系列里第三次出现"接口抽象+具体实现分包"的模式（[第 07 篇 Tool 接口](07-tool-system.md)、[第 09 篇 Hook 协议](09-hooks-lifecycle.md)，现在 Storage）。

### Message 落库的关键一步：JSON.stringify content（`db.ts:166-191`）

```typescript
async saveMessage(conversationId: string, msg: Message): Promise<void> {
  await this.adapter.insertMessage({
    id: nanoid(),
    conversationId,
    uuid: msg.uuid,
    parentUuid: msg.parentUuid || null,
    role: msg.type,
    content: JSON.stringify(msg.content),  // ← ContentBlock[] 整体序列化
    isMeta: msg.isMeta || false,
    isCompactSummary: msg.isCompactSummary || false,
  })
}

async getMessages(conversationId: string): Promise<Message[]> {
  const rows = await this.adapter.getMessagesByConversation(conversationId)
  return rows.map((row) => ({
    type: row.role as Message['type'],
    uuid: row.uuid,
    parentUuid: row.parentUuid ?? undefined,
    timestamp: row.createdAt?.getTime() || Date.now(),
    content: JSON.parse(row.content),  // ← 取回时反序列化
    isMeta: row.isMeta,
    isCompactSummary: row.isCompactSummary,
  })) as Message[]
}
```

**ContentBlock[] 整体存 JSON 字符串**——不拆 text / tool_use / tool_result 多张表，不建关联。代价是不能 SQL 查询 ContentBlock 内部（"找所有调用过 Edit 的消息"得 LIKE '%tool_use%Edit%'），收益是：

- 写入 1 次 INSERT 而不是 N 次（一个 LLM 响应可能 5-10 个 block）
- 读取 1 次 SELECT 而不是带 JOIN
- ContentBlock 字段加新 type 不用改 schema
- 跟 LLM SDK 的 message 结构 1:1 对应，序列化反序列化无信息丢失

**这是 ORM 范式的反向选择：能用文档存的就别拆表**，OLTP-friendly 之外没意义。

### Session 运行时状态：**故意不持久化**（`session/manager.ts:13-32`）

```typescript
export class Session {
  readonly userId: string
  private connections = new Set<WebSocketLike>()
  private _abortController = new AbortController()        // ← 不能序列化
  private _isAgentRunning = false                          // ← 进程态
  private _lastActivityAt = Date.now()                     // ← 内存计时器
  private _containerId: string | null = null
  readonly sessionAllowedTools: SessionAllowEntry[] = []   // ← 内存列表
  sessionHooks: HooksConfig = {}                           // ← 内存 hook 配置
  private _pendingPermissions = new Map<...>()             // ← resolve 回调
  private _pendingUserAnswers = new Map<...>()             // ← resolve 回调
  private _permissionMode: PermissionMode = 'normal'       // ← 内存
  private _graceTimer: ReturnType<typeof setTimeout> | null = null
  private _eventBuffer = new EventBuffer(500)              // ← 仅供重连重放
  private static GRACE_PERIOD_MS = 30_000                  // ← 30 秒宽限
}
```

**这堆字段一个都没存进 DB**。Engine 进程重启会发生什么？

- ✗ 在飞的 LLM 请求（abortController.signal 是 native 对象）→ **拿不回**
- ✗ pending permission ({"yes" or "no"} 待用户点击）→ **被 abort() 触发 'deny'，拒绝当前调用**
- ✗ pending user answer（AskUserQuestion 弹窗）→ **被 abort() 触发 rejected**
- ✗ sessionHooks（用户加的临时 hook）→ **丢**
- ✗ permissionMode（用户当前 session 切的模式）→ **回到默认 'normal'**
- ✗ event buffer（缓冲事件）→ **丢，但 conversation messages 已落库**
- ✓ conversations 表 → **保留**
- ✓ messages 表 → **保留**

进程重启的代价就是"在飞的请求丢，历史完整"。**用户重新连上 WebSocket、重发最后一句话，继续对话**。这是博客系列从 [第 03 篇 Agent Loop](03-agent-loop-async-generator.md) 到 [第 09 篇 Hook](09-hooks-lifecycle.md) 一以贯之的边界：**LLM 调用是事务性的、不持久；用户文字历史是持久的**。

## 关键实现要点

5 个不容易看出来的细节：

**1. 启动 drizzle 之前同步跑 migration（`web/lib/db/index.ts:12-26`）**

```typescript
import { migrateDatabase } from './migrate'

const dbPath = process.env.DATABASE_PATH || join(process.cwd(), 'data', 'harwork.db')
mkdirSync(join(dbPath, '..'), { recursive: true })

const _migrated = migrateDatabase().catch((err) => {
  console.error('DATABASE MIGRATION FAILED:', err)
  process.exit(1)  // ← migration 失败直接退进程
})

const client = createClient({ url: `file:${dbPath}` })
export const db = drizzle(client, { schema: { ...schema, ...designSchema } })
export const migrationReady = _migrated
```

**关键设计：migration 失败 → `process.exit(1)`**。不容忍部分迁移、不让 app 在不一致 schema 上跑。同时 `migrationReady` 是 Promise，重要的 DB 访问可 await 它确保 schema 就绪。**migration 是代码一部分，不是部署一部分。**

**2. addColumnsIfMissing 的容错语义（`migrate.ts:24-35`）**

```typescript
async function addColumnsIfMissing(
  client: Client,
  columns: Array<{ table: string; column: string; type: string }>,
): Promise<void> {
  for (const { table, column, type } of columns) {
    try {
      await client.execute(`ALTER TABLE "${table}" ADD COLUMN "${column}" ${type}`)
    } catch (e: any) {
      if (!e.message?.includes('duplicate column')) throw e  // ← 重复列不算错
    }
  }
}
```

idempotent migration 的精髓在这——**只放过"该列已存在"这一种特定错误**。其他任何 SQL 错误（拼写错、FK 冲突）都正常抛。这种"窄豁免"模式比 `try { ... } catch { /* ignore */ }` 安全得多。

**3. usage_events 表的双写 + 容错（`adapter.ts:107-132`）**

```typescript
async insertUsageEventByConversation(conversationId, tokens, costUsd) {
  const row = await this.db.select({ userId, source }).from(conversations)
    .where(eq(conversations.id, conversationId)).get()
  if (!row?.userId) return

  try {
    await this.db.insert(usageEvents).values({ ... })
  } catch {
    // Backward-compatible: usage_events may not exist before migration.
  }
}
```

每次更新 conversation usage 都**同时写 usage_events 明细表**（双写："汇总 + 流水"模式）。流水表上线时间晚，老库可能没这张表——所以 catch 捕获并吞掉，**让新功能不挡老用户**。这是博客系列里第一次明示 graceful degradation 模式。

**4. 长期记忆存成 JSON（`adapter.ts:154-170`）**

```typescript
async insertMemory(row: { ... category: string; confidence: number }) {
  await this.db.insert(memories).values({
    id: row.id,
    userId: row.userId,
    conversationId: row.conversationId,
    content: JSON.stringify({       // ← 又一次：业务字段揉进 JSON
      key: row.key,
      value: row.value,
      category: row.category,
      confidence: row.confidence,
    }),
    source: 'auto',
  })
}
```

memories 表（`schema.ts:196-209`）schema 只有 `content` / `source` / `userId` / `conversationId` 四列业务字段。`key` / `value` / `category` / `confidence` 全塞进 content 的 JSON。**为什么不拆 4 列？** 因为长期记忆的格式还在演化（[第 06 篇](06-long-term-memory.md) 讲到 fact/preference/context/correction 分类正在调整），用 JSON 留弹性。**未稳定的领域字段先 JSON，稳定后再分列**——schema 演化的常见技巧。

**5. 30 秒 grace period 不是断开就 abort（`session/manager.ts:82-93`）**

```typescript
removeConnection(ws: WebSocketLike): void {
  this.connections.delete(ws)
  if (this.connections.size === 0 && this._isAgentRunning) {
    this._graceTimer = setTimeout(() => {
      this._graceTimer = null
      if (this.connections.size === 0 && this._isAgentRunning) {
        this.abort()  // ← 30s 后还没人回来才 abort
      }
    }, Session.GRACE_PERIOD_MS)  // 30_000
  }
}
```

WebSocket 断开**不立刻**取消 agent loop。30s 内重连 → `addConnection()` 里清掉 timer → agent 继续跑。**用户切个 wifi、合上电脑 30s 内重开、Cmd-R 刷新都不打断**。配合 EventBuffer(500) 缓存事件，重连后能重放过去 500 条事件让 UI 状态对齐。这是博客 [第 12 篇](12-websocket-30s-grace) 的伏笔，但宽限期的实现就在 session/manager.ts 里。

## 反直觉结论

> **Session 持久化的正确边界不是"什么都存"，而是"区分进程态和用户态"**。AbortController / pending Promise resolver / event buffer / permissionMode —— 这些是进程态，**故意不持久**，进程重启即丢。conversation / message / memory / hook config —— 这些是用户态，**必须持久**。两条边界一旦划清，整个持久化层的复杂度立刻塌下来：进程重启的逻辑只剩"接受当前请求丢、用户重发"，根本不需要写 Redis、不需要分布式状态、不需要 saga / outbox / event sourcing。

换句话说：**进程态硬持久 = 灾难**。你序列化了 AbortController，下次启动反序列化拿到一个无用的 native handle；你存了 pending Promise，进程换一个之后 resolve 在哪？你存了 EventBuffer，重启完真的还要重放？**所有"看起来该存"的运行时状态，仔细想都是状态污染源**。HarWork 反向操作——**该不持久的就坦然不持久**——结果是 storage 层薄得反常，但生产稳得反常。

最反直觉：**ContentBlock[] 整体存 JSON 字符串**。学院派 ORM 范式逼你拆 N 张表，HarWork 反向操作——**能 JSON 序列化的就 JSON**。代价是不能 SQL 查 block 内部，但 agent 系统**根本不需要查 block 内部**（消息检索按 conversation/user 就够）。**用 ORM 跟 LLM 协议结构对齐，不要逼 LLM 协议适配 ORM 范式。**

## 三个生产坑

**坑 1：用 better-sqlite3 同步 API 跑 Engine。** 同步 API 单元测试很快、benchmark 很好看，但 Engine 用 async generator 流式吐事件（[第 03 篇](03-agent-loop-async-generator.md)）。同步 I/O 阻塞 event loop → 流式事件全部堵在队列里，用户看到 UI 卡死。HarWork 选 `@libsql/client` 异步 driver（`web/lib/db/index.ts:22`）+ drizzle-orm 异步 API，**所有 DB 操作都是 await**。

**坑 2：把所有 audit / usage / message 写库都同步等返回。** Agent 跑一次几十条事件，每条 INSERT 都 await 等返回 = 用户看 LLM 流式吐字延迟肉眼可见。HarWork 的 messages 是流式写的（每条收到就 saveMessage），但 audit_log 走批量异步通道。更激进的做法：把 audit_log 通过 `setImmediate` 推到下一 tick，不阻塞主路径。

**坑 3：drizzle-kit migrate 跑在部署阶段。** "部署时跑 migration"是 12factor 教科书做法，但容器化场景下 **runtime 跑 migration 才能保证镜像随处可启**。HarWork 选 runtime migration（`web/lib/db/index.ts:17` 在 db client 创建前 await）+ 版本化追踪表（migrate.ts:38 的 MIGRATIONS 数组），失败直接 exit(1)。**镜像 + DB path 给你 → 启动就能用，不需要额外步骤。**

## 配图

1. ![两层存储抽象 + StorageProvider 接口边界](../assets/img/10-storage-abstraction.svg)
2. ![30 张表分组 + 5 个责任域](../assets/img/10-schema-30tables.svg)
3. ![持久态 vs 内存态 —— 进程重启幸存清单](../assets/img/10-persisted-vs-runtime.svg)

## 下一篇

→ 第 11 篇：Per-User 持久 Docker —— pause/unpause 节省冷启动 13 秒

Session 数据存哪解决了，下一篇切到容器侧：每个用户绑定一个持久 Docker 容器（不是每次请求开新容器），空闲时 `docker pause` 冻 CPU、保留内存映射，30 分钟空闲触发自动 pause；用户回来 `docker unpause` 瞬间唤醒，**冷启动 13.7s → 热唤醒 0.2s**。覆盖容器生命周期表、SessionManager 的 idle sweep 调度、为什么 pause 而不是 stop。

---

📌 系列阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/10-session-storage.md](../en/10-session-storage.md)
