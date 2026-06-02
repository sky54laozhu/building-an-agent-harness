# 单篇发布 Checklist

发布前必过：

## 内容
- [ ] zh / en 双语已 commit 入仓
- [ ] Front Matter 的 prev / next 已对齐
- [ ] 反直觉结论存在且 ≠ 标题重复
- [ ] 所有配图至少 1 张原创（非纯文字流程图）
- [ ] SVG 含 `<title>` `<desc>`
- [ ] PNG @2x 已导出至 assets/img/

## 链接
- [ ] 死链扫描：`scripts/blog/check-links.sh docs/blog/zh/NN-*.md`
- [ ] 跨篇引用号正确（指向真实存在的篇号）
- [ ] 内链关键词与 seo-matrix.md 一致

## 数据
- [ ] 字数：zh 1500-3000 / en 1200-2400（第 18 篇可破上限）
- [ ] 字数已记入 analytics/publishing-log.md

## 平台
- [ ] GitHub 已 push 到 master
- [ ] 掘金已发，文末有"原文 GitHub"链接
- [ ] dev.to 已发，hashtag = #ai #agents + 篇特定
- [ ] 数据卡 `analytics/metrics/NN-<slug>.md` 已建（24h 后回填）

## HN 篇（仅 11 / 18）
- [ ] 周二 8am PT 发
- [ ] Title 30-80 字符，含反直觉钩子
- [ ] 首评本人放，1 段背景 + 1 段邀评
