---
name: spot-pre-log-analyze
description: 拉取并排查 KCEX spot 预发布(pre)环境日志。用户给出时间区间和要查的问题(如"pre 环境每天凌晨 3:30-8:00 横盘,看是不是下游出了问题"),用 curl 直查 Kibana/ES,结合日志字典定位原因。
---

# Spot Pre Log Analyze

排查 KCEX spot 预发布环境的历史日志。用户提供**时间区间 + 问题描述**,由本 skill 决定查什么、怎么查,最后给出带证据链的排查结论。

## 环境速查

| 项 | 值 |
|---|---|
| Kibana | `https://kibana.kcextest.com`(space `market`) |
| 账号 | `vito.lo` / `vito.lo`(Basic Auth) |
| ES 索引 | `market-kcex-market-maker-spot-*`(按天分索引,跨天用通配) |
| main 容器 | `kcex-market-maker-spot-main-e-1-1` |
| far 容器 | `kcex-market-maker-spot-far-e-1-1` |
| 日志时间 | `@timestamp` 是 **UTC**(带 Z) |
| 日志级别 | INFO / WARNING / ERROR / DEBUG |

## 拉日志脚本

脚本:`/root/.claude/skills/spot-pre-log-analyze/scripts/query_logs.sh`

```bash
# 基本用法
query_logs.sh --env main --from "2026-08-12 03:30 +0800" --to "2026-08-12 08:00 +0800" --level ERROR
query_logs.sh --env far  --from "2026-08-12 03:30 +0800" --to "2026-08-12 08:00 +0800" --msg "tick done"
query_logs.sh --env main --from now-15m --msg rate_limit --desc        # 相对时间 + 倒序
query_logs.sh --env far  --from "..." --to "..." --level WARNING --size 200   # 默认 size 50,拉大量时调大
```

脚本参数: `--from/--to`(任意 date 可解析格式,自动转 UTC)、`--env main|far`、`--container`(自定义通配)、`--level`、`--msg`(message 关键词)、`--size`、`--desc`(时间倒序,默认升序)、`--raw`(完整 JSON)。

输出格式:`@timestamp [LEVEL] file:line | message`,首行 `# total=N`。

**工作原理**(改脚本时注意):走 Kibana internal search API `POST /s/market/internal/search/es`,必须带 `x-elastic-internal-origin: Kibana` header,否则 Kibana 返回 400 "not available with the current configuration"。

## 时间处理规则

1. **用户给的时间默认是北京时间(UTC+8)**,转 UTC 时 -8h。脚本里直接传 `+0800` 让脚本转,如 `--from "2026-08-12 03:30 +0800"`。
2. 用户给"每天 3:30-8:00"这种**周期性**描述时,先确认具体哪一天,或默认查"昨天 + 今天"两个时间窗。
3. 索引按天分,跨 0 点(UTC)的时间窗**必须**用默认通配索引,不能收窄到单天。
4. 时间窗不要太宽:日志量约 1000+/分钟/容器。先窄后宽,或靠 `--level`/`--msg` 收窄。

## 日志字典

### tick_done(每个 tick 一行,核心汇总)
`spot_service_runner.cpp:360` SymbolRuntime::logInfoSummary()

```
tag=SOL-USDT trace_id=62535 tick done mode=normal ask1=76.33 bid1=76.3 strategies=0
before_tick: buy: step1: orders(3/3=100%,max=ok) quota(200.0/200.0=100%,band=over) ...
after_tick: ...
plan:brush=none fallback=none emergency_update=false ban_update=false rate_limit=0 req_err=0
```

| 字段 | 含义 |
|---|---|
| `mode` | `normal` / `ban` / `emergency` / `skip` |
| `ask1`/`bid1` | 本 tick 使用的买卖一价(`0` 或缺失 = 行情问题) |
| `strategies` | 参与规划的策略步数(0 = minWaitTime 跳过了策略执行,不是故障) |
| `orders(x/y)` | step 现有订单数/目标数 |
| `quota(used/limit,band=ok/over/low)` | 额度使用情况,`band=over` 表示超限 |
| `brush` | 刷量状态(`none` 或 `buy/sell(amount@price)`) |
| `fallback` | Emergency 行情降级链:`none` / `internal` / `quote_cache` / `emergency_grid` |
| `emergency_update`/`ban_update` | Emergency/Ban 网格是否成功提交 |
| `rate_limit` | 本 tick 的 429 次数 |
| `req_err` | 本 tick 的 request error 次数 |

**`fallback != none` 或 `mode=emergency/skip` 是下游(行情/交易所)出问题的直接信号。**

### 其他关键事件

| 事件 | 位置/关键词 | 含义 |
|---|---|---|
| `[position_stale]` | spot_coro_strategy_context.cpp:353 | 仓位数据过期(>阈值),用旧仓位继续 —— 下游仓位服务问题 |
| `mode_transition` | 模式切换日志 | normal ↔ ban ↔ emergency 切换及原因 |
| `price_ban_mode` / `price_default_grid_mode` | | ban/网格模式相关 |
| `reconcile_cold_start` / `reconcile_oversized` / `reconcile_expired` / `reconcile_cancel_unknown` | | 订单对账:冷启动/清理膨胀/过期/未知订单 |
| `plan_update_done` | DEBUG 级别 | 每个 strategy step 的计划变更(sell_add/buy_add/cancel/keep/force/flash) |
| `step_tick` | DEBUG 级别 | 每次 planOneStrategy 的触发类型 |
| `cancel_and_add` / `cancel_add_done` | | 撤挂批次及接受情况 |
| `default_grid_orders_replace` / `ban_orders_replace` / `special_grid_done` | | Emergency/Ban 网格订单 |
| `429_backoff_cleared` | | 限流退避清除 |
| `order_manager_step_failed` / `order_manager_ban_failed` | | 订单提交失败 |
| `cancel_batch_failed` | | reconcile 路径预期行为(交易所 400 = 订单已成交/取消) |
| `memory_stats` | memory_stats.cpp:92 | jemalloc 大 JSON,**排查时忽略** |

## 排查方法论

### 第一步:澄清输入
缺信息就问:具体日期(周期描述先确认哪天)、main 还是 far(默认两个都查,main 为主)、时区(默认北京时间)。

### 第二步:概览(先宽后窄)
```bash
# 1) 时间窗内所有 ERROR/WARNING
query_logs.sh --env main --from "..." --to "..." --level WARNING --size 500
# 2) 时间窗内模式分布:拉 tick_done 汇总
query_logs.sh --env main --from "..." --to "..." --msg "tick done" --size 500
```
从 ERROR 列表和 mode/fallback 分布判断:是行情问题、仓位问题、限流问题,还是代码逻辑问题。

### 第三步:按症状钻取

| 症状 | 查什么 | 判定 |
|---|---|---|
| 横盘/不报价/订单不动 | `--msg "tick done"` 看 mode、ask1/bid1、fallback | `fallback!=none`、`mode=emergency/skip`、`ask1=0` → 下游行情问题 |
| 下游(行情/交易所)出问题 | `--level WARNING` + `position_stale`、`req_err`、`rate_limit`、`mode_transition` | 仓位 stale、429 集中、模式切换频繁 → 下游确认 |
| 限流 | `--msg rate_limit`、`--msg 429` | `rate_limit>0` 期间 `executed` 全 0 是预期;恢复后追赶 |
| 铺单/撤单异常 | `--msg "tick done"` 看 planned vs executed、`reconcile_*`、`order_manager_*_failed` | planned 有但 executed=0 且无限流 → 提交失败 |
| 某 symbol 单独异常 | `--msg "tag=SOL-USDT"` 限定单币 | 单币 vs 全市场区分:全市场都挂 = 系统/下游;单币挂 = 该币行情或配置 |

### 第四步:对照验证
- **main vs far 对照**:同一时间窗两容器都拉。都异常 → 下游/共享服务;只有 main → main 部署问题。
- **问题时段 vs 正常时段对照**:拉相邻正常时段同样的查询,确认异常是时段性的。
- 需要精确时间线时用 `--raw` 拿完整 `_source`(含 kubernetes.pod_name、trace_id 等)。

### 输出格式
```markdown
## 排查结论
**时间窗**: <用户时间,注明时区>  |  **环境**: main/far/both

### 1. 结论
<一句话结论,如:3:30-8:00 横盘期间 mode=emergency 占比 100%,fallback=quote_cache,
行情源在此时段持续不可用,是下游行情问题,非本系统问题>

### 2. 证据
| 时间(UTC) | 事件 | 日志摘录 |
|---|---|---|
| ... | ... | ... |

### 3. 时间线
<关键事件按时间排列>

### 4. 对照
<main vs far / 问题时段 vs 正常时段 对比结论>

### 5. 建议
<需要谁处理、还能怎么进一步验证>
```

## 注意事项

- **memory_stats 日志是巨大单行 JSON**,`--msg "tick done"` 之类查询会自然过滤它;但 `--level INFO --size 大` 可能被它刷屏,必要时 `--msg` 收窄或 `--raw` 解析时跳过。
- 查询量控制:一次 `--size` 建议 ≤500,量大的场景先聚合(level 过滤)再钻取。
- 无法确认的结论不要猜,证据不足就多拉一个时间窗/一个过滤条件。
