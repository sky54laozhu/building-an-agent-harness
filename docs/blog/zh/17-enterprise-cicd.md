---
title: "Part 17：企业级 CI/CD —— canary + 多探针自动回滚"
slug: 17-enterprise-cicd
date: 2026-08-25
series: harwork-agent-harness
series_index: 17
keywords: [CI/CD, canary deployment, progressive rollout, GitHub Actions, P95 latency, auto rollback, nginx split_clients, agent harness, harwork, exponential backoff, quality gate, solo founder DevOps]
prev: 16-optimistic-lock-collab
next: 18-49-day-retro
canonical: https://github.com/sky54laozhu/building-an-agent-harness/blob/master/docs/blog/zh/17-enterprise-cicd.md
---

# Part 17：企业级 CI/CD —— canary + 多探针自动回滚

> 一个人撑 AI 平台，发布要回答 3 件事：每次部署不挂掉用户、出问题 5 分钟回滚、不需要 24h 监控也能睡好觉。HarWork 用 **7 件套渐进发布** 顶住——main/tag 自动构建 + staging→production 晋升门禁 + 组件分离发布 + nginx split_clients 流量切分 + 10/25/50/100 阶梯放量 + 失败率/平均/P95 多探针门限 + 阶梯失败指数退避重试。**关键不是抄大厂工具链，是把渐进发布这个工程模式做对**。本篇拆这 7 件套各自的工程细节、为什么 web 走 canary 而 engine 走 full、为什么 P95 比平均延迟更靠谱、为什么阶梯失败先回退不直接回滚——共 **1592 行 infra-as-code**（`.github/workflows/release.yml` 1239 + `.github/workflows/ci.yml` 97 + `docker/nginx.canary.conf.template` 120 + `docs/release.md` 136）。

## 问题陈述

solo founder 做生产级 SaaS，发布管线要解 4 个问题：

1. **每次部署不挂所有用户。** 一次性把 100% 流量切到新版 = 新版有 bug 时所有用户同时炸。
2. **出问题 5 分钟回滚。** 手动 ssh 改 docker-compose、人肉拉旧镜像 → 凌晨 3 点起床都难做到 5 分钟。
3. **不需要 24h 监控。** 不能依赖"出问题群里有人喊"——一个人没"群"，自动门限是唯一可靠信号。
4. **复杂度可维护。** Argo Rollouts / Spinnaker / Flagger 是大厂为 100 人发布团队设计的，单人维护成本爆炸。

这 4 个合起来 = 单人企业级发布的工程契约。HarWork 的答案藏在 4 个文件：`.github/workflows/release.yml`（7 件套主战场）、`.github/workflows/ci.yml`（基础 lint/test/build）、`docker/nginx.canary.conf.template`（nginx 流量切分）、`docs/release.md`（发布手册）。

## 朴素方案为什么不行

**朴素 1：手动 ssh deploy。** 起初没事——一周一次手动 `docker pull && docker compose up -d`，凭记忆操作。**第 3 个月必踩**：忘记 pull 子镜像、忘记备份旧 image tag、半夜出问题没快照可回。**手动操作的可靠性不随经验提升、随疲劳下降**。

**朴素 2：简单 `build & push`。** GitHub Action 跑 `docker build && docker push`，部署靠 server 端 cron 拉 latest。3 个坑：(1) **没有门禁**——任意失败的 PR 合并到 main 都会被推到生产；(2) **没有回滚路径**——latest 标签覆盖了，旧版没保留；(3) **没有质量观察窗**——一上去全量，5 分钟内没人发现就是 5 分钟 P0。**生产级 CI/CD 的最低门槛是"晋升 + 回滚 + 观察"三件**。

**朴素 3：抄大厂 CI/CD 模板。** Spinnaker pipeline.json、ArgoCD Application、Flagger Canary CRD ——单人维护成本爆炸。Spinnaker 自身就要 5 个微服务（clouddriver / front50 / orca / igor / gate），**为了发布 1 个应用先维护 5 个发布工具**——本末倒置。**大厂工具假设是"发布工程师团队"，单人 SaaS 用 = 自虐**。

**朴素 4：蓝绿部署。** 蓝绿 = 永远跑两份满规模实例（蓝当前生产、绿候选）。**单 VPS / 小集群直接资源翻倍**——成本翻倍、发布频率反而被资源约束拖慢。**蓝绿适合"发布 = 大事件"的传统企业，不适合"每周 2-3 次发布"的快速迭代 SaaS**。

**朴素 5：Kubernetes + Argo Rollouts。** 听起来"生产级"——但 k8s 本身的运维负担（etcd 备份、控制面升级、CNI 故障排查）就够一个 SRE 团队全职。**单人在阿里云一台 ECS 上 docker-compose 就够，硬上 k8s 是用 1000% 的复杂度换 1% 的功能收益**。

HarWork 的实际选择：**docker-compose + nginx split_clients + GitHub Actions 单 workflow + 7 件套**。下面拆。

## 核心方案：7 件套渐进发布

### 第 1 件：main/tag 自动触发 + 多模式分流（`release.yml:134-138`）

```yaml
on:
  workflow_dispatch:
    inputs:
      # 30 个参数，包括 image_tag / deploy_target / production_canary_percent ...
  push:
    branches: [main]
    tags: ['v*']
```

3 种触发模式分别走 3 条路径：(1) **push main** → 镜像 tag = `sha-<12位commit>`、自动 deploy-staging（`release.yml:263`）；(2) **push v\* tag** → 镜像 tag = git tag、自动 staging→production 晋升；(3) **workflow_dispatch** → 30 个参数全可调（包括 `deploy_tag` 用于回滚到历史镜像）。**3 种触发不是冗余、是"日常 / 正式版 / 应急"3 个工作流场景**。

### 第 2 件：staging → production 晋升门禁（`release.yml:499`）

```yaml
deploy-production:
  needs: [publish-engine, publish-web, deploy-staging]
  if: ${{ ... && ((github.event_name == 'workflow_dispatch' && (!inputs.require_staging_promotion || needs.deploy-staging.result == 'success')) || (github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') && needs.deploy-staging.result == 'success')) }}
  environment: production
```

3 道门：(1) `require_staging_promotion`（默认 `true`）—— production 发布前 staging 必须先成功；(2) **GitHub Environment: production**（`release.yml:500`）—— 配审批规则后必须人工点"approve"才放行；(3) **手动触发额外要求** `production_confirmation == "deploy-production"`（`release.yml:531-540`）—— 防误点。**3 道门叠加 = 不可能"误推生产"**。

冻结窗口（`release.yml:266-293` staging / `:502-529` production）：`DEPLOY_FREEZE_UNTIL` secret 配 UTC ISO8601 时间戳（如 `2026-05-20T00:00:00Z`），命中窗口直接 exit 1，**手动触发 `override_freeze=true` 才能强发**。月度发布冻结、双十一冻结、值班轮换 handover 都靠它。

### 第 3 件：组件分离发布 —— web 走 canary、engine 走 full（`release.yml:1131-1206`）

phased 策略里 web 和 engine 路径完全分开：

```bash
# 第 1 阶段：web 走 canary 10→25→50→100
if [ "$canary_percent" -gt 0 ]; then
  enable_canary_runtime "$first_canary_percent"  # 起 web-canary container
  for canary_step in $canary_ramp_csv; do
    apply_canary_split_percent "$canary_step"
    run_canary_step_validation                   # 多探针门限
  done
fi

# 第 2 阶段：web 全量收尾
docker compose ... up -d --no-build web
disable_canary_runtime

# 第 3 阶段：engine 直接 full
docker compose ... up -d --no-build engine ssh-gateway
```

**为什么 web canary、engine full**：web 是 HTTP 无状态，nginx split_clients 切流量天然友好；engine 是 WebSocket 长连接 + 会话有状态——**强行 canary engine 要做"WS 会话迁移到新进程"，工程量是 web canary 的 10 倍**。Part 12 拆过 engine 的 30s 宽限期 session 复活——那个机制依赖单进程内存，多进程切流量直接破坏前提。**所以 engine 直接 full + 客户端 30s 内自动重连**——架构借力比 canary 还稳。

### 第 4 件：nginx split_clients 流量切分（`nginx.canary.conf.template:24-35`）

```nginx
split_clients "${remote_addr}${http_user_agent}" $harwork_split_bucket {
    __CANARY_PERCENT__% canary;
    * stable;
}

map "$harwork_force_canary:$harwork_cookie_bucket:$harwork_split_bucket" $harwork_bucket {
    "~^1:" canary;          # X-Harwork-Canary: always 强制
    "~^0:canary:" canary;   # cookie 粘性
    "~^0:stable:" stable;
    "~^0::canary$" canary;
    default stable;
}
```

3 层决策优先级：(1) **`X-Harwork-Canary: always` header 优先**（line 13-16）—— smoke 探针用这个强制打到 canary（`release.yml:818`），不被流量百分比稀释；(2) **`harwork_canary` cookie 粘性**（line 18-22）—— 同一用户落到同一 bucket，避免 WS 重连跨 bucket；(3) **`split_clients` 按 `${remote_addr}${http_user_agent}` hash 百分比分流**（line 24-27）—— 同样的 IP+UA 永远落同一桶，**不是每次请求重抽**。`__CANARY_PERCENT__` 占位符由 `apply_canary_split_percent`（`release.yml:1044-1052`）用 `sed` 替换后 reload nginx。

### 第 5 件：10/25/50/100 阶梯放量（`release.yml:989-1042` build_canary_ramp_steps）

默认放量阶梯 `10,25,50,100`（`release.yml:117`），按 `production_canary_percent` 目标值截断——目标 50% → 阶梯变成 `10,25,50`；目标 100% → 完整 4 级。**为什么不从 5% 开始**：6 个采样请求（默认）下 5% 的样本量在 nginx hash bucket 里抽样误差太大；10% 是工程经验值——足够小到限制爆炸半径，足够大到样本统计有意义。每个阶梯间隔 `phase_wait / step_count` 秒（`release.yml:1119-1128`，默认 120s/4=30s 每级），**4 级总观察窗 ≈ 2 分钟**——比"一次性全量"安全 100 倍、比"24 小时灰度"快 720 倍。

### 第 6 件：多探针质量门限 —— 失败率/平均/**P95**（`release.yml:840-927`）

```bash
run_canary_quality_gate() {
  for probe_url in $probe_url_list; do
    # 采样 PRODUCTION_CANARY_SAMPLE_REQUESTS 次（默认 6）
    # 记录 http_code 和 time_total
    failure_percent=$((failures * 100 / total))
    avg_latency_ms=$((total_latency_ms / successes))
    p95_rank=$(((95 * successes + 99) / 100))
    p95_latency_ms="$(sort -n "$latency_samples_file" | sed -n "${p95_rank}p")"

    [ "$failure_percent" -gt "$MAX_FAILURE_PERCENT" ] && return 1   # 默认 20%
    [ "$avg_latency_ms" -gt "$MAX_AVG_LATENCY_MS" ] && return 1     # 默认 1500ms
    [ "$p95_latency_ms" -gt "$MAX_P95_LATENCY_MS" ] && return 1     # 默认 2500ms
  done
}
```

3 个门限**任一超限 = 阶梯失败**：失败率 20% / 平均延迟 1500ms / **P95 延迟 2500ms**。**P95 是核心**——平均延迟会被大量快速请求拉低（6 个请求里 5 个 50ms 1 个 5000ms，avg=875ms 通过 1500ms 门限），但 P95=5000ms 暴露了尾延迟问题。**只有 P95 才能抓出"大多数用户没事但一小撮人卡死"的退化场景**。每个探针采 6 次（line 866-889），用 stable 和 canary 两种 header 模式各跑一遍（`release.yml:937-942`）——**对比验证而非单测**。`run_canary_step_validation`（`release.yml:929-944`）依次跑 smoke → canary smoke → stable gate → canary gate，4 个全过才算这一级通过。

### 第 7 件：阶梯失败先回退 + 指数退避重试（`release.yml:946-965`、`:1141-1180`）

```bash
compute_recovery_wait_seconds() {
  failed_attempt="$1"
  wait_seconds="$PRODUCTION_CANARY_STEP_RECOVERY_WAIT_SECONDS"  # 默认 15s
  if [ "$failed_attempt" -gt 1 ]; then
    i=2
    while [ "$i" -le "$failed_attempt" ]; do
      wait_seconds=$((wait_seconds * multiplier))   # 默认 3x
      [ "$wait_seconds" -gt "$wait_cap" ] && wait_seconds="$wait_cap"  # cap 180s
      i=$((i + 1))
    done
  fi
}
```

失败序列：阶梯 25% 失败 → **回退到 10%**（上一级 `previous_canary_step`，`release.yml:1160`）→ **指数退避等待**（15s → 45s → 135s → 180s cap）→ **重试 25%**（默认 `PRODUCTION_CANARY_STEP_MAX_RETRIES=1` 即最多再试 1 次）→ 仍失败 → **触发 trap 回滚到上一版镜像**（`release.yml:692-728` `rollback_on_failure`）。**回退（ramp back） ≠ 回滚（image swap）**：回退是软的、退到上一个稳定阶梯；回滚是硬的、整个 docker-compose 切回旧镜像。**软在前、硬在后**——大多数退化是"放量太快暴露的性能问题"，回退就够；只有真 bug 才需要回滚。

## 反直觉结论

> **一人撑企业级发布的关键不是抄大厂工具链，是把渐进发布这个工程模式做对**。Spinnaker / ArgoCD / Flagger 是 100 人发布团队的工具——单人用 = 自虐。HarWork 用 **1239 行 GitHub Actions YAML + 120 行 nginx template** 实现 7 件套（canary 切流 + 阶梯放量 + 多探针门限 + 指数退避回退 + 自动回滚），跑在阿里云一台 ECS 上 docker-compose 拉起。**复杂度不是越高越好——单人维护要的是"7 件套都做对"，不是"100 件套都做错"**。

更反直觉的：**P95 比平均延迟更靠谱**。99% 的教程教 "monitoring 看 avg latency"，但 avg 是骗子——6 个请求 5 个 50ms 1 个 5000ms，avg=875ms 通过 1500ms 门限，但有一个用户等了 5 秒。**P95 才能抓出尾延迟退化**：同样的样本 P95=5000ms 直接超 2500ms 门限。HarWork 在 `release.yml:894-904` 用 `sort -n | sed -n "${p95_rank}p"` 6 行 bash 算出 P95 ——不需要 Datadog / New Relic，**6 行 bash + curl --write-out '%{time_total}' 就够**。

最反直觉的工程细节：**软回退在硬回滚之前**。直觉是"阶梯失败 → 立刻回滚到旧镜像"——但 HarWork 不这么做（`release.yml:1158-1170`）：失败先 `apply_canary_split_percent "$previous_canary_step"` 回到上一阶梯（25% 失败 → 退到 10%），等待指数退避秒数，再重试当前阶梯；只有 `MAX_RETRIES` 次还失败才触发 trap 整单回滚（`release.yml:400` `trap 'rollback_on_failure $?' EXIT`）。**为什么不直接硬回滚**：80% 的"阶梯失败"是临时抖动（GC pause、网络毛刺、依赖瞬时慢）—— **回退到稳定流量 + 等几十秒 + 重试**就能恢复；只有真 bug 才需要回滚。**软在前、硬在后 = 既不放过真问题、又不被假阳性逼疯**。

## 三个生产坑

**坑 1：`trap 'rollback_on_failure $?' EXIT` 的 `$?` 语义不稳。** `release.yml:400`、`:729` 都用了这个模式——意图是"脚本任何位置非 0 退出 → trap 抓到 exit code → 执行回滚"。但 bash 在 EXIT trap 里 `$?` 的值依赖触发场景：**`set -e` 触发的隐式退出**保留原 exit code，但**显式 `exit N`** 后 trap 里 `$?` = N，**信号触发（SIGTERM）**则 `$?` = 128+signal。SSH 断连（GitHub Actions runner 网络抖动）触发 SIGHUP → trap 看到 `$?` = 129 ≠ 0 → 误判"部署失败"启动回滚，但其实部署已成功只是 SSH 断了。**生产代价**：低概率但出现就是大事故。**修法**：trap 入口处加 `[ "$exit_code" -ge 128 ] && return`——信号触发不回滚（GitHub Actions 会重跑），只在脚本逻辑非 0 时回滚。

**坑 2：质量门限把 stable 桶也算进去 = 反向冤枉新版本。** `release.yml:937-942` 的 `run_canary_step_validation` 跑 4 个检查：smoke / canary smoke / **stable 桶质量门限** / canary 桶质量门限——任一失败整级失败。问题：**stable 桶跑的是旧版镜像**，如果旧版本身已经性能退化（比如内存泄漏跑了 30 天）、新版反而修复了——按当前逻辑，stable 桶超 P95 门限 → 整级失败 → 触发回退 → 回退到的就是更烂的旧版。**生产代价**：好版本被坏旧版的退化反向拖死、永远无法上线。**修法**：把 stable 桶的门限改成"参考值不阻塞"（记录但不 return 1），只让 canary 桶门限决定阶梯成败——**对比基线，不是双门限**。

**坑 3：冻结窗口的 `date -u -d` 不跨平台。** `release.yml:278`、`:514` 用 `date -u -d "$DEPLOY_FREEZE_UNTIL" +%s` 解析 UTC ISO8601——这是 **GNU coreutils 语法**，在 GitHub Actions 默认 ubuntu runner 上能跑。但部署目标主机若是 macOS（开发者本地）或 Alpine（小镜像 OS）→ `date` 是 BSD/busybox 实现、不识别 `-d`，**直接报"Invalid DEPLOY_FREEZE_UNTIL format"然后 exit 1**。当前能跑是因为 runner 是 ubuntu，但**复用脚本到本地或 Alpine 容器内就炸**。**修法**：用 Python 一行替代——`python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$DEPLOY_FREEZE_UNTIL'.replace('Z','+00:00')).timestamp()))"`——跨平台稳定。

## 配图

1. ![7 件套渐进发布全景流水线](../assets/img/17-progressive-release-pipeline.svg)
2. ![阶梯放量曲线 + 多探针质量门限](../assets/img/17-canary-ramp-quality-gate.svg)
3. ![阶梯失败回退状态机 · 软回退 → 硬回滚](../assets/img/17-rollback-state-machine.svg)

## 下一篇

→ Part 18：复盘 —— 49 天独立造 Harness 的得与失

7 件套发布管线撑住了"个人作品 → 生产可用"的最后一公里。但整个 HarWork 项目本身——从 2026-04-08 第一次 commit 到 2026-05-26 系列规划，**49 天 / 287 commits / 60.7K LOC / 110 tests** 独立全栈造 AI 平台 —— 真的值得吗？下一篇是系列收尾的诚实复盘：哪些技术选择回头看是对的（async generator Loop / Adapter 模式 / 单 WS / 7 件套发布）、哪些是错的（管理后台单组件膨胀 / SQLite 写并发瓶颈 / 错误监控只做 webhook 没接 Sentry）、哪些是没做完的（冲突 UI / 业务级 SLO / OpenAPI 字段级 schema）。**不卖"独立开发者神话"，只交付一份工程化复盘清单**。

---

📌 阅读地图：[reading-map.md](../reading-map.md)
🔗 English version: [en/17-enterprise-cicd.md](../en/17-enterprise-cicd.md)
