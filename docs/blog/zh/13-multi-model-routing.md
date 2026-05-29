---
title: "Part 13：多模型路由 —— Claude / DeepSeek / Qwen 在同一个 Harness 里混用"
slug: 13-multi-model-routing
date: 2026-07-28
series: harwork-agent-harness
series_index: 13
keywords: [多模型路由, ModelRegistry, AI SDK, Vercel AI SDK, OpenAI 兼容, Anthropic, DeepSeek, Qwen, 智谱 GLM, token 计费, agent harness, streamText, 模型抽象, provider adapter]
prev: 12-websocket-30s-grace
next: 14-ai-artifact-rendering
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/13-multi-model-routing.md
---

# Part 13：多模型路由 —— Claude / DeepSeek / Qwen 在同一个 Harness 里混用

> 前 12 篇我们假设 agent 背后只有一个模型。但凡做过商用 agent 都知道：**复杂任务用 Claude Opus 思考，日常对话用 Haiku 省钱，写中文 prompt 用 Qwen 更顺，看 SQL/数据用 DeepSeek 性价比最高**。"多模型路由"听起来像个大工程——provider adapter、stream protocol 转换、token 计费分模型记账——但 HarWork 里**真正的"模型抽象层"只有约 230 行**（`packages/engine/src/models/registry.ts`）。这一篇拆解它为什么能这么短：**因为 90% 的国产模型都已经把自己包装成 OpenAI 兼容接口，剩下 10% 由 AI SDK 接管**——HarWork 不写适配器，只写"API key 闸口 + 命名空间前缀"。

**章节跳转：**[问题](#问题陈述) · [朴素方案](#朴素方案为什么不行) · [5 段硬编码](#核心方案5-段硬编码--ai-sdk--命名空间前缀) · [实现要点](#关键实现要点) · [反直觉](#反直觉结论) · [生产坑](#三个生产坑)

## 问题陈述

把"在 agent 里换模型"做对，要回答 5 个问题：

1. **怎么统一不同 provider 的 stream 协议？** Anthropic 的 `event: message_delta` 和 OpenAI 的 `data: {"choices":[...]}` 长得完全不一样——agent loop 拿到的应该是哪种？
2. **怎么让用户在前端选了 "Claude Sonnet 4" 就走 Anthropic，选了 "DeepSeek V4" 就走 deepseek.com？** 模型 id 怎么编码 provider 信息？
3. **token 怎么按模型分别计费？** Claude Opus 输出 75 美元/百万 token，Qwen Turbo 是 0.17 美元——相差 440 倍，**计费表必须按 modelId 索引**。
4. **新加一个 provider（比如 Moonshot Kimi）要改多少代码？** 是改 10 个文件还是 1 个？
5. **provider 偶尔挂了（key 失效、限流、网络抖）怎么办？** Agent 应该 fail-fast 还是 fallback？

这 5 个问题合起来 = 一个 agent harness 在"模型抽象层"必须给出的答案。HarWork 的答案藏在 4 个地方：`models/registry.ts`（注册 + 工厂）、`models/pricing.ts`（计费表）、`agent/loop.ts:198` 那一行 `streamText({model, ...})`（统一调用入口）、`dev-server.ts:218-229`（启动期 env → 实例）。**核心赌注是：不自己写抽象层，赌 Vercel AI SDK 已经把这层做平了**。

## 朴素方案为什么不行

**朴素 1：每个 provider 写一个 adapter 类，统一接口。** 看起来"工程"，实际是给自己挖坑。AI SDK 已经把 `streamText({model})` 做成了 provider-agnostic 入口——你再包一层等于把"已经统一的接口"再次包成"你以为统一的接口"。**坏处不是工作量，是 lock-in**：AI SDK 升级会让你的封装跟不上（v4 → v5 把 `completionTokens` 改成 `outputTokens`，HarWork 在 `agent/loop.ts:248` 用 `?? ` 同时兼容）。

**朴素 2：让前端直接调 provider 的 API。** 那 key 怎么放？放在前端就泄漏；放在 BFF 又要写 N 套 stream proxy。**HarWork 一切 LLM 调用都走 engine——这是安全前提，没有讨论空间**。

**朴素 3：所有模型走 OpenAI 兼容协议（用 LiteLLM 之类的转换层）。** 听起来一劳永逸，但你会丢掉**只在 Anthropic 协议里有的能力**：thinking budget（Claude 思考预算）、prompt caching、文档 source。**多模型的本质不是"统一协议"，是"统一编排"——协议保留各家的特色**。

**朴素 4：每个 provider 一套 modelId 命名空间，靠 baseURL 路由。** 比如 `gpt-4o` 直接走配置好的 baseURL。**问题**：用户的"自定义 provider"也叫 `gpt-4o`，怎么区分？HarWork 用 `provider:upstreamId` 双段命名（`zhipu:glm-4.7` / `deepseek:v4-pro`），前缀就是路由 key。**Anthropic 和 OpenAI 模型保留裸 id**（`claude-opus-4-20250514` / `gpt-4o`）是历史包袱，但因为它们是"已知品牌"，撞名概率低。

**朴素 5：动态注册——用户随时上传 key、立刻可用。** HarWork 不做：模型在**进程启动时一次性从 env 注入**（`dev-server.ts:218`），不支持运行时热加载。**原因**：probeAll 启动期就跑一遍，运行时再来新模型还要重新 probe，状态机复杂度上一个量级——**为一个低频需求换 10 倍状态机复杂度，不值**。要加新 provider，重启 engine。

HarWork 的实际选择：**registry 五段式硬编码 + AI SDK 接管 stream 协议 + 启动期 probe 标 `available` + namespace 前缀路由**。下面拆。

## 核心方案：5 段硬编码 + AI SDK + 命名空间前缀

### Registry 构造函数：5 个 `if (config.xxxApiKey)`（`models/registry.ts:72-164`）

```typescript
constructor(config: ModelRegistryConfig = {}) {
  if (config.anthropicApiKey) {
    const anthropic = createAnthropic({ apiKey: config.anthropicApiKey, ... })
    for (const info of ANTHROPIC_MODELS) {
      this.models.set(info.id, { info, factory: () => anthropic(info.id) })
    }
  }

  if (config.openaiApiKey) {
    const openai = createOpenAI({ apiKey: config.openaiApiKey, ... })
    for (const info of OPENAI_MODELS) {
      this.models.set(info.id, { info, factory: () => openai.chat(info.id) })
    }
  }

  if (config.zhipuApiKey) {
    const zhipu = createAnthropic({                       // ← 注意：用的是 createAnthropic
      apiKey: config.zhipuApiKey,
      baseURL: config.zhipuBaseURL || 'https://open.bigmodel.cn/api/anthropic/v1',
    })
    for (const model of ZHIPU_MODELS) {
      this.models.set(model.id, { info: model, factory: () => zhipu(model.upstreamId) })
    }
  }

  if (config.deepseekApiKey) {
    const deepseekFetch: typeof globalThis.fetch = async (input, init) => {
      if (init?.body && typeof init.body === 'string') {
        try {
          const body = JSON.parse(init.body)
          body.thinking = { type: 'disabled' }              // ← 强制关 thinking
          init = { ...init, body: JSON.stringify(body) }
        } catch { /* pass through */ }
      }
      return globalThis.fetch(input, init)
    }
    const deepseek = createOpenAI({
      apiKey: config.deepseekApiKey,
      baseURL: config.deepseekBaseURL || 'https://api.deepseek.com',
      fetch: deepseekFetch,                                 // ← 自定义 fetch 注入
    } as any)
    for (const model of DEEPSEEK_MODELS) {
      this.models.set(model.id, { info: model, factory: () => deepseek.chat(model.upstreamId) })
    }
  }
  // qwen 类似，OpenAI 兼容，baseURL 走阿里 dashscope
}
```

**5 个关键设计点**：

1. **没 API key 就不注册**——key 缺失的 provider 完全不出现在 `listModels()` 里。前端 UI 自然不会显示，杜绝"用户点了一个我没配 key 的模型"。
2. **每个 model 是 `{ info, factory }` 对**——factory 延迟到调用时才 `anthropic(modelId)` 真正构造，所以**同一个 model 可以被并发使用**（AI SDK 模型实例是无状态的）。
3. **Zhipu 用 `createAnthropic`，不是 `createOpenAI`**——智谱 GLM 提供了 Anthropic 兼容端点（`/api/anthropic/v1`），HarWork 直接复用 `@ai-sdk/anthropic` 包，**省一个 adapter**。但你的 modelId 仍然叫 `zhipu:glm-4.7`，不暴露"它走 Anthropic 协议"这个实现细节。
4. **DeepSeek 的 `deepseekFetch` 包装**：DeepSeek API 不接受 OpenAI 标准请求里的某些字段，但又会因为 AI SDK 默认开 thinking 模式爆 400。**解决**：拦截 fetch、解析 body、强塞 `thinking: { type: 'disabled' }`，再放出去。**这才是真正的 provider quirk**——SDK 抽象不掉，所以放在 registry 里。
5. **`upstreamId` vs `id`**：`{ id: 'deepseek:v4-pro', upstreamId: 'deepseek-v4-pro' }`——前者是 HarWork 暴露给前端/数据库的 stable id，后者是真实发给 API 的字符串。**Provider 改名（V4 → V4.1）只动 upstreamId，不动 id，数据库里的 default_model 字段不需要迁移**。

### `getModel(modelId)`：拿 factory 当场造（`models/registry.ts:166-172`）

```typescript
getModel(modelId: string): LanguageModel {
  const entry = this.models.get(modelId)
  if (!entry) {
    throw new Error(`Model "${modelId}" not found or not available. Available: ${[...this.models.keys()].join(', ')}`)
  }
  return entry.factory()
}
```

**没有缓存**——每次 `getModel` 都 new 一个 `LanguageModel`。看起来浪费，但 AI SDK 的 model 实例本质是"配置壳"（包含 baseURL、headers、apiKey），构造代价极低。**优势**：abort signal 等 per-request 状态不会跨请求泄漏。

### Agent loop 调用：一行 `streamText({model})`（`agent/loop.ts:198-209`）

```typescript
result = streamText({
  model,                                                    // ← 不管什么 provider，都是 LanguageModel
  system,
  messages: aiMessages,
  tools: aiTools,
  abortSignal: context.abortController.signal,
  ...(params.supportsThinking ? {
    providerOptions: {
      anthropic: { thinking: { type: 'enabled', budgetTokens: 10000 } },
    },
  } : {}),
})
```

**整个 agent loop 不知道当前是 Claude 还是 DeepSeek**——`model` 是 SDK 给的统一句柄。**唯一一个 provider-specific 分支是 `params.supportsThinking`**：只有标记 supportsThinking 的模型（`registry.ts:41-42`：Opus 4 / Sonnet 4）才注入 `providerOptions.anthropic.thinking`。这块设计反映了**"统一协议但保留各家特色"**的取舍：thinking budget 是 Anthropic 独有，SDK 把它放进 providerOptions.anthropic 命名空间下，**用就用、不用就别传**。

### 按模型分别计费：`pricing.ts` 一张表（`models/pricing.ts:6-42`）

```typescript
const MODEL_PRICING: Record<string, ModelPricing> = {
  'claude-opus-4-20250514':    { inputPer1M: 15,   outputPer1M: 75 },
  'claude-sonnet-4-20250514':  { inputPer1M: 3,    outputPer1M: 15 },
  'claude-haiku-4-5-20251001': { inputPer1M: 0.80, outputPer1M: 4 },
  'gpt-4o':      { inputPer1M: 2.50, outputPer1M: 10 },
  'gpt-4o-mini': { inputPer1M: 0.15, outputPer1M: 0.60 },
  'zhipu:glm-4.7':   { inputPer1M: 0.69, outputPer1M: 0.69 },
  'zhipu:glm-5':     { inputPer1M: 1.39, outputPer1M: 1.39 },
  'deepseek:v4-pro': { inputPer1M: 0.28, outputPer1M: 1.11 },
  'qwen:qwen-plus':  { inputPer1M: 0.11, outputPer1M: 0.56 },
  'qwen:qwen-max':   { inputPer1M: 1.39, outputPer1M: 5.56 },
  'qwen:qwen-turbo': { inputPer1M: 0.04, outputPer1M: 0.17 },
}

const DEFAULT_PRICING: ModelPricing = { inputPer1M: 3, outputPer1M: 3 }

export function estimateCostByModel(modelId, inputTokens, outputTokens): number {
  const pricing = MODEL_PRICING[modelId] || DEFAULT_PRICING
  return (inputTokens * pricing.inputPer1M + outputTokens * pricing.outputPer1M) / 1_000_000
}
```

**4 个值得展开的点**：
- **统一 USD**：国产模型的 RMB 价格按 ~7.2 汇率预转好，不在运行时换算——**避免汇率漂移导致历史账单"昨天 5 美元今天 4.9"**。
- **inputPer1M ≠ outputPer1M**：所有 LLM 输出都比输入贵，Claude Opus 5 倍、Qwen Max 4 倍、GPT-4o-mini 4 倍——**这就是为什么 agent harness 要削减输出 token（系统提示精简、结构化输出）比削减输入更划算**。
- **DeepSeek 在 input/output 上差 4 倍**（0.28 / 1.11）——但 Zhipu 是 1:1（0.69 / 0.69）。**国产模型计费模型不一致**，pricing 表必须分模型而不是分 provider。
- **DEFAULT_PRICING = {3, 3}**：注册了但没在 pricing 表里的模型，按 GPT-4o 输入价格估——**保底，不会因 modelId 拼写错误导致计费归零**。

### `agent/loop.ts:241-265` 每轮发 `usage_update` 给前端

```typescript
usage = await result.usage
const turnTotalTokens = usage.totalTokens ?? 0
totalTokens += turnTotalTokens
const turnCompletionTokens = (usage as any).outputTokens ?? (usage as any).completionTokens ?? 0
totalCompletionTokens += turnCompletionTokens

yield {
  type: 'usage_update' as const,
  turnTokens: usage.totalTokens ?? 0,
  turnCompletionTokens,
  totalTokens,
  totalCompletionTokens,
  costUsd: estimateCostByModel(modelId, totalTokens - totalCompletionTokens, totalCompletionTokens),
  contextWindowPercent: turnCtxPercent,
}
```

**`outputTokens ?? completionTokens` 这一行藏着 AI SDK 版本迁移的伤疤**——v4 时代叫 `completionTokens`，v5 改成 `outputTokens`，HarWork 不挑版本，**两个字段都接**。这是工程里少见的"两个都对"逻辑，因为 SDK 演进会留下兼容期。

### Probe 模型可用性：启动期跑一次（`models/registry.ts:199-225`）

```typescript
async probeModel(modelId: string): Promise<boolean> {
  const entry = this.models.get(modelId)
  if (!entry) return false
  try {
    const model = entry.factory()
    await generateText({ model, prompt: 'hi', maxOutputTokens: 1 })
    entry.info.available = true
    return true
  } catch (err) {
    entry.info.available = false
    return false
  }
}

async probeAll(): Promise<void> {
  await Promise.allSettled([...this.models.keys()].map((id) => this.probeModel(id)))
}
```

**`dev-server.ts:652` 启动时跑 probeAll**，每个模型发一个 1-token 的 `hi`——花费几乎为 0，但能**在 5 秒内知道每个 key/baseURL 是否真的能用**。`Promise.allSettled` 保证一个 provider 挂了不影响其他。`info.available = false` 直接反映到前端 UI 的"模型不可选"灰态。

## 关键实现要点

5 个不仔细看代码会漏掉的细节：

**1. 自定义 provider 走 `providers` 字段，不和 5 个内置 provider 抢位置（`registry.ts:143-163`）**

```typescript
if (config.providers) {
  for (const [providerName, providerConfig] of Object.entries(config.providers)) {
    const provider = createOpenAI({ apiKey: providerConfig.apiKey, baseURL: providerConfig.baseURL })
    for (const model of providerConfig.models) {
      this.models.set(model.id, {
        info: { id: model.id, displayName: model.displayName, provider: providerName, ... },
        factory: () => provider.chat(model.id),
      })
    }
  }
}
```

用户的"自定义 OpenAI 兼容 provider"（比如他家公司私有部署的 GLM-4，或者 Moonshot Kimi）通过 `providers: { kimi: { apiKey, baseURL, models: [...] } }` 注入，**id 是用户自己定的、不强加 `provider:` 前缀**——HarWork 信任用户管自己的命名空间。

**2. `streamText` 的 `abortSignal` 传的是 session 的 controller（`loop.ts:203`）**

```typescript
abortSignal: context.abortController.signal,
```

这一根线把 [Part 12](12-websocket-30s-grace.md) 的 30s grace abort 和 LLM 调用串起来——**grace 到期 abort()→ session.abortController.abort()→ AI SDK 收到 signal → upstream HTTP 请求中断 → token 不再计费**。**没有这条线，30 秒 grace 是空的**。

**3. `ws-message-handlers.ts:533-543` 把 contextWindow 和 supportsThinking 透传给 agent loop**

```typescript
const modelInfo = modelRegistry.getModelInfo(modelId)
const agentParams = createAgentParams({
  model,
  ...
  contextWindow: modelInfo?.contextWindow,
  supportsThinking: modelInfo?.supportsThinking,
})
```

`contextWindow` 决定了 agent loop 的[压缩触发阈值](03-agent-loop-async-generator.md)——Claude 200K vs DeepSeek 131K，触发时机不一样。`supportsThinking` 决定要不要给 streamText 加 `providerOptions.anthropic.thinking`。**Registry 不光是一张表，是一张带元数据的表**——你换模型，agent loop 的行为也跟着调（更短的 contextWindow → 更早压缩；不支持 thinking → 不传 budgetTokens）。

**4. fallback 链：用户 default → 系统第一个 available（`openai-compat.ts:131-145`）**

```typescript
if (!modelId || modelId === 'auto') {
  const preferred = await getDefaultModel(userId)
  if (preferred && modelRegistry.listModels().some(m => m.id === preferred && m.available !== false)) {
    modelId = preferred
  } else {
    modelId = modelRegistry.listModels().find(m => m.available !== false)?.id
  }
}
```

OpenAI 兼容路径上，`model: "auto"` 触发自动选择：**先看用户在 settings 里指定的 default_model，再退回到 registry 里第一个 available 的**。这是给"我不在乎用什么模型、谁能用就用谁"的 IDE 集成（Cursor / VS Code Continue 走 OpenAI 兼容 API）准备的兜底——**用户的体验是"模型选择"消失，HarWork 帮他挑**。

**5. 启动日志显示注册了哪些模型（`dev-server.ts:650`）**

```typescript
console.log(`[engine] Models registered: ${modelRegistry.listModels().map((m) => m.id).join(', ') || '(none — set API keys)'}`)
```

部署 HarWork 后第一次启动，**这一行是你判断 env 配对了没**的关键日志。如果显示 `(none — set API keys)`，说明 5 个 env 变量都没配上——你 `.env.local` 里少了什么。**这种"自我诊断"日志是 agent harness 标配，不靠用户读代码猜配置**。

## 反直觉结论

> [!IMPORTANT]
> **"多模型支持"的工程量与 provider 数量无关，与"协议家族数"相关**。HarWork 支持 5 个 provider（Anthropic / OpenAI / Zhipu / DeepSeek / Qwen），但其实只调用 2 个 SDK 包（`@ai-sdk/anthropic` + `@ai-sdk/openai`）——因为**Zhipu 走 Anthropic 兼容协议，DeepSeek/Qwen 走 OpenAI 兼容协议**。registry.ts 约 230 行能装下所有 provider 的原因是：**SDK 已经把"协议家族"那层抽好了，HarWork 只要写"哪个 key 走哪个 SDK"**。如果哪天有个 provider 既不兼容 OpenAI 也不兼容 Anthropic、自己另搞一套（比如 Google Gemini 早期），那 registry.ts 就会涨——不是因为多了一个 provider，而是因为多了一个**协议家族**。

更反直觉的：**HarWork 没有 "ModelProvider" 接口，没有 "BaseProvider" 抽象类，没有"插件系统"**。如果你之前做过 LiteLLM 或 LangChain 的 provider plugin 体系，会觉得这个 registry 太"扁"。但 HarWork 的押注是：**Vercel AI SDK 已经是事实标准，绑死它好过自己造一层"防止 lock-in"的抽象**。代价是 SDK 升级时偶尔要 `?? ` 兜底（如 `outputTokens ?? completionTokens`），收益是**新加 provider = 一个 `if` 块 + 一行 pricing**。

最反直觉的工程细节：**provider quirk 不抽象，直接写死**。DeepSeek 的 `deepseekFetch` 包装函数（强制关 thinking）是 HarWork 整个 codebase 里**最"hardcoded"的一段**——但它就**应该**这样。试图把它抽象成"GenericProviderQuirkHook" 只会让代码更难懂——quirk 是 provider 的具体毛病，不需要泛化。**抽象是为了多个相似的具体情况服务的；只有一个具体情况时，抽象本身就是 over-engineering**。

## 三个生产坑

> [!WARNING]
> **坑 1 —— probeAll 启动期跑成本不为零，但你可能没注意。**
>
> 每个模型一次 `hi` 调用 = 几个 token——10 个模型 = 几十个 token = ~ 0.01 美元。**单次启动忽略不计；但你如果在 CI 里跑 e2e 反复重启 engine，一天几百次，账单会冒出"莫名其妙的 1 美元"**。HarWork 没有 `skipProbe: process.env.NODE_ENV === 'test'` 的判断——CI 环境你应该用 mock provider 或者把 ANTHROPIC_API_KEY 等设成空，让 registry 直接跳过。

> [!WARNING]
> **坑 2 —— DEFAULT_PRICING `{3, 3}` 是个静音陷阱。**
>
> 你注册了一个新模型但忘了在 pricing.ts 加条目——计费照跑、但价格永远是 3 美元/百万 token。**用户看不出差错**，直到月底对账发现 token 数对得上、金额对不上——这种 bug 排查起来极痛苦。**HarWork 应该在 estimateCostByModel 里加 `console.warn` 当走 DEFAULT 分支时**，但目前没加。**如果你 fork HarWork、加自定义 provider，请记得同时加 pricing 条目**。

> [!WARNING]
> **坑 3 —— 动态 providers 没经过 probe。**
>
> `if (config.providers)` 分支（`registry.ts:143-163`）注册的自定义模型不会自动加入 `probeAll` 吗？其实**会**——`probeAll` 遍历的是 `this.models.keys()`，包含所有注册的模型。但是如果用户自定义 provider 的 baseURL 配错了或者 key 错了，会 5 秒内被标 `available = false`、UI 直接灰掉。**坑在用户视角**：他从环境变量配了 Kimi，结果启动后 UI 上 Kimi 是灰的——**他不知道是 probe 失败了**，以为是 HarWork bug。**生产部署应该把 probeAll 的日志（`[models] xxx: unavailable — <msg>`）暴露在 admin UI 而不只是 console.log**，但目前 HarWork 只 console.warn。

## 配图

1. ![ModelRegistry 分层架构](../assets/img/13-registry-layers.svg)
2. ![AI SDK stream 协议统一](../assets/img/13-stream-unification.svg)
3. ![按模型计费数据流](../assets/img/13-pricing-flow.svg)

## 下一篇

→ Part 14：AI 产物渲染 —— 让 agent 输出的代码 / 图表 / 设计稿可交互

模型抽象层讲完了，但 agent 输出的"产物"（artifact）——React 组件、Mermaid 图表、SVG、HTML 页面——怎么从 token 流变成可点击的预览？HarWork 的 design canvas（你正在用的这套设计协作流）背后有一套 artifact 渲染管线：streamText 输出的代码块怎么实时编译、iframe 隔离怎么做、用户在预览里修改怎么回传给 agent。下一篇拆这个"看得见的 agent"。

---

📌 阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/13-multi-model-routing.md](../en/13-multi-model-routing.md)
