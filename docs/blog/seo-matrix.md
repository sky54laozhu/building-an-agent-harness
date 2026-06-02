# SEO 关键词 × 篇章映射

> 篇号以最终 18 篇结构为准（见 reading-map.md）。

## 中文主关键词（用于知乎 / 掘金 / 公众号）

| 关键词 | 主篇 | 辅助篇 |
|--------|------|--------|
| Agent Harness | 01 | 02 |
| AI 编程助手架构 | 01 | 02 |
| Agent Loop 设计 | 03 | 04, 05 |
| LLM 上下文压缩 | 04 | 03 |
| 工具协议 | 07 | 05, 08, 09 |
| AI 沙箱 | 08 | 11 |
| LLM 安全护栏 | 08 | 09 |
| WebSocket 重连 | 12 | 10 |
| 多模型路由 | 13 | 10 |
| AI 产物可视化 | 14 | 15, 16 |
| 企业级 CI/CD | 17 | 18 |

## 英文主关键词（用于 dev.to / HN / Medium）

| Keyword | Primary | Secondary |
|---------|---------|-----------|
| agent harness | 01 | 02 |
| llm agent loop | 03 | 04, 05 |
| context compression | 04 | 03 |
| tool protocol | 07 | 05, 08, 09 |
| ai sandbox | 08 | 11 |
| agent safety | 08 | 09 |
| websocket session resilience | 12 | 10 |
| llm provider abstraction | 13 | 10 |
| optimistic locking ai | 16 | 14, 15 |
| solo founder ci/cd | 18 | 17 |
| canary deployment | 17 | 18 |

## 链接结构（内链规则）

- 每篇 Front Matter 的 `prev` / `next` 自动生成上下篇导航
- 文内首次出现某个核心概念，必须链到该概念主篇
- reading-map（系列阅读地图）是全集 hub，所有篇页脚都链回 reading-map
