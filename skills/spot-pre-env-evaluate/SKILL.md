---
name: spot-pre-env-evaluate
description: 启动 KCEX Spot 连接预发布环境，观察做市行为和订单管理，检查限流/铺单/模式切换是否正常
---

# Spot Pre Env Evaluate

启动 KCEX Spot C++ 做市系统连接预发布环境（`pre-env.yaml`），运行几分钟，
检查做市链路是否正常：行情解析 → 模式切换 → 策略铺单 → exchange 提交 → 限流处理 → reconcile。

## 程序启动方式

```bash
# 1. Debug build
cd /kcex/cpp/spot/build-debug
cmake .. -DCMAKE_BUILD_TYPE=Debug
make -j$(nproc)

# 2. 从 launch.json 读取环境变量（不要硬编码）
# 找到 "Spot (pre-env-debug)" 配置项，提取 environment 中的所有变量
# 构造 env 字符串，例如: DEPLOY_PROCESS=C-1-1 KMM_RUNTIME_ENV=pre LOG_LEVEL=INFO LOG_HISTORY=1
cd /kcex/cpp/spot
<从 launch.json 读取的 env vars> \
./build-debug/kcex-mm-spot \
  --config dev/config/pre-env.yaml \
  --loop \
  --interval-ms 3000 \
  > /tmp/spot_pre_run.log 2>&1 &
```

### 关键环境变量（每次从 launch.json 读取最新值）

| 变量 | 来源 | 作用 |
|---|---|---|
| `DEPLOY_PROCESS` | `.vscode/launch.json` → `"Spot (pre-env-debug)"` → `environment` | 部署分组，映射到 MySQL `spot_symbol_configs` 表的 `process_group` 列 |
| `KMM_RUNTIME_ENV` | 同上 | 运行时环境标识 |
| `LOG_LEVEL` | 同上 | 日志级别：INFO 用于常规检查，DEBUG 用于定位 plan 层 bug（能看到 `plan_update_done`、`step_tick`、`cancel_add_done`） |
| `LOG_HISTORY` | 同上 | 启用 log history（`/loglevel` admin endpoint 可用） |

### 预发布环境依赖

`dev/config/pre-env.yaml` 连接到真实预发布环境：
- Exchange API: `http://openapi.kcexpre.com/spot`
- MySQL: pre RDS (`kcex-pre-maker-common.cluster-cpyw088uimn5.ap-northeast-1.rds.amazonaws.com`)
- Redis: pre cluster (`pre-common-redis-cluster.zjhkak.clustercfg.apne1.cache.amazonaws.com`)
- `SUBMIT_ENABLED: true` — 会实际向预发布交易所下单

### 与 test 环境的关键差异

| 项目 | test | pre |
|---|---|---|
| MySQL host | `kcex-test-maker-common.cluster-...` | `kcex-pre-maker-common.cluster-...` |
| MySQL user | `aikrtj` | `eoZTxv4mPg` |
| Redis host | `test-common-redis-cluster.zjhkak...` | `pre-common-redis-cluster.zjhkak...` |
| Exchange API | `openapi.kcextest.com` | `openapi.kcexpre.com` |
| Config 文件 | `dev/config/test-env.yaml` | `dev/config/pre-env.yaml` |
| 日志文件 | `/tmp/spot_test_run.log` | `/tmp/spot_pre_run.log` |

## 观察方法

### 1. 启动确认
```bash
# 等待进程启动并加载 symbol
until grep -q "tick_done" /tmp/spot_pre_run.log 2>/dev/null; do sleep 2; done
```

### 2. tick_done 汇总日志（每个 tick 一行）
```bash
grep "tick_done" /tmp/spot_pre_run.log | tail -10
```

日志字段含义：

| 字段 | 来源 | 含义 |
|---|---|---|
| `mode` | plan layer | `normal` / `ban` / `emergency` / `skip` |
| `ask1` / `bid1` | plan layer | 本 tick 使用的买卖一价 |
| `strategies` | plan layer | 本 tick 参与规划的策略步数（0 = minWaitTimeSeconds 跳过了策略执行） |
| `planned(cxl=N add=M)` | plan layer | Reconciler 产出的计划撤单/挂单数 |
| `executed(cxl=N add=M ok=M)` | exec layer | OrderManager 实际执行的撤单/挂单/成功数 |
| `brush` | plan layer | 刷量状态（`none` 或 `buy/sell(amount@price)`） |
| `fallback` | plan layer | Emergency fallback 层级（`none` / `internal` / `quote_cache` / `emergency_grid`） |
| `emergency_update` / `ban_update` | exec layer | Emergency / Ban 网格是否成功提交 |
| `rate_limit` | exec layer | 本 tick 触发的 429 次数 |
| `req_err` | exec layer | 本 tick 的 request error 次数 |

### 3. 模式切换
```bash
grep "mode_transition\|price_ban_mode\|price_default_grid_mode" /tmp/spot_pre_run.log | tail -10
```

### 4. Reconcile 行为（每 20 tick 一次）
```bash
grep "reconcile\|openOrders" /tmp/spot_pre_run.log | tail -10
```

### 5. 错误和限流
```bash
grep "ERROR\|WARNING\|rate_limit" /tmp/spot_pre_run.log | tail -20
```

### 6. 停止进程
```bash
pkill -f "kcex-mm-spot.*pre-env"
```

### 7. 日志级别切换

当 `assert_plan_count_fail` 等 assert 触发但 INFO 级别看不到 plan 细节时，切 `LOG_LEVEL=DEBUG` 重新启动。DEBUG 级别会输出：
- `plan_update_done` — 每个 step 的 sell_add / buy_add / cancel / keep / force / flash
- `step_tick` — 每次 planOneStrategy 的触发类型和计划量
- `cancel_add_done` — 每批 cancelAndAdd 的接受情况

切 DEBUG 后日志量大增，运行 30-60 秒即可，找到问题后切回 INFO。

### 8. 清理存量日志

```bash
# 清理超过 1 天的旧日志，避免 /tmp 堆积
find /tmp -name "spot_pre_run*.log" -mtime +1 -delete 2>/dev/null
```

### 7. 盘口状态追踪

盘口（订单簿）是系统向交易所提交的挂单集合。通过以下命令追踪盘口从冷启动到稳态的演变过程。

#### 7a. 盘口变更时间线（每 tick 的 planned vs executed）
```bash
# 抽取每个 tick 的计划/执行差异，观察盘口如何一步步建立
grep "tick_done" /tmp/spot_pre_run.log | \
  awk '{print $0}' | \
  grep -oP 'mode=\S+|planned\(cxl=\d+ add=\d+\)|executed\(cxl=\d+ add=\d+ ok=\d+\)|rate_limit=\d+|req_err=\d+|emergency_update=\w+|ban_update=\w+' | \
  paste - - - - - -
```

简化版（只看核心盘口变化）：
```bash
grep "tick_done" /tmp/spot_pre_run.log | \
  grep -oP 'planned\([^)]+\) executed\([^)]+\) rate_limit=\d+'
```

#### 7b. 首次 tick（冷启动盘口）
```bash
# 第一个 tick_done 显示初始盘口状态
grep "tick_done" /tmp/spot_pre_run.log | head -3
```

#### 7c. 最后几个 tick（稳态盘口）
```bash
# 稳态下 planned cxl/add 应趋近于 0（盘口与目标一致，无需变更）
grep "tick_done" /tmp/spot_pre_run.log | tail -5
```

#### 7d. 限流时的盘口更新（重点）
```bash
# 限流 tick：planned 有值但 executed 全为 0
grep "tick_done" /tmp/spot_pre_run.log | grep -v "rate_limit=0" | head -10

# 限流恢复后的第一个成功 tick
grep "tick_done" /tmp/spot_pre_run.log | grep "rate_limit=0" | grep -v "executed(cxl=0 add=0"
```

#### 7e. Grid 网格更新日志
```bash
# Emergency 网格（default_grid）
grep "default_grid_orders_replace" /tmp/spot_pre_run.log

# Ban 网格
grep "ban_orders_replace" /tmp/spot_pre_run.log
```

字段含义：
- `asks=N bids=N` — 本 tick 计划提交的卖单/买单数量
- `trade_price=X` — 网格锚定的成交价
- `ask_ban=true/false bid_ban=true/false` — 哪一侧被 ban

#### 7f. 单步策略订单详情（需 DEBUG 级别日志）
```bash
# plan_update_done 显示每个 strategy step 的计划变更
grep "plan_update_done" /tmp/spot_pre_run.log | tail -20
```

字段含义：
- `sell_add` / `buy_add` — 本 step 计划新增的卖/买单数
- `cancel` — 本 step 计划撤销的订单数
- `keep` — 保留不变的订单数
- `empty=true` — 本 step 无变更（盘口已对齐）
- `force=true` — 强制全量更新触发
- `flash=true` — 闪电更新触发（价差过大）

#### 7g. Reconcile 对盘口的影响
```bash
# 冷启动对账
grep "reconcile_cold_start" /tmp/spot_pre_run.log

# 稳态对账：清理过期/膨胀订单
grep "reconcile_oversized\|reconcile_expired" /tmp/spot_pre_run.log

# 未知订单取消
grep "reconcile_cancel_unknown" /tmp/spot_pre_run.log
```

#### 7h. 网格订单详情
```bash
# special_grid_done 显示 Emergency/Ban 网格的具体价格
grep "special_grid_done" /tmp/spot_pre_run.log | tail -5
```

#### 7i. 限流恢复追踪
```bash
# 限流退避清除
grep "429_backoff_cleared" /tmp/spot_pre_run.log
```

#### 7j. 交易所批次详情（需 DEBUG 级别日志）
```bash
# cancel_add_done 显示每次 cancelAndAdd 批次的接受情况
grep "cancel_add_done" /tmp/spot_pre_run.log | tail -20
```

## 做市行为正常性检查清单

### Phase 0 — Quote Resolution（行情解析）
- [ ] 行情能正常拉取（`quote` 来自 `SPOT_API_HOST`）
- [ ] 非 Emergency 行情时根据仓位的 HedgeBias 选择 Ban/Normal 路径
- [ ] Emergency 行情时走 fallback chain: internal quote → quote_cache → emergency_grid → Skip
- [ ] `ask1` / `bid1` 在 Normal/Ban/Emergency 三种模式下都正确填充（不应出现 `ask1=0 bid1=0`）

### Phase 1 — Order Reconciliation（订单对账）
- [ ] 冷启动 / 每 20 tick 执行一次 reconcile
- [ ] `reconcileColdStart` 发现 unknown step 订单时取消、已知 step 订单种子化
- [ ] `reconcileSteadyState` 检测过期订单（>3× forceUpdateTime）和膨胀订单（>10× gridLevels）并清理

### Phase 2 — Strategy Planning（策略规划）
- [ ] Normal 模式：每个 step 产出 `UpdatePlan`（Reconciler diff target vs liveOrders）
- [ ] Ban 模式：策略单正常规划 + ban 网格通过 `SpecialOrderPlanner` 生成
- [ ] Emergency 模式：仅 emergency 网格，无策略单
- [ ] `minWaitTimeSeconds` 正确隔 tick 调度策略执行（`strategies=0` vs `strategies=N` 交替）
- [ ] Force update 和 Flash update 按时间/价差触发

### Phase 3 — Exchange Submission（交易所提交）
- [ ] `OrderManager::submitTarget` 按模式 dispatch（Normal/Ban/Emergency）
- [ ] `diffSide` 产出正确的 cancel/add 列表（index-matched price comparison）
- [ ] `cancelAndAdd` 成功时 backfill exchange orderId 到 `stepOrders_`
- [ ] 返回 exchange orderId 的订单在下一 tick 能被正确 cancel（不再用空 orderId 撤单）
- [ ] 空 diff 时跳过 exchange 调用

### Phase 4 — Brush Volume（刷量）
- [ ] 仅当 `tradeEnabled` 且 role 允许时执行
- [ ] 限流时自动跳过

### Phase 5 — Order Book Convergence（盘口收敛）
- [ ] **冷启动阶段**：第一个 tick 的 `planned add > 0`（系统需要建立初始盘口）
- [ ] **冷启动阶段**：如果首 tick 被限流（`rate_limit>0`），`executed` 全为 0，盘口延迟到后续 tick 建立
- [ ] **逐步建立**：限流恢复后 `executed add` 一次性提交积压订单，盘口快速到位
- [ ] **稳态收敛**：运行一段时间后 `planned(cxl=0 add=0)` 出现（盘口与目标无差异，无需变更）
- [ ] **稳态波动**：正常行情下 `planned add` 通常为 1-3（微调），不会出现大量重建
- [ ] **Force update**：触发时 `plan_update_done force=true`，盘口全量重建（sell_add/buy_add 较大）
- [ ] **Flash update**：价差突变时 `plan_update_done flash=true`，快速调整盘口
- [ ] **Ban 网格**：Ban 模式触发时 `ban_orders_replace` 日志出现，`ban_update=true` 在 tick_done 中确认
- [ ] **Emergency 网格**：Emergency 模式触发时 `default_grid_orders_replace` 日志出现，`emergency_update=true` 确认
- [ ] **限流下盘口保持**：限流期间 `planned` 持续产出但 `executed` 为 0，盘口未变但计划层不受影响
- [ ] **限流恢复后追赶**：`consecutiveRateLimits_` 清零后，下一个 tick 的 `executed add` 应反映积压的 `planned add`
- [ ] **Reconcile 清理**：reconcile 发现过期/膨胀订单时取消它们（`reconcile_oversized_trim` / `reconcile_expired_trim`），盘口回归正常大小

### 限流处理
- [ ] 429 返回时 `rateLimitHits++`（不是 `rateLimited=true` 被覆盖）
- [ ] 限流后 `tick_done` 的 `executed` 全为 0（未实际执行）
- [ ] 策略层 `planned` 不受限流影响（plan 仍在产出）
- [ ] `consecutiveRateLimits_` 正确累加，`isRateLimited()` 查询正常工作

### 错误处理
- [ ] `requestError` 发生时 `requestErrors++`（`submitStep` / `submitBanGrid` 都会计数）
- [ ] 单步失败不影响其他 step（`!ok` → `co_return` 提前退出）
- [ ] `[cancel_batch_failed]` 是 reconcile 路径的预期行为（交易所 400 表示订单已成交/取消）

### 日志完整性
- [ ] 每个 tick 有且仅有一行 `tick_done`
- [ ] 模式切换有 `mode_transition` 日志
- [ ] Exchange 调用失败有 `order_manager_step_failed` / `order_manager_ban_failed`
- [ ] 策略层有 `step_tick`（DEBUG 级别）和 `plan_update_done`（DEBUG 级别）

## 常见问题及处理

### `ask1=0 bid1=0` 在 Normal 模式
`resolveNormalPath` 可能漏设了 `summary_.ask1/bid1`。在 `summary_.mode = TickMode::Normal` 之后补充赋值。

### `req_err` 始终为 0
检查 `submitStep` / `submitBanGrid` 的 `result.requestError` 分支是否有 `tickSummary_->requestErrors++`。

### `ban_update=false` 但看到了 `ban_orders_replace` 日志
`ban_update` 在 exec layer 设于 `submitBanGrid` 成功后。如果 exchange 返回 429，`submitBanGrid` 提前返回，`ban_update` 不设。这是正确的。

### 预发布环境可能遇到的问题
- **下单成功但成交慢**：pre 环境流动性较低，订单可能长时间挂在盘口未成交。
- **symbol 配置差异**：pre 环境的 `spot_symbol_configs` 表可能和 test 环境不同，确认 `process_group` 列有对应的记录（从 launch.json 的 `DEPLOY_PROCESS` 获取当前分组值）。
- **Redis DB 复用**：pre 环境 Redis DB 0 可能被多个进程共享，注意 key 冲突。

## 评估报告模板

每次运行评估后，按以下模板输出报告。**盘口变化是必填项**。

```markdown
# Spot 预发布环境评估报告

**运行时间**: <开始时间> ~ <结束时间>（共 N 个 tick）
**Symbol**: <symbol>
**日志级别**: INFO / DEBUG
**进程 PID**: <pid>

---

## 1. 总览

| 指标 | 值 | 判定 |
|---|---|---|
| 总 tick 数 | N | — |
| Normal 模式占比 | X% | ✅/⚠️ |
| Ban 模式次数 | N | — |
| Emergency 模式次数 | N | ✅/⚠️ |
| Skip 次数 | N | — |
| 限流 tick 数 / 占比 | N (X%) | ✅/⚠️ |
| request error 总数 | N | ✅/⚠️ |
| Reconcile 执行次数 | N | — |

## 2. 盘口变化

### 2.1 初始盘口（冷启动）

第一个 tick_done:
```
<tick_done 日志原文>
```

- 初始 planned: cxl=**N**, add=**M**
- 初始 executed: cxl=**N**, add=**M**, ok=**M**
- 是否被限流: 是/否
- 判断: 系统需要建立 **M** 个订单的初始盘口 / 盘口从 reconcile 种子化继承

### 2.2 最终盘口（稳态）

最后一个 tick_done:
```
<tick_done 日志原文>
```

- 最终 planned: cxl=**N**, add=**M**
- 最终 executed: cxl=**N**, add=**M**, ok=**M**
- 收敛状态: 已收敛（planned 趋近 0）/ 仍在调整 / 被限流阻塞

### 2.3 盘口建立过程

按时间线描述盘口如何从 0 到稳态：

```
Tick #1  | planned(cxl=0 add=12)  executed(cxl=0 add=12 ok=9)  rate_limit=0 | 首次铺单
Tick #2  | planned(cxl=0 add=0)   executed(cxl=0 add=0 ok=0)   rate_limit=3 | 被限流，盘口未变
Tick #3  | planned(cxl=2 add=5)   executed(cxl=2 add=5 ok=5)   rate_limit=0 | 限流恢复，追赶积压
Tick #4  | planned(cxl=0 add=1)   executed(cxl=0 add=1 ok=1)   rate_limit=0 | 微调
Tick #5  | planned(cxl=0 add=0)   executed(cxl=0 add=0 ok=0)   rate_limit=0 | 盘口收敛 ✅
...
```

关键阶段标注：
- 🔴 冷启动：tick #1 ~ #N
- 🟡 限流阻塞：tick #N ~ #M（rate_limit > 0）
- 🟢 盘口收敛：tick #N 起（planned cxl/add 趋近 0）

### 2.4 限流对盘口的影响

| 指标 | 值 |
|---|---|
| 限流 tick 数 | N |
| 限流期间累计 planned add | M（计划但未提交） |
| 限流恢复后首个 executed add | M（一次性追赶） |
| 最长连续限流 tick | N |
| 限流是否导致盘口落后 | 是/否（落后 N tick） |

限流期间的典型行为：
- tick #N: `planned(cxl=2 add=3) executed(cxl=0 add=0) rate_limit=1` — 计划了但未执行
- tick #N+1: `planned(cxl=0 add=2) executed(cxl=0 add=0) rate_limit=1` — 继续阻塞
- tick #N+2: `planned(cxl=0 add=0) executed(cxl=2 add=5 ok=5) rate_limit=0` — 限流清除，积压一次性提交

（用实际日志替换上面的示例）

### 2.5 网格更新（如有）

Emergency 网格:
```
<default_grid_orders_replace 日志，含 asks/bids 数量变化>
```

Ban 网格:
```
<ban_orders_replace 日志，含 asks/bids 数量变化>
```

## 3. 模式切换

<mode_transition 日志摘录，标注切换原因>

| 切换 | Tick # | 从 → 到 | 原因 |
|---|---|---|---|
| 1 | N | normal → ban | ask_ban 触发 |
| 2 | M | ban → normal | ban 解除 |

## 4. Reconcile

<reconcile 相关日志摘录>

- 冷启动 reconcile: 取消 unknown N 个 / 种子化 known M 个
- 稳态 reconcile: 清理 oversized N 次 / expired M 次

## 5. 异常汇总

| 类型 | 次数 | 典型日志 |
|---|---|---|
| rate_limit（429） | N | — |
| request_error | N | <错误信息> |
| cancel_batch_failed | N | 预期 |
| order_manager_step_failed | N | <错误信息> |
| 其他 ERROR | N | <错误信息> |

## 6. 综合判定

- 做市链路: ✅ 正常 / ⚠️ 有问题（说明）
- 盘口收敛: ✅ 正常（N tick 内收敛）/ ⚠️ 未收敛（原因）
- 限流处理: ✅ 正确（planned 不受影响，executed 正确追赶）/ ⚠️ 有问题
- 模式切换: ✅ 正常 / ⚠️ 异常
- 总体: ✅ 通过 / ⚠️ 需关注

### 建议/备注
- <任何值得注意的发现>
```
