# Building an Agent Harness

> A 19-article bilingual deep dive on the engineering behind a production-grade AI Agent Harness, drawn from HarWork — a solo-built platform shipped in 69 days.
>
> 19 篇双语工程拆解 · 从 HarWork（一人 69 天打造的企业级 Agent Harness）的真实实现讲起。

## Status

🚧 **Scaffolding** · Article 01 in preparation. See [reading map](./docs/blog/reading-map.md) once published.

## What you'll find here

| Path | Purpose |
|------|---------|
| [`docs/blog/zh/`](./docs/blog/zh/) | 中文版 19 篇 |
| [`docs/blog/en/`](./docs/blog/en/) | English version, 19 articles |
| [`docs/blog/assets/`](./docs/blog/assets/) | Diagrams, code snippets, images |
| [`docs/blog/seo-matrix.md`](./docs/blog/seo-matrix.md) | Keyword × article map |
| [`docs/blog/DECISIONS.md`](./docs/blog/DECISIONS.md) | Hosting / structure ADRs |
| [`scripts/blog/`](./scripts/blog/) | Content production tooling |

## Reading order

- **From scratch**: 01 → 02 → ... → 19
- **Skim path (8 articles)**: 01 → 02 → 03 → 07 → 10 → 11 → 13 → 18
- **Hacker News path**: 01 → 11 → 18 → 19

Full reading map lands with Article 01.

## Series themes

1. **Foundations** — what an Agent Harness *is*, full architecture map
2. **Core loop** — async generators, context compression, tool orchestration, memory
3. **Tools & extensions** — protocol, skills, hooks
4. **Sandbox & security** — per-user Docker, 138-rule bash analyzer, three-layer permissions
5. **Session & streaming** — WebSocket resilience, multi-model routing
6. **Design collaboration** — Harness as substrate for non-code AI artifacts
7. **DevOps & retrospective** — solo CI/CD, 69-day postmortem

## License

Content (articles, diagrams): TBD — likely [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
Tooling (`scripts/blog/`): TBD — likely MIT

Final license decisions land before Article 01 ships.

---

🔗 中文读者：每篇都有 `zh/` 版本，结构对齐 / [seo-matrix.md](./docs/blog/seo-matrix.md) 含全部中英关键词映射。
