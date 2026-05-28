---
title: "第 08 篇：权限与沙箱 —— bash-analyzer / path-guard / Docker 三层防御"
slug: 08-permissions-sandbox
date: 2026-06-23
series: harwork-agent-harness
series_index: 8
keywords: [permission system, sandbox, Docker isolation, path guard, bash analyzer, bypass immune, yolo mode, agent security, AI safety, agent harness]
prev: 07-tool-system
next: 09-hooks-lifecycle
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/08-permissions-sandbox.md
---

# 第 08 篇：权限与沙箱 —— bash-analyzer / path-guard / Docker 三层防御

> 上一篇说了 `checkPermissions` 是工具的"第一道闸门"。但 LLM 会想出绕开第一道闸门的办法——把 `rm -rf` 拼到 `;` 后面、`base64` 编码再 pipe 给 shell、用 `$()` 替换、甚至直接写文件到 `.git/hooks/post-commit`。这一篇拆 HarWork 怎么用**三层防御**接住所有这些招式：bash-analyzer 拦命令内容、path-guard 拦写文件路径、Docker 沙箱兜底物理副作用。三层不是冗余，是**互补**——每一层抓不同的威胁模型，绕过一层不能绕过另两层。

**章节跳转：**[问题](#问题陈述) · [朴素方案](#朴素方案为什么不行) · [三层防御](#核心方案三层防御的分工) · [实现要点](#关键实现要点) · [反直觉](#反直觉结论) · [生产坑](#三个生产坑)

## 问题陈述

LLM 不会主动作恶，但它的训练语料里有大量"`curl xxx | bash`"这种 oneliner——它会在帮你装依赖的时候自然写出来。需要解决：

1. **怎么拦截危险命令？** —— Bash 工具不能依赖人审，得能自动识别 `rm -rf` / `curl | sh` / fork bomb 这些。
2. **怎么拦截危险文件操作？** —— LLM 可能写 `.env`、改 `.bashrc`、甚至改 `.git/hooks/post-commit`（这样下次 commit 就执行任意代码）。
3. **怎么兜底容器外副作用？** —— 即使前两层都过了，Bash 跑出来的命令也得限制在容器里，不能动 host。
4. **怎么给用户开口子？** —— 但 yolo 模式下 LLM 要能写文件、跑命令，三层都拦死就没法干活。

四个问题在生产环境都很现实，但 HarWork 把它们拆成**三层独立机制 + 一个 bypassImmune 标记**——分层在于关心的"威胁面"不同。

## 朴素方案为什么不行

**朴素一：只在 Bash 里拦 `rm -rf`**。LLM 用 `rm$IFS-rf` / 或者 base64 编码绕过 / 或者写到 .bashrc 让你下次开 shell 自动执行。**拦不住**——攻击面比 regex 大得多。

**朴素二：把 Docker 当唯一防线，反正出不了容器**。问题：容器里的 `.git/hooks/post-commit` 仍然会在你下次 git commit 时执行；`.ssh/authorized_keys` 写进去仍然能被 SSH 服务读到；`.env` 里的 token 仍然会被泄露给恶意服务。**容器隔离不能替代应用层 ACL**。

**朴素三：每个工具自己写权限逻辑**。`write.ts`、`edit.ts`、`bash.ts`、`notebook-edit.ts` 都要做 path-guard——4 份 regex 维护，迟早不同步。**逻辑会漂**。

**朴素四：把所有 deny 都做成"用户可以 override"**。LLM 看到 deny 就会"我有更好的办法"——回去想个变体再试。**让用户当门神是把责任推给最不该承担的人**。

HarWork 的方案：**分层 + bypassImmune**。每层独立、互不依赖；critical 级别（`rm -rf` / `.git/`）走 bypassImmune 路径——连用户都 override 不了。

## 核心方案：三层防御的分工

| 层 | 文件 | 关心什么 | 几行 | 拦截示例 |
|---|---|---|---|---|
| ① **bash-analyzer** | `security/bash-analyzer.ts` | 命令字符串内容 | 76 | `rm -rf /`、`curl \| sh`、fork bomb |
| ② **path-guard** | `security/path-guard.ts` | 文件路径 | 55 | 写 `.git/`、`.env`、`.ssh/` |
| ③ **Docker / K8s 沙箱** | `web/lib/workspace/docker.ts` (271) + `engine/workspace/k8s.ts` (300) | 进程边界 + 文件系统挂载 | 571 | 跑出容器写 host、改 host 文件 |

**三层独立**：bash-analyzer 不看 path，path-guard 不看 command，Docker 不看应用层语义。**互补**：bash-analyzer 漏掉的命令到了 Docker 也跑不出容器；path-guard 漏掉的文件到了 Docker 也只能写在挂载卷里；Docker 漏掉的（理论上没漏过）能被前两层在应用层拦住。

### Layer 1：bash-analyzer —— 26 条正则的语义守卫

`bash-analyzer.ts:15-49` 定义了 26 条 pattern：

```typescript
const PATTERNS: Pattern[] = [
  // critical（永远拦，bypassImmune）
  { regex: /\brm\s+(-[^\s]*)?r[^\s]*f|rm\s+(-[^\s]*)?f[^\s]*r/i, ... risk: 'critical' },
  { regex: /\bsudo\b/, ... risk: 'critical' },
  { regex: /\bcurl\b.*\|\s*(ba)?sh/, ... risk: 'critical' },
  { regex: /:\(\)\s*\{\s*:\|:\s*&\s*\}\s*;/, ... description: 'fork bomb', risk: 'critical' },
  { regex: /\bdd\b.*\bof=\/dev\//, ... risk: 'critical' },
  { regex: /\bmkfs\b/, ... risk: 'critical' },
  // warning（可被用户 override）
  { regex: /\bkill\s+-9\b/, ... risk: 'warning' },
  { regex: /\biptables\b/, ... risk: 'warning' },
  // ...
]
```

`bash.ts:317-325` 调用：

```typescript
const analysis = analyzeBashCommand(input.command)
if (analysis.risk === 'critical') {
  return {
    allowed: false,
    bypassImmune: true,  // ← 永远拦
    reason: `Dangerous command blocked: ${analysis.matchedPatterns.join(', ')}`,
  }
}
```

注意三个设计选择：

1. **`rm -rf` 的 regex 写得"对称"**——`/\brm\s+(-[^\s]*)?r[^\s]*f|rm\s+(-[^\s]*)?f[^\s]*r/i`——既匹配 `-rf` 也匹配 `-fr`，连 `-Rf` `-fR` 也都覆盖到。
2. **fork bomb 单独一条 regex** `/:\(\)\s*\{\s*:\|:\s*&\s*\}\s*;/`——这种 attack 不会被 `rm` 的 regex 抓到，但能让容器内存爆掉。
3. **`curl | sh` 和 `wget | sh` 分两条 pattern**——LLM 可能用任意一种，缺一条就漏。

### Layer 2：path-guard —— 两段式黑名单

`path-guard.ts:10-30` 定义两个 list：

```typescript
const BYPASS_IMMUNE_PATTERNS = [
  { pattern: /\/\.git\//, reason: 'Writing to .git/ internals is never allowed' },
  { pattern: /\/\.ssh\//, reason: 'Writing to .ssh/ is never allowed' },
  { pattern: /\/\.gnupg\//, reason: 'Writing to .gnupg/ is never allowed' },
  // ...
]
const PROTECTED_PATTERNS = [
  { pattern: /\/\.env($|\.)/, reason: 'Writing to .env files requires confirmation' },
  { pattern: /\/\.claude\//, reason: 'Writing to .claude/ config requires confirmation' },
  { pattern: /\/(\.bashrc|\.zshrc|\.bash_profile|\.zprofile|\.profile)$/, ... },
]
```

调用在 `write.ts:42-48`：

```typescript
const immune = isBypassImmuneProtected(input.file_path)
if (immune.blocked) return { allowed: false, bypassImmune: true, reason: immune.reason }
if (context.permissionMode === 'yolo') return { allowed: true }
const guard = isProtectedPath(input.file_path)
if (guard.blocked) return { allowed: false, reason: guard.reason }
return { allowed: true }
```

**注意 yolo 检查的位置**——它在 bypassImmune 之后、PROTECTED 之前。`.git/` 在 yolo 也拦，`.env` 在 yolo 可以写。这条不对称设计的语义是："yolo 是相信用户，不是禁用安全"——core security invariants 永远不让步。

`edit.ts:56-63` 和 `notebook-edit.ts:122-130` 完全相同的结构——三个工具共享同一个 `path-guard` 模块，**不重写**。

### Layer 3：Docker / K8s 沙箱 —— 内核级隔离

两个实现：
- `web/lib/workspace/docker.ts:36-58` 用 `dockerode` 创建容器：
  ```typescript
  HostConfig: {
    NanoCpus: 2_000_000_000,             // 2 CPU
    Memory: 3 * 1024 * 1024 * 1024,      // 3 GB
    Binds: [`harwork-data-${userId}:/workspace`],  // 只挂载 /workspace
    NetworkMode: NETWORK_NAME,
  },
  User: 'worker',                         // 非 root
  WorkingDir: '/workspace',
  ```
- `engine/workspace/k8s.ts:81-122` Pod + PVC：CPU/memory limits、`workingDir: '/workspace'`、`volumeMounts: [{ name: 'workspace-data', mountPath: '/workspace' }]`。

**三件事**：
1. **`/workspace` 是唯一可写**——所有 LLM 操作 confined 在挂载卷。Bash `rm -rf /` 在容器内即使被 bash-analyzer 漏过也只能删 rootfs（重启即恢复），动不了 host。
2. **资源 limits**——Docker 硬编码 2 CPU / 3 GB（`docker.ts:47-48`）；K8s 走 `config.cpuLimit/memoryLimit`（部署期可配）。fork bomb 即使被 bash-analyzer 漏过，最多打满当前容器，OOM-kill 自己。
3. **User: worker（非 root）**——`sudo` 即使被漏过也提升不了权限。

Docker 是兜底，不是首要——前两层在应用层就把 90% 攻击挡掉了，Docker 主要兜剩下 10%。

## 关键实现要点

5 个非显然细节：

**1. bypassImmune 是个布尔标记，但流程上是个"短路开关"**

`tool-executor.ts:417-440`：

```typescript
const permResult = tool.checkPermissions(call.args, context)
if (!permResult.allowed && permResult.bypassImmune) {
  audit(context, call, 'bypass_immune_block', permResult.reason)
  // → 直接拒绝，不进入 requestPermission 流程
  yield { type: 'tool_call_result', ..., isError: true }
  continue
}
if (!permResult.allowed) {
  // 普通 deny → 走 requestPermission 让用户选
  if (context.requestPermission) {
    const action = await context.requestPermission(...)
    // 用户可以 override
  }
}
```

**bypassImmune = true 时跳过 `requestPermission` 调用**——这是它和普通 deny 的唯一区别。但效果是质的：**用户连选择都没有**。

**2. 三种 permission mode 的行为矩阵**

| Mode | 读工具 | 写工具 | bash-analyzer warning | bash-analyzer critical | path-guard PROTECTED | path-guard BYPASS_IMMUNE |
|---|---|---|---|---|---|---|
| strict | 提示 | hard-deny | hard-deny | hard-deny | hard-deny | hard-deny |
| normal | 自动 | 提示 | 提示 | hard-deny | 提示 | hard-deny |
| yolo | 自动 | 自动 | 自动 | hard-deny | 自动 | hard-deny |

最右两列是 bypassImmune——**三种模式下都 hard-deny**。最左列 strict 模式下读工具都提示——这是为了让 strict 真的能起到 audit 作用。yolo 不是"全开"，是"开到 bypassImmune 为止"。

**3. denial tracker：连续 5 次或累计 20 次拒绝就中止**

`tool-executor.ts:193-211` + L408、L434：

```typescript
const denials = createDenialTracker(5, 20)
// 每次 deny：
const abortMsg = denials.record()
if (abortMsg) {
  yield { type: 'error', code: 'too_many_denials', message: abortMsg }
  return
}
```

**为什么要 tracker**：LLM 看到 deny 不会停，会反复变体重试。tracker 强制中断这种"硬撞墙"循环——防止 token 浪费 + 防止用户看到 50 条 deny 提示。

**4. Strict 模式连"读"都要提示**

`tool-executor.ts:124`：

```typescript
if (context.permissionMode === 'strict') return true  // needsPermission = true
```

很多 agent 系统把 strict 实现成"只读模式"，HarWork 反而是"全审 mode"——读也得点确认。这样 strict 真正变成了 high-stakes 任务的 audit mode（每一步都过用户脑子）。

**5. 并行调度退化到串行**

`tool-executor.ts:51-52`：

```typescript
const canParallel =
  permissionMode !== 'strict' &&  // ← strict 关掉并行
  tool != null &&
  tool.isReadOnly(call.args) &&
  tool.isConcurrencySafe(call.args)
```

strict 模式下 partitionToolCalls 不再合并 parallel batch——因为每次都要等用户点确认，并行没意义。**permissionMode 同时改变调度行为**——这是它能压缩到一个枚举值的关键。

## 反直觉结论

> [!IMPORTANT]
> **三层防御不是"重复保护"，是"分别守不同的边界"。** bash-analyzer 守命令语义边界、path-guard 守应用层 ACL 边界、Docker 守 OS 内核边界。三层守同一个东西就是冗余；守不同边界就是 defense in depth。**新加一个安全检查时，先想清楚它守的是哪条边界，再决定加在哪一层。**

换句话说：**bypassImmune 是产品决策，不是技术决策**。技术上完全可以让 `.git/` 也走 requestPermission（用户也能 override），但产品上不允许——因为"用户被社工后点 allow"是真实威胁。**让某些决策连用户都没机会做错，是把责任拿回到系统手里**。

最反直觉的：**yolo 模式比想象的要保守**。从功能上看 yolo "什么都让做"，但实际上 critical bash + bypassImmune path 在 yolo 下也是 hard-deny。**yolo 的含义是"少打扰用户"，不是"放弃 invariants"**。这是产品设计上的纪律——便利性可以让步，但 core safety 不让步。

## 三个生产坑

> [!WARNING]
> **陷阱一 —— 把 bash-analyzer 写成 LLM 调的工具。**
>
> 有人想"让 LLM 自己用 analyzer 工具检查命令"——LLM 会绕过去（不调用 analyzer 直接调 Bash）。**安全检查必须在 tool executor 强制路径上**，不能交给 LLM 自觉。

> [!WARNING]
> **陷阱二 —— path-guard 用 startsWith 而不是 regex。**
>
> `startsWith('/workspace/.git/')` 漏掉 `/workspace/sub/.git/`（用户的 monorepo）。**path-guard 必须用 regex 匹配 `\/\.git\//`** 这种"包含"，不是"前缀"。

> [!WARNING]
> **陷阱三 —— Docker 的 user 字段忘记设 worker。**
>
> dockerode 默认 user 是 root——一旦 root 在容器内，`chown` / `chmod 777` 可以改任何挂载文件的 owner。HarWork `docker.ts:55` 设 `User: 'worker'`、k8s 走 Pod securityContext。**容器内非 root 是 baseline，不是 optional**。

## 配图

1. ![三层防御的关心边界与拦截示例](../assets/img/08-three-layer-defense.svg)
2. ![permission mode 矩阵 + bypassImmune 短路](../assets/img/08-permission-matrix.svg)
3. ![Docker / K8s 沙箱关键约束](../assets/img/08-sandbox-constraints.svg)

## 下一篇

→ 第 09 篇：Hook 生命周期 —— 8 种事件如何安全跑

权限和沙箱守住了"LLM 不能做什么"，下一篇切到另一面：用户怎么在 LLM 做某事时**注入自己的代码**。Hook 系统暴露 8 个事件（PreToolUse / PostToolUse / UserPromptSubmit / Stop / SessionStart / SessionEnd / PreCompact / PostToolUseFailure），每个事件可以挂 shell 命令或 HTTP webhook，hook 在用户容器内并行跑，输出 JSON 还能改写 LLM 的输入、追加上下文、甚至 deny 这次调用。下一篇拆 hook executor 的 wrappedCommand 注入、退出码语义（0/2/其他）、并行聚合的"最严格优先"。

---

📌 系列阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/08-permissions-sandbox.md](../en/08-permissions-sandbox.md)
