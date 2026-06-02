# Building an Agent Harness

> HarWork 工程拆解博客系列 · Bilingual deep-dive into building a production-grade Agent Harness · 18 篇 · 中文 + English

## 仓库托管决策

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. 嵌在 HarWork 主仓 docs/blog/ | 与源码邻近，便于源码切片 | HarWork 私有 → 必须 publish 到独立 public mirror |
| B. 新建 blog 子 repo（推荐） | 公开权威源即托管地，无需 mirror | 抓源码切片需要跨仓 |

决策：B —— 新建公开仓 `sky54laozhu/building-an-agent-harness`
理由：
- HarWork 主仓不公开是已确定约束；mirror 流程脆弱；blog 仓自己就是权威源更可控
- 仓库名 `building-an-agent-harness` 抢"Agent Harness"关键词 + 蹭 Anthropic "Building agents" 文档的语义邻近 SEO
