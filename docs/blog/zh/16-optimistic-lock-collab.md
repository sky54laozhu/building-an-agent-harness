---
title: "Part 16：乐观锁实时协作 —— 为什么 AI 产物多人协作不该用 CRDT"
slug: 16-optimistic-lock-collab
date: 2026-08-18
series: harwork-agent-harness
series_index: 16
keywords: [optimistic locking, AI artifact collaboration, CRDT, Yjs, websocket, real-time collaboration, conflict resolution, agent harness, harwork, design collaboration, share token, version control]
prev: 15-design-variants-mix
next: 17-enterprise-cicd
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/16-optimistic-lock-collab.md
---

# Part 16：乐观锁实时协作 —— 为什么 AI 产物多人协作不该用 CRDT

> AI 产物（设计稿、PRD、HTML）越好用，多人并发编辑的需求越高。Google Docs 用 OT、Figma 用 CRDT、Notion 用 OT —— 这些都是**普通文档**的协作模型。但 AI 产物的每次编辑都携带**语义决策**（"这个按钮改红是因为品牌主色"），自动合并 = 把语义判断交给 diff 算法，灾难。HarWork 选了相反的路：**乐观锁 + 显式冲突 + 不自动合并**。这一篇拆 4 个东西：5 种朴素方案为什么都不行、HarWork 的乐观锁为什么在**内存**里不在 DB 里、WebSocket `design:*` 消息协议的 5 种 type 怎么分流、以及组织级 share token 的 TTL + 软撤销 —— 共 **852 行代码**（`collab-server.ts` 183 + `version-store.ts` 89 + `ws-server.ts` 280 + `versions/route.ts` 108 + `shares/route.ts` 108 + `shares/[shareId]/route.ts` 129 + `shared/[token]/route.ts` 62 + `design-share-dialog.tsx` 138 + `share-utils.ts` 29 + `design-shares-schema.ts` 20）。

## 问题陈述

多人协作 AI 产物要回答 4 个核心问题：

1. **A 在改 hero、B 同时改 footer，提交时谁覆盖谁？** 不能 last-write-wins（丢工作），不能锁死 B 不让动（体验差）。
2. **CRDT 在普通文档里很香，为什么在 AI 产物里失效？** Yjs / Automerge 自动合并文本是按字符 diff —— 但 AI 产物的"红色按钮"和"绿色按钮"是语义对立，自动合并算法不懂。
3. **乐观锁该存在 DB 还是内存？** DB 持久但每次 update 要事务、性能差；内存快但重启清零。HarWork 选哪个？
4. **非平台用户怎么参与？** 设计稿要发链接给客户、给老板看 —— 但不能给他们开账号。怎么做"匿名查看 / 评论"又不开后门？

这 4 个问题合起来 = AI 产物多人协作的工程契约。HarWork 的答案藏在 5 个地方：`packages/engine/src/design-collab/version-store.ts`（核心乐观锁）、`packages/engine/src/design-collab/collab-server.ts`（WS 协作 server）、`packages/engine/src/ws-message-handlers.ts`（消息分流）、`packages/web/lib/db/design-shares-schema.ts`（share token 表）、`packages/web/components/design/design-share-dialog.tsx`（share UI）。

## 朴素方案为什么不行

**朴素 1：悲观锁。** A 改 hero 时全 project 加锁，B 锁死。UX 灾难——B 想改 footer 也得等。**死锁更致命**：A 改到一半网络掉线，锁释放靠 TTL，TTL 期内没人能动。**90 年代企业软件做法**。

**朴素 2：CRDT（Yjs / Automerge）。** 一定有人说"这就是为多人编辑生的"。直到看到这个场景：A 把按钮改红（品牌主色），B 同时改绿（a11y 对比度算的）—— CRDT 按字符 diff 合并可能得 `#FF8800`（插值）这种**两人都不想要**的结果。**普通文档里"两人都说 'hello' 无冲突"成立，AI 产物里"两个语义决策必须二选一"才成立**。根源：**编辑粒度是字符，但语义粒度是决策**。

**朴素 3：last-write-wins。** A 先提交 B 后提交 B 覆盖。但 AI 产物的每次编辑可能是**用户半小时讨论 + 3 轮 AI 迭代**的结果，丢一次 = 丢半小时。**生产 AI 协作平台没人选 LWW**。

**朴素 4：DB 行级乐观锁（version column + transaction）。** `design_versions` 加 `expectedVersion`，每次 update 事务 `WHERE version = ?` 匹配才 +1。3 个坑：(1) **事务开销大**——每次按钮颜色调整都写 DB 事务，10 人并发时 SQLite 锁表；(2) **延迟**——HTTP 长链路 200-500ms 才知道写失败；(3) **广播脱节**——DB 版本号变了但其它客户端不知道，要么轮询要么再上 WebSocket —— 那为什么不直接 WS 一条龙？

**朴素 5：Operational Transform（Google Docs 那套）。** 要在 server 维护"转换函数"——给定操作 A 和 B，怎么变换 A 在 B 之后应用。**AI 产物的"操作"难以形式化**（"把按钮改红"是什么 OT 操作？），变换函数无法自动推导。**OT 在 Google Docs 行得通因为操作集极小（插入/删除字符），AI 产物的操作是开放集**。

HarWork 的实际选择：**内存 VersionStore + WebSocket 协议级冲突通知 + 显式拒绝自动合并 + 组织级 share token**。下面拆。

## 核心方案：4 步管线

### 第 1 步：内存版本号 + applyEdit 的 CAS 语义（`version-store.ts:44-57`）

```typescript
applyEdit(projectId: string, editVersion: number): EditApplyResult {
  const current = this.getVersion(projectId)

  if (editVersion === current) {
    const newVersion = this.incrementVersion(projectId)
    return { accepted: true, newVersion }
  }

  return {
    accepted: false,
    currentVersion: current,
    conflict: true,
  }
}
```

**整个乐观锁的核心 14 行**。语义 = CPU 的 CAS（compare-and-swap）：客户端带 `editVersion` 过来，server 比对当前版本，相等 +1、不等告诉客户端"你看的版本过期了"。**Map<projectId, number> 而非 DB 行级锁**——`version-store.ts:21` 的 `versions` 是**纯内存**。3 个理由：(1) 协作版本号无需持久化——engine 重启时所有 WS 重连，客户端发 `design:sync`（`collab-server.ts:143-150`）重新取；(2) Map O(1) 比 SQLite 事务快 1000 倍；(3) 不和 DB 的 `design_versions.versionNumber`（快照历史）混淆——**前者"并发冲突检测"，后者"版本快照"**，两个不同概念。

### 第 2 步：5 种 WebSocket 消息分流（`ws-message-handlers.ts:123-141`）

```typescript
if (msg.type === 'design:join') {
  // 客户端进入 project，server 推送 design:sync 同步当前版本
  ctx.designCollabServer.joinProject(ctx.ws, ctx.userId, userName, projectId)
}

if (msg.type === 'design:edit') {
  // 客户端提交编辑，server 走 CAS 并广播或返回 conflict
  ctx.designCollabServer.handleEdit(msg as DesignEditMessage)
}

if (msg.type === 'design:sync') {
  // 客户端主动同步（重连后调用）
  ctx.designCollabServer.handleSync(ctx.ws, msg.projectId)
}
```

5 种消息类型（`collab-server.ts:4-41`）：客户端发 **`design:join` / `design:edit` / `design:sync`**；server 发 **`design:edit:ack` / `design:conflict` / `design:edit`（广播给其他客户端）**。**design:edit 在客户端和 server 之间含义不同**：客户端发 = "我要编辑"；server 发 = "其他人编辑了"。

**为什么不真做"独立 WebSocket 通道"**：spec 原本想给 `design-collab` 单开一条 WS endpoint，但实际工程发现同一用户开 2 条 WS 会让 session 管理混乱（Part 12 的 30s 宽限期、500 事件 ring buffer 都要复制一份）。最终选**单 WS + 消息 type 分流**：`msg.type === 'design:edit'` 走 `DesignCollabServer`，`msg.type === 'chat'` 走 Agent Loop（`ws-message-handlers.ts:143-146`）。**逻辑通道靠消息 type 区分，物理上只有一条 WS**。

### 第 3 步：冲突通知是协议级、不是产品级（`collab-server.ts:118-140`）

```typescript
} else {
  const lastEditor = this.versionStore.getLastEditorOfArea(projectId, area)
  const senderClient = this.findClient(projectId, userId)
  if (senderClient) {
    this.sendToClient(senderClient.ws, {
      type: 'design:edit:ack',
      projectId,
      newVersion: result.currentVersion!,
      accepted: false,
    })
    this.sendToClient(senderClient.ws, {
      type: 'design:conflict',
      projectId,
      editVersion,
      currentVersion: result.currentVersion!,
      conflictingUserId: lastEditor?.userId || 'unknown',
      conflictingUserName: this.findClientName(...) || 'Another user',
      area,
    })
  }
}
```

服务端做事克制：(1) 告诉客户端"提交被拒"（`design:edit:ack` `accepted: false`）；(2) 附 `design:conflict` 包含**冲突方信息**——谁、改哪个 area、当前版本号；(3) **不自动合并**。客户端怎么显示——产品决策。spec 原本规划"弹 UI 让用户选覆盖/丢弃/合并"，但**当前 codebase 冲突 UI 还没实现**——消息发出去了，前端没对应 React handler。**这是 HarWork 当前最大产品 gap，但协议设计没毛病**。

`getLastEditorOfArea`（`version-store.ts:75-83`）反查最近 50 条 edit 历史（`maxHistoryPerProject = 50` line 23）找到上一个改 area 的人。**为什么只存 50 条**：不是审计日志（那走 DB），只为告诉冲突方"谁改了你正在改的东西"——50 条够覆盖一次协作 session 活跃窗口。

### 第 4 步：组织级 share token —— TTL + 软撤销 + 路由分离（`design-shares-schema.ts` + `share-utils.ts:12-16` + `shared/[token]/route.ts:34-36`）

```typescript
// design-shares-schema.ts:12-16
permission: text('permission', { enum: ['view', 'edit'] }).notNull().default('view'),
expiresAt: integer('expires_at', { mode: 'timestamp_ms' }),
revokedAt: integer('revoked_at', { mode: 'timestamp_ms' }),

// share-utils.ts:12-16
export function isShareValid(share: ShareRecord): boolean {
  if (share.revokedAt !== null) return false
  if (share.expiresAt === null) return true
  return share.expiresAt.getTime() > Date.now()
}
```

3 个设计点：(1) **permission 是 view/edit 二选一**——不做"comment-only"中间态，AI 产物的评论走 annotation 体系（Part 14）；(2) **expiresAt 可空 = 永不过期**——1h/24h/7d/30d 是 UI 预设（`design-share-dialog.tsx:18-24`）底层支持任意时间戳；(3) **revokedAt 软撤销**——`DELETE` 不物理删（`shares/[shareId]/route.ts:121-122`），只置 `revokedAt = new Date()`，方便审计。

`isShareValid` 校验顺序关键：**先看撤销、再看过期、最后看永不过期**——撤销永远优先（不允许"过期+重新激活"）。`shared/[token]/route.ts:34` 每次访问调用，**校验失败返回 403 而非 404**——区分"token 不存在"（404）和"token 存在但失效"（403）。

## 反直觉结论

> **AI 产物多人协作不该用 CRDT**。这个结论反 10 年来的协作工具技术潮流（Figma / Linear / Notion 都在卷 CRDT 实现）。但 CRDT 的核心假设是"**编辑可以自动合并**"——这个假设在普通文档（两人同时输入"hello"无冲突）、设计稿位置（两人拖拽不同元素无冲突）里成立，但**在 AI 产物里完全失效**。AI 产物的每次编辑都是**语义决策**——"我把这个按钮改红，是因为基于品牌主色 + 用户行为数据 + 上次和 PM 讨论的结论"。把这种决策交给 diff 算法自动合并 = 让算法替人做产品判断。**HarWork 选乐观锁 + 显式冲突，是承认"AI 产物的协作单位是决策，不是字符"**。

更反直觉的：**乐观锁不在 DB 里，在内存 Map 里**。所有教科书讲乐观锁都教你"加个 version 列、走事务"——但 HarWork 的 `VersionStore.versions: Map<string, number>`（`version-store.ts:21`）就是个纯内存 Map。3 个收益：(1) 性能——SQLite 单线程事务在 10 人并发时锁表，Map O(1) 操作不会；(2) 简化——版本号不需要持久化，**engine 重启时所有 WS 连接断、重连时客户端会主动 `design:sync` 同步**（`collab-server.ts:143-150`），等于天然重置；(3) 分层——DB 的 `design_versions.versionNumber` 管"快照历史"（Part 15 拆过的线性日志），内存的 `VersionStore.versions` 管"并发冲突检测"，**两个维度的版本号绝不混用**。

最反直觉的工程细节：**冲突 UI 是协议级的，不是产品级的**。`collab-server.ts:130-138` 把 `design:conflict` 消息发出去了，附带冲突方姓名、area、currentVersion——协议完整。但**前端的 React 客户端目前没有对应的 handler 渲染对比框** —— spec 原本规划"用户选覆盖 / 丢弃 / 合并"那个 UI，**没实装**。这是个**故意的工程顺序选择**：先把协议跑通、让 server 端能正确判定冲突，等用户量起来再加 UI。**很多协作功能死在"先做漂亮 UI 后接发协议"——HarWork 反过来，先有协议、UI 留给用户量驱动**。

## 三个生产坑

**坑 1：engine 重启清空 VersionStore，所有客户端的 editVersion 全部变成"过期"**。`version-store.ts:21` 的 `Map` 在进程重启时归零——所有客户端最后一次收到的 `currentVersion` 比如是 47，重启后 server 内 `versions.get('proj-X') = 0`。客户端如果**没有先发 `design:sync`** 就直接发 `design:edit { editVersion: 47 }`，server 比对 `47 !== 0` → 全部 conflict。**生产代价**：engine 重启后第一波编辑全失败，用户看到一堆"冲突"提示但实际没人和他冲突。**修法**：(1) 客户端 WebSocket onopen 必须先发 `design:join`，server 会主动推 `design:sync`（`collab-server.ts:68-73`）让客户端校准；(2) `design:edit` 失败时客户端自动重试一次，先发 `design:sync` 再重发 edit；(3) 终极方案：把 `versions` 从内存搬到 Redis（带 TTL），engine 重启不丢但仍然不走 DB 事务。

**坑 2：share-dialog 生成的 URL 格式与服务端路由不匹配**。`design-share-dialog.tsx:56` 拼的链接是 `${origin}/design/project/${projectId}?token=${shareToken}`（query param 风格），但服务端的 share 路由是 `/api/design/shared/[token]/route.ts`（路径风格）。**当前能跑通是因为**`/design/project/[id]/page.tsx` 在客户端读 `searchParams.token` 后再去 fetch `/api/design/shared/${token}`——多一跳。**生产代价**：(1) 客户端要写额外的"读 query → 调 API"胶水代码；(2) 分享链接给非登录用户时，page.tsx 会先要求登录、再跳转 share 路由，**不是真正的"匿名访问"**。**修法**：要么把 share URL 改成 `/design/shared/${token}` 直接对齐服务端路由，要么 page.tsx 在 query 里有 token 时跳过 auth gate。

**坑 3：shared/[token] 路由用 withAuth 但缺 isOrgMember 校验**。`shared/[token]/route.ts:17` 包了 `withAuth`——意思是**share token 不是"公开链接"，使用者必须登录**。问题：`route.ts:11` 的 TODO 注释写着 "Add isOrgMember check when multi-org is implemented"——目前**任何登录用户都能用任何有效的 share token 访问其他组织的 project**。`share-utils.ts:26-29` 有 `isOrgMember` 函数，但它在 share 路由里**没被调用**。**生产代价**：组织 A 的 share token 泄漏给组织 B 的员工 → 组织 B 员工登录后能看到组织 A 的设计稿（虽然不能写，但能看是 view permission 设计的本意外延）。**修法**：`shared/[token]/route.ts` 在 line 32 后加 `if (!isOrgMember(request.user.orgId, share.orgId)) return 403`——4 行代码。

## 配图

1. ![CAS 语义乐观锁时序图](../assets/img/16-optimistic-lock-sequence.svg)
2. ![5 种 WebSocket 消息类型分流](../assets/img/16-ws-message-demux.svg)
3. ![share token 生命周期 · TTL + 软撤销](../assets/img/16-share-token-lifecycle.svg)

## 下一篇

→ Part 17：企业级 CI/CD —— canary + 多探针自动回滚

协作做好了，下一关是**一个人怎么持续维护这件事**。HarWork 是单人维护的 AI 平台，每次部署不能挂掉用户、出问题要 5 分钟回滚、不需要 24h 监控也能睡好觉——这些靠 7 件套渐进发布扛着：main/tag 自动构建、staging→production 晋升门禁、phased 组件发布、5%→25%→50%→100% 流量阶梯、多探针质量门限（含 P95 延迟）、阶梯失败指数退避回退、独立 web/engine 发布通道。下一篇拆这 7 件 GitHub Actions 配置的工程化细节，以及"为什么大厂 CI/CD 模板抄过来必崩"。

---

📌 阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/16-optimistic-lock-collab.md](../en/16-optimistic-lock-collab.md)
