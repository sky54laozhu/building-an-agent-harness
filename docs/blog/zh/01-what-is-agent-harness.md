---
title: "第 01 篇：什么是 Agent Harness —— 像 Claude Code 一样的 AI 编程工具是怎么造的"
slug: 01-what-is-agent-harness
date: 2026-05-26
series: harwork-agent-harness
series_index: 1
keywords: [Agent Harness, AI 编程助手架构, Claude Code 原理]
prev: null
next: 02-harwork-stack-overview
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/01-what-is-agent-harness.md
---

# 第 01 篇：什么是 Agent Harness —— 像 Claude Code 一样的 AI 编程工具是怎么造的

> 同样调 Claude API，为什么 Claude Code、Cursor、Aider 各有各的味道？答案藏在 LLM 之外的那层工程外壳里。

## 问题陈述

如果你打开 Claude Code、Cursor、Aider、Continue 的源码或公开材料，会发现一件有意思的事：**它们底下的 LLM 是同一批**——多半是 Claude Sonnet/Opus、GPT-4 系列、Gemini，外加各家自己微调过的中小模型。可它们的产品手感、扩展性、安全边界、断网行为，完全不一样。

差异不在模型本身。差异在**模型外面那层"壳"**：怎么把无状态的 `POST /v1/messages` 调用，拼装成一个能"看代码、改文件、跑命令、记住上下文、断线续传、跨会话同步"的工程工具。

这层"壳"，在英文工程圈逐渐被叫作 **Agent Harness**（直译：智能体支具/线束）。它不是 LLM，也不是 Agent 框架的一个抽象类，它是把 LLM 当成 CPU、把工具当成外设、把对话当成会话状态的一整套**运行时**。

本系列就是拆这件外壳。今天这一篇，先把"什么是 Agent Harness"这件事讲清楚。

## 朴素方案为什么不行

要造一个 AI 编程助手，最直觉的三种做法都走不远。

**方案一：直接 `curl` LLM API。** 你把整份代码贴进 prompt，让模型返回 diff 自己 patch。十分钟内能跑通 demo。但只要项目稍大就破功：上下文窗口装不下、模型看不到运行结果、你也没法让它"先 grep 一下再决定改哪里"。这条路本质上是"把人类工程师的眼睛和手蒙住"。

**方案二：套个 LangChain Agent / ReAct 模板。** 这条路在 2023 年风靡一时。问题是抽象太浅——它解决了"如何让 LLM 在循环里调工具"，但没解决"工具调用结果如何回灌到下一轮"、"对话太长了怎么压缩"、"`rm -rf /` 这种命令谁来拦"、"流式输出到一半断线了怎么续"、"用户中断后怎么干净退出"。生产环境随便跑一周就会暴露十几个边界 bug。

**方案三：自己写一个 ReAct prompt 循环。** 看起来很灵活。但你写完循环会发现：每加一个工具就要改 prompt，每接一个新模型就要重写工具调用解析（Anthropic 的 tool use 和 OpenAI 的 function calling 字段不一样），每加一个安全规则就要重新跑回归。三个月后你写出来的就是一个**功能阉割版**的 Harness——而且没人能维护。

这三条路的共同 bug 是：它们都把"调 LLM"当成核心问题。真到工程里，**直接调 LLM 大概只占整体工程量的 20%**，剩下 80% 决定产品手感和稳定性的部分，全在 LLM 调用的"前后左右"：调用之前要决定哪些工具能用、哪些路径不能碰；调用之中要把 token 流转成事件、把工具调用拆成可中断的子任务；调用之后要把结果回灌、把上下文压缩、把日志结构化。Harness 就是这 80% 的容器。

## 核心定义

我们给 Agent Harness 下一个明确定义：

> **Agent Harness：把无状态 LLM API 包装成"有状态、可控、可观测、可扩展"的工程 Agent 的运行时层。**

四个关键词都是钱，缺一个用户就跑掉：

- **有状态**：会话能跨断线、跨容器重启活下来；上下文能被压缩、回放、检索；用户改了 30 轮的对话不会因为浏览器刷新就丢。
- **可控**：用户能随时中断、回退、改主意；危险操作（删文件、外网请求、写敏感目录）有审批；token 额度、并发数有硬性约束，不会被一个坏 prompt 拖垮整个服务。
- **可观测**：每一次 LLM 调用、工具调用、上下文压缩、Hook 触发都有结构化日志；线上出错能从日志一路定位到具体哪一行 prompt、哪一次工具响应；账单能按用户、按模型、按工具拆分。
- **可扩展**：第三方不用改源码，靠 Hook 和 Skill 就能加新工具、新触发器、新模型；社区的扩展能像浏览器插件一样安装；同一份 Harness 既能跑通用编程任务，也能跑领域专用 Agent（医疗、法务、运维）。

要同时满足这四点，至少需要 7 个必备组件，刚好对应本系列后面的 7 个板块：

| 组件 | 解决什么问题 | 对应板块 |
|------|--------------|----------|
| Agent Loop | 多轮工具调用如何安全终止 | 二 |
| Context Engine | 长对话如何不爆窗口 | 二 |
| Tool Protocol | 工具如何被发现、调用、中断 | 三 |
| Extension Points | 用户如何在不改源码的前提下扩展 | 三 |
| Sandbox & Security | 危险命令、文件穿越、密钥怎么防 | 四 |
| Session & Streaming | 断线、并发、多模型怎么撑 | 五 |
| DevOps | 一个人 / 小团队怎么撑生产 | 七 |

每个组件单独看都不复杂，难的是**让它们之间的接口不漏水**——这正是后面 18 篇要拆的。

## 关键实现要点

不同 Harness 的取舍可以一眼看出来。下面这张表，是我读完 [Anthropic 关于 Agent 的官方设计文档](https://www.anthropic.com/research/building-effective-agents)、[Cursor 团队在 Lex Fridman #447 的两小时访谈](https://lexfridman.com/cursor-team-transcript/)、[Aider 作者 Paul Gauthier 关于"LLM 在 JSON 里返回代码会出错"的基准测试](https://aider.chat/2024/08/14/code-in-json.html)，加上 HarWork 自己造一遍 Harness 的体感，整理出来的：

| 维度 | Claude Code | Cursor | Aider | HarWork |
|------|-------------|--------|-------|---------|
| Loop 形态 | 终端 + 异步生成器 | 编辑器内嵌 | 终端 + Git | 终端 + Web 双形态 |
| 上下文压缩 | 5 层渐进 | 编辑器侧检索 | 仓库 map + 选择性注入 | 5 层渐进 |
| 工具协议 | Anthropic tool use | 编辑器协议 | Diff 应用 | Anthropic tool use + 自定义扩展 |
| 沙箱 | OS 进程 | 编辑器进程 | Git 工作树 | Per-User 持久 Docker |
| 扩展点 | Hook + Skill + Plugin + MCP | 编辑器内 | 命令行参数 | Hook + Skill + Plugin |

看起来差异很大，但**底层都在解 7 个组件这同一道题**——只是各自的优先级不一样：Cursor 把交互体验做到极致，Aider 把 Git 集成做到极致，Claude Code 把可扩展做到极致，HarWork 这套则把"单人也能撑起企业级 DevOps"做到极致。

如果你想自己读源码验证这一点，HarWork 项目内部的 `docs/claude-code-analysis/` 目录有 16 篇 Claude Code 源码逆向笔记，覆盖了 Agent Loop、上下文压缩、权限系统、Hook 系统、Skill/Plugin 等核心模块——本系列后面会逐一展开。

## 反直觉结论

> **Harness 的难点不在 LLM 调用，而在"LLM 不调用的时候"——工具结果如何回灌、压缩何时触发、断线如何续传、用户改主意时如何回滚。Harness ≈ 80% 工程问题 + 20% LLM 问题。**

这句话的含义是：**做一个能用的 AI 编程工具，主要靠的是经典分布式系统、操作系统、数据库的工程功夫，而不是 prompt engineering**。

举个具体例子。Claude Code 处理"用户按 Ctrl-C 中断"这件事，源码里走的是 AbortController + 异步生成器协议 + 工具 cleanup 钩子三层联动：信号传到 Loop，Loop 把当前正在跑的工具标记为 cancelled，工具自己负责清理已经写到一半的文件、关掉打开的子进程、提交可回滚的事务——任何一层漏写都会留下脏状态。Cursor 团队在 Lex Fridman 访谈里专门讲过他们怎么用 Merkle tree 做仓库语义索引、怎么用 KV Cache 共享 transformer 注意力，本质都是为了解决"上下文够大但又不能拖慢响应"这个工程矛盾——**全是工程问题，不是 LLM 问题**。

再举个反例。Aider 作者 Paul Gauthier 跑过一组基准测试：让 LLM 把代码包在 JSON 里返回，**所有模型**的成功率都明显下降，Sonnet 和 DeepSeek Coder 掉得最惨——因为 JSON 的字符串转义会污染模型生成代码时的注意力。这条结论无法通过"换更强的模型"解决，只能通过工程上选对协议来绕过：所以 Aider 选择 plain text + diff 块，而不是函数调用。Harness 的价值就在这里：它替你把"哪种协议对哪种模型最稳"沉淀下来，下次换模型时不用从零踩坑。

反过来，你给 Harness 换一个更强的 LLM，大概率只能解决 5% 的 bug；你把 Harness 的工具协议从 sync 改成 async streaming，往往一次性解决 30% 的 bug。这就是为什么 Cursor、Aider、Claude Code 即便共用同一批 Claude 模型，产品形态却完全不同——壳的差异决定了上限。

这就是为什么本系列 19 篇里，真正讲"怎么调 LLM"的只有 1-2 篇，剩下的 17 篇全在讲循环、上下文、工具、沙箱、流式、会话、可观测、DevOps——**这才是 Harness 的本体**。

## 配图

1. ![同一个问题，多家答案：Claude Code / Cursor / Aider / HarWork 的栈对比](../assets/img/01-comparison.svg)
2. ![Harness 七层组件同心圆图](../assets/img/01-seven-components.svg)
3. ![裸 LLM vs Harness：同一个 prompt 的不同遭遇](../assets/img/01-naked-vs-harness.svg)

## 下一篇

→ [第 02 篇：HarWork Harness 全景图——16 层栈一次性摊开](./02-harwork-stack-overview.md)

下一篇我们用 HarWork 真实代码做样本，把 16 层栈从 LLM API 一直摊到 CI/CD，附上 cloc 实测的业务代码占比——你会看到一个反直觉的数字。

---

📌 系列阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/01-what-is-agent-harness.md](../en/01-what-is-agent-harness.md)
