---
name: spot-profiling
description: KCEX Spot 做市系统性能分析。结合 perf 火焰图、Prometheus 指标、自定义埋点、jemalloc 内存分析，端到端诊断 800+ symbol 压力测试瓶颈。自动区分冷启动/稳态阶段，分析 per-symbol per-tick 延迟构成。数据驱动，拒绝臆断。Use when 跑 spot benchmark 压力测试、分析 spot 性能瓶颈、做 profiling 优化循环。
---

<what-to-do>

你是 KCEX Spot 做市系统的性能分析专家。你整合四种信息源——perf 硬件计数器、Prometheus 指标、源码埋点、火焰图——做端到端的性能诊断。**数据驱动，拒绝臆断。** 每个瓶颈推论必须附带 perf 报告、Prometheus 数值、或日志输出作为证据。

## 🚨 最高优先级约束

### quick_start.sh 是管理压测依赖的**唯一入口**

**所有 benchmark 基础设施（MySQL、Redis、mock-api、feed）的启停必须且只能通过 `quick_start.sh` 进行。** 这是硬性约束，没有任何例外。

```bash
# ✅ 唯一允许的命令 — bench
bash /kcex/cpp/spot/dev/quick_start.sh bench start-infra    # 只启 infra，验证通过后返回
bash /kcex/cpp/spot/dev/quick_start.sh bench start-spot     # 编译 + 前台启动 spot（需 infra 已就绪）
bash /kcex/cpp/spot/dev/quick_start.sh bench start          # 启动 infra + 编译 + 前台启动 spot
bash /kcex/cpp/spot/dev/quick_start.sh bench stop-spot      # 停止 spot
bash /kcex/cpp/spot/dev/quick_start.sh bench stop           # 停止 spot + infra（清理全部数据）

# ✅ 唯一允许的命令 — localdev
bash /kcex/cpp/spot/dev/quick_start.sh localdev start-infra
bash /kcex/cpp/spot/dev/quick_start.sh localdev start-spot
bash /kcex/cpp/spot/dev/quick_start.sh localdev start
bash /kcex/cpp/spot/dev/quick_start.sh localdev stop-spot
bash /kcex/cpp/spot/dev/quick_start.sh localdev stop
```

**❌ 以下行为绝对禁止，违反即为错误：**

- `docker compose -f ... up -d` — 手动 compose
- `docker stop <container-id>` / `docker rm <container-id>` — 裸 docker 命令
- `docker run ...` — 手动启动任何容器
- `docker-compose` (v1) — 任何形式的直接 compose 调用
- 任何绕过 `quick_start.sh` 的环境管理操作

### quick_start.sh 失败时的处理规则

**如果 `quick_start.sh` 执行失败：**

1. **立即停止** — 不要尝试绕过它，不要手动修复容器状态
2. **报告错误输出** — 把 quick_start.sh 的完整 stderr/stdout 展示出来
3. **分析根因** — 从 quick_start.sh 日志和 compose logs 中诊断问题
4. **修复 quick_start.sh 或 compose yaml** — 如果脚本本身有 bug，修脚本；如果是环境问题，诊断清楚后给出修复方案
5. **重新运行 quick_start.sh** — 修复后重新执行，直到它成功返回

**绝对不要做的事情：**

- ❌ "quick_start.sh 失败了，我手动 docker compose 启动"
- ❌ "mock-api 不 healthy，我手动 docker restart 一下"
- ❌ "MySQL init 没跑，我手动 docker exec 进去执行 SQL"
- ❌ 任何形式的"绕过 quick_start.sh 先跑起来再说"

**为什么这么严格：** 
- 宿主机跑着其他重要容器，裸 docker 命令有误杀风险
- 绕过 quick_start.sh 的手动修复不具备可复现性，下次还是挂
- quick_start.sh 内置了 4 重验证（MySQL/Redis/Mock API/Feed），手动操作跳过了这些检查
- 之前已经浪费大量 token 在手动 setup 上，这次修好 quick_start.sh 就是为了避免重蹈覆辙

### quick_start.sh 的可靠性保证

当前版本的 quick_start.sh 已经过端到端验证：
- ✅ MySQL 镜像 baked-in init SQL（不依赖 WSL2 bind mount）
- ✅ mock-api 通过 `MOCK_SYMBOLS_LIST` env var 加载 867 symbols（不依赖文件挂载）
- ✅ Docker compose health check 序列化启动（MySQL → Redis → mock-api + feed）
- ✅ 4 重 post-startup 验证（每个组件用实际 API 调用确认功能正常）
- ✅ 命名 volume 可靠清理（`stop` 彻底删除所有数据）
- ✅ 幂等（重复执行不产生副作用）
- ✅ 容器隔离（项目名 `spot-bench`，不会误触其他容器）

如果它失败了，**一定是环境有问题或脚本有 bug** — 不要绕过，修好它。

---

### 只重启 spot，绝不重启 compose（除非 infra 变了）

改动 spot 代码后，只做「编译 + 重启 binary」。**只有以下情况才允许重启 compose：**
1. compose yaml / Dockerfile / mock-api 源码变更
2. MySQL schema 变更（`dev/mysql-init/` 下的 SQL）
3. `.env.bench` / `.env.localdev` 环境变量变更
4. 需要重建 Docker 镜像

**不在以上清单 = 只重启 spot。** compose 重启 ~60s，spot 重启 ~2s。

### 其他关键约束

- **Mock API 必须加载全部 867 symbol** — quick_start.sh 从 MySQL seed SQL 提取 symbol，通过 `MOCK_SYMBOLS_LIST` 环境变量传入 mock-api 容器。如果 mock 只有 13 个默认 symbol，其余 854 个的 position 数据会过期 → 99% tick failure。quick_start.sh 的验证步骤会检查 symbol 数量 >= 100。
- **禁止加编译 flag 绕过错误** — 编译不过直接修代码。
- **改完代码编译+单测全 green 才能进入下一步。**
- **perf_event_paranoid 当前为 2** — 不能用 `--call-graph dwarf`，只能用 `--call-graph fp`。二进制必须用 `-fno-omit-frame-pointer` 编译才能获得完整调用栈。
- **Profiling 构建**: quick_start.sh 自动传递 `-DKCEX_SPOT_PROFILING_BUILD=ON`，CMake 会加 `-fno-omit-frame-pointer -g`。如果手动 cmake（不用 quick_start.sh），必须手动加这个 flag。不用在生产环境开 — frame pointer 有 1-3% 性能开销。

---

## 当前系统状态（来自记忆和最近 benchmark）

### 架构概览

```
kcex-mm-spot (C++)
├─ 874 threads (每 symbol 一个 SymbolRuntime)
├─ tick interval: 500ms (benchmark)
├─ Position cache: 背景线程 0.5s 刷新, shared_lock 零 IO
├─ Prometheus :18083
└─ Phase 分解:
    ├─ resolve_quote: ~20ms P50 (Redis position read + market data + spread calc)
    ├─ update_strategies: ~18ms P50 (└─ strategy_plan <1ms, strategy_execute <1ms)
    └─ reconcile_orders: ~32ms P50 (every 20th tick, └─ reconcile_fetch HTTP 8ms)
mock-api (C++, httplib::Server, ThreadPool(1024)) :18090
MySQL (mariadb:11, :3306)
Redis (redis:7, :6379)
feed (Python, feed_market_data.py) — 合成行情
```

### 现有埋点清单

| 埋点 | 位置 | 测量的东西 |
|---|---|---|
| `observeTick(seconds, success)` | `spot_service_runner.cpp:91` | tick 总延迟（不含 sleep），Prometheus histogram |
| `recordSymbolTick(symbol, seconds)` | `spot_service_runner.cpp:95` | per-symbol tick 累计，内存聚合，每 30s dump top-20 |
| `recordExternalCall("tick.phase", "resolve_quote", ...)` | `spot_service_runner.cpp:109` | Phase 0 耗时 |
| `recordExternalCall("tick.phase", "update_strategies", ...)` | `spot_service_runner.cpp:155` | Phase 1 耗时 |
| `recordExternalCall("tick.phase", "reconcile_orders", ...)` | `spot_service_runner.cpp:156` | Phase 2 耗时（每 20 tick） |
| `recordExternalCall("tick.phase", "strategy_plan", ...)` | `strategy_manager.cpp:360` | buildSideOrders 耗时 |
| `recordExternalCall("tick.phase", "strategy_execute", ...)` | `strategy_manager.cpp:363` | HTTP cancelAndAdd 耗时 |
| `recordExternalCall("tick.phase", "reconcile_fetch", ...)` | `strategy_manager.cpp:238` | HTTP currentOrders 耗时 |
| `recordExternalCall("tick.phase", "reconcile_classify", ...)` | `strategy_manager.cpp:281` | 订单分类耗时 |
| `recordExternalCall("tick.phase", "reconcile_trim", ...)` | `strategy_manager.cpp:283` | 裁剪超限订单耗时 |
| `recordExternalCall("tick.phase", "reconcile_sync", ...)` | `strategy_manager.cpp:285` | 同步 Redis 耗时 |
| `recordPriceFallback(symbol, layer)` | `strategy_manager.cpp:121+` | 价格回退层计数 |
| `recordStrategyUpdate(symbol, step, reason)` | `strategy_manager.cpp:346` | 策略触发计数 |
| `recordOrderPlan(...)` | `strategy_manager.cpp:584` | 订单计划统计 |
| `dumpSymbolTickStats(20)` | `spot_service_runner.cpp:294` | 每 30s 打印 top-20 最慢 symbol |
| `setColdStartComplete()` | `spot_service_runner.cpp:164` | 冷启动完成 gauge |

### 已知埋点盲区

1. **`resolveQuote()` 内部无子相分解** — 无法区分 market data fetch vs position cache read vs spread calc 各占多少。这是 tick 里最大的单一 phase（~27% P50），但内部构成不可见。
2. **没有 per-symbol histogram** — 867 个 symbol 的尾延迟差异被全局 histogram 抹平了。个别 symbol 的 P99 可能很差但全局看不出来。
3. **没有 off-CPU 分析** — HTTP I/O wait 被计入 phase 耗时但无独立的 context-switch/sleep 统计。
4. **没有「慢 tick 详细日志」** — 个别 tick 超过阈值（如 500ms）时没有自动输出完整 phase breakdown 日志。
5. **jemalloc stats 有收集但未写入 CSV** — `startMemoryStatsCollector` 输出到日志但 bench.sh 的 CSV 只抓了 RSS，没抓 alloc/dealloc 速率。

### 已知瓶颈（2026-06-13 867-symbol stress test v5）

| 优先级 | 瓶颈 | 证据 |
|---|---|---|
| 🔴 | `buildSideOrders` CPU 21% (indexAmount + pow) | perf record 867 symbols, 60s |
| 🔴 | `MetricCache::get` 单 mutex, 867 线程竞争 | perf report 2.36% CPU + code review |
| 🟡 | HTTP `reconcile_fetch` 8ms P50, `resolve_quote` 内部 Redis 20ms | Prometheus external_call histogram |
| 🟡 | malloc/free ~15% 累计 (string copy + redis sds + json serialize) | perf report |
| 🟡 | 日志 `writeMoldJson` ~8% (strftime + json) | perf report |
| 🟢 | `resolveQuote()` 内部无子相分解 | instrumentation gap |
| 🟢 | 尾延迟 P99 ~5s（首次 mergeOrderBook） | Prometheus histogram |

---

## 标准分析流程（6 步）

### Step 0: 环境确认

检查 perf 能力和 infra 状态：

```bash
# perf 能力
cat /proc/sys/kernel/perf_event_paranoid  # 当前=2, 限于 fp 调用图
perf --version  # 6.12.90
ls /tmp/FlameGraph/  # 火焰图工具已安装

# infra 状态
curl -s localhost:18083/actuator/prometheus | head -5  # spot 是否在跑
curl -s localhost:18090/health  # mock-api 是否活
ps aux | grep kcex-mm-spot | grep -v grep  # spot PID
```

如果 infra 不活或 spot 不活，用 quick_start.sh 启动。

### Step 1: 宏观性能画像 (perf stat)

在 spot 运行时采集 30-60s：

```bash
SPOT_PID=$(pgrep kcex-mm-spot)
perf stat -d -d -d -p $SPOT_PID -- sleep 60 2>&1 | tee /tmp/perf_stat.txt
```

**必须输出：**
- IPC（<0.7 → 前端/后端停滞；>2.0 → 良好）
- L1 dcache misses%（>5% → 数据访问模式问题）
- LLC misses%（>2% → prefetch 问题）
- branch-misses%（>2% → 无规律分支）
- context-switches（>10k/s → 线程过多或锁竞争）
- CPU migrations

结合 Prometheus 指标做交叉验证：
```bash
curl -s localhost:18083/actuator/prometheus | grep -E \
  'kc_market_mm_tick_seconds_(sum|count)|kc_market_mm_external_call_seconds'
```

### Step 2: 热点定位 (perf record + 火焰图)

采集 CPU cycles 调用图（限制 fp 模式，60s 采样）：

```bash
SPOT_PID=$(pgrep kcex-mm-spot)
perf record -F 99 -g --call-graph fp -p $SPOT_PID -o /tmp/spot_perf.data -- sleep 60

# 生成火焰图
perf script -i /tmp/spot_perf.data | \
  /tmp/FlameGraph/stackcollapse-perf.pl | \
  /tmp/FlameGraph/flamegraph.pl > /tmp/spot_flame.svg

# 同时输出 text report（用于后续分析）
perf report -i /tmp/spot_perf.data --stdio -g > /tmp/perf_report.txt
```

**从 Prometheus 提取 Phase 时间分解：**
```bash
PROM=$(curl -s localhost:18083/actuator/prometheus)
echo "$PROM" | grep 'kc_market_mm_external_call_seconds.*tick\.phase' | \
  awk '{print $1, $2, $NF}'
```

**从日志提取 per-symbol tick stats：**
```bash
grep 'symbol_tick_stats' /kcex/cpp/spot/dev/bench/bench-out/spot.log | tail -10
```

### Step 3: 热点函数深潜 (源码 + 反汇编 + 埋点交叉验证)

对每个 >5% CPU 的热点函数，执行三件事：

a) **完整源码阅读** — 读热点函数完整实现 + 操作的数据结构定义
b) **指令级开销** — `perf annotate -i /tmp/spot_perf.data <function_name>`
c) **埋点上下文化** — 用 Prometheus phase timing 交叉验证 perf 发现

**关键源码文件清单：**
| 文件 | 内容 |
|---|---|
| `spot/adapters/spot_service_runner.cpp` | tick 主循环 + 埋点 |
| `spot/strategy/strategy_manager.cpp` | resolveQuote, updateStrategiesOnce, reconcileOrders |
| `spot/strategy/strategy_base.cpp` | buildSideOrders, planUpdate, indexAmount |
| `spot/adapters/spot_strategy_context.cpp` | exposure, getPosition, emergencyGrid |
| `spot/strategy/order_reconciler.cpp` | 订单对账 |
| `spot/strategy/price_manager.cpp` | 价格判断 |
| `spot/adapters/spot_exchange_client.cpp` | HTTP 客户端 |
| `spot/adapters/spot_market_data_provider.cpp` | 行情数据提供 |
| `cpp-infra/kcex_infra/metrics.hpp` | 埋点 API 定义 |
| `cpp-infra/kcex_infra/metrics.cpp` | 埋点实现 (Prometheus histogram + counter) |

### Step 4: 冷启动 vs 稳态分析

**区分两阶段的指标：**

```bash
# 冷启动完成时间点 (gauge 从 0 → 1)
grep 'cold_start_complete' /kcex/cpp/spot/dev/bench/bench-out/spot.log

# 第一个成功的 per-symbol tick（从 symbol_tick_stats 观察）
grep 'symbol_tick_stats' /kcex/cpp/spot/dev/bench/bench-out/spot.log | head -20

# 首次 mergeOrderBook 耗时（日志中找 startup_merge_current_orders 和 startup_merge_empty）
grep -E 'startup_merge|merge_order_book_failed' /kcex/cpp/spot/dev/bench/bench-out/spot.log | head -30

# Prometheus 中冷启动期间 tick 延迟 vs 稳态
curl -s localhost:18083/actuator/prometheus | grep 'cold_start_complete'
```

**冷启动特有的瓶颈：**
- 首个 mergeOrderBook → currentOrders HTTP 调用（867 线程并发，mock-api 处理）
- Position cache 首次 populate（Redis HGETALL 一次 867 key）
- MySQL 连接池 warmup

**稳态瓶颈**（冷启动完成后持续存在）：
- buildSideOrders CPU
- resolveQuote 内 Redis GET + JSON parse
- reconcile（每 20 tick）HTTP currentOrders
- Metrics mutex 竞争

### Step 5: 生成优化方案与风险评估

对每个瓶颈，必须给出：
1. **具体代码修改**（diff 格式）
2. **解决的微架构问题**（引 Step 3 的 perf/disasm 证据）
3. **预期收益**（具体的 Prometheus 指标预期变化方向和量级）
4. **风险**（可读性、不同编译器退变、线程安全）

### Step 6: 验证与迭代

```bash
# 1. 应用优化后编译
cd /kcex/cpp/spot/build-bench && ninja -j$(nproc)

# 2. 只重启 spot
kill $(pgrep kcex-mm-spot) 2>/dev/null; sleep 1
./kcex-mm-spot --config ../../dev/config/bench.yaml --loop --interval-ms 500 > /kcex/cpp/spot/dev/bench/bench-out/spot.log 2>&1 &

# 3. 等 Prometheus 就绪
until curl -s localhost:18083/actuator/prometheus >/dev/null 2>&1; do sleep 1; done

# 4. 重跑 perf record + 收集指标

# 5. 用 perf diff 对比
perf diff /tmp/spot_perf_before.data /tmp/spot_perf_after.data

# 6. 对比 Prometheus histogram quantiles
```

---

## 全量 867+ symbol Stress Test 标准流程

### 一键启动（推荐）

```bash
# 一键启动 infra + spot
bash /kcex/cpp/spot/dev/quick_start.sh bench start

# 或只启 infra（AI 自行管理 spot 编译+重启）
bash /kcex/cpp/spot/dev/quick_start.sh bench start-infra
```

quick_start.sh 自动完成：生成 867 symbol 列表 → 启动 MySQL（seed SQL 初始化）→ Redis → mock-api（867 symbols 加载）→ feed（合成行情）→ 四重验证通过后返回。不用任何手动干预。

### AI 只重启 spot（节约时间）

```bash
# 编译
cd /kcex/cpp/spot/build-bench && ninja -j$(nproc)

# 只重启 spot
kill $(pgrep kcex-mm-spot) 2>/dev/null; sleep 1
cd /kcex/cpp/spot
./build-bench/kcex-mm-spot --config dev/config/bench.yaml --loop --interval-ms 500 \
  > dev/bench/bench-out/spot.log 2>&1 &
```

### 同时运行 perf + 指标收集（60s）

```bash
SPOT_PID=$(pgrep kcex-mm-spot)
OUTDIR="/kcex/cpp/bench-reports"

# 并行采集：perf stat + perf record + Prometheus snapshot
perf stat -d -d -d -p $SPOT_PID -- sleep 60 2>&1 | tee "$OUTDIR/$(date +%Y-%m-%d)-perf-stat.txt" &
PID_STAT=$!

perf record -F 99 -g --call-graph fp -p $SPOT_PID \
  -o "$OUTDIR/$(date +%Y-%m-%d)-perf.data" -- sleep 60 &
PID_REC=$!

# Prometheus 快照（前后各一次）
curl -s localhost:18083/actuator/prometheus > "$OUTDIR/$(date +%Y-%m-%d)-prom-before.txt"
wait $PID_STAT $PID_REC
curl -s localhost:18083/actuator/prometheus > "$OUTDIR/$(date +%Y-%m-%d)-prom-after.txt"

# 火焰图
perf script -i "$OUTDIR/$(date +%Y-%m-%d)-perf.data" | \
  /tmp/FlameGraph/stackcollapse-perf.pl | \
  /tmp/FlameGraph/flamegraph.pl > "$OUTDIR/$(date +%Y-%m-%d)-flame.svg"

# 保存 per-symbol tick stats
grep 'symbol_tick_stats' /kcex/cpp/spot/dev/bench/bench-out/spot.log | tail -20 \
  > "$OUTDIR/$(date +%Y-%m-%d)-symbol-stats.txt"
```

### 正常做市验证（9 项条件）

Benchmark 跑完后必须逐项检查。从 `[[benchmark-normal-mm-definition]]` 继承：

```bash
# 简化版一键验证
PROM=$(curl -s localhost:18083/actuator/prometheus)
LOG=/kcex/cpp/spot/dev/bench/bench-out/spot.log

echo "$PROM" | grep 'kc_market_mm_tick_seconds_count.*success="true"' | awk '{print "✓ ticks ok:", $NF}'
echo "$PROM" | grep 'kc_market_mm_tick_seconds_count.*success="false"' | awk '{print "✗ ticks fail:", $NF}'
echo "$PROM" | grep 'kc_market_mm_exchange_action_total.*cancel_add.*result=requested' | awk '{if($NF>0) print "✓ orders submitted:", $NF; else print "✗ no orders"}'
grep -c 'execute_plan_done' "$LOG" | awk '{if($1>10) print "✓ plans executed:", $1; else print "✗ no plans"}'
grep -c 'reconcile_orders.*orders=[1-9]' "$LOG" | awk '{if($1>0) print "✓ reconcile sees orders:", $1; else print "✗ no reconcile"}'
grep -c 'emergency' "$LOG" | awk '{if($1==0) print "✓ no emergency"; else print "✗ emergency:", $1}'
grep -c 'price_ban_mode' "$LOG" | awk '{if($1==0) print "✓ no ban"; else print "✗ ban:", $1}'
```

---

## 埋点盲区补充指南

当你发现以下盲区阻碍分析时，**主动建议加埋点**（并给出具体 diff）：

### 盲区 #1: resolveQuote() 内部无子相

当前只有一个 `recordExternalCall("tick.phase", "resolve_quote", total, true)`，无法区分：
- `marketData_.quote(symbol)` — 从 market data store 取行情（shared_ptr deref，极快）
- `context_.exposure(symbol)` — position cache read（shared_lock + unordered_map find）
- `applySpreadWeight()` — spread 计算（纯 CPU）

**建议埋点：** 在 `strategy_manager.cpp` 的 `resolveQuote()` 中加三个子相计时，参考已有 `reconcile_orders` 的子相分解模式。

### 盲区 #2: 慢 tick 无自动详细日志

个别 tick 超过阈值（如 500ms）时，没有自动输出完整 phase breakdown。

**建议埋点：** 在 `SymbolRuntime::tick()` 的 Guard 析构中加阈值检查：`if (elapsed > config.slowTickThreshold) { log full breakdown }`。

### 盲区 #3: jemalloc stats 未进 CSV

`startMemoryStatsCollector` 输出的 alloc/dealloc 速率只在日志，bench.sh 只抓了 RSS。

**建议：** 加 Prometheus gauge `kc_market_mm_jemalloc_allocated_bytes` 和 `kc_market_mm_jemalloc_active_bytes`。

### 盲区 #4: HTTP 请求无 latency histogram

当前 `reconcile_fetch` 和 `strategy_execute` 被塞进了通用的 `external_call` histogram，与 Redis 请求混在一起。

**建议：** 单独暴露 `kc_market_mm_http_request_seconds` histogram。

---

## Loop 模式（自动 profiling → 分析 → 优化循环）

当用户要求自动优化循环时，按以下流程：

```
┌──────────────────────────────────────────────────────┐
│  1. 确认 infra 状态（quick_start.sh status）          │
│     ├─ infra 不活? → quick_start.sh bench start-infra    │
│     └─ infra 活? → next                               │
├──────────────────────────────────────────────────────┤
│  2. 编译 spot（Release + Prometheus + jemalloc）       │
│     cd build-bench && ninja -j$(nproc)                │
├──────────────────────────────────────────────────────┤
│  3. 重启 spot（只 restart binary，不动 compose）       │
│     kill old → start new → wait Prometheus             │
├──────────────────────────────────────────────────────┤
│  4. 跑 60s perf stat + perf record + Prometheus 快照  │
│     生成火焰图 + per-symbol stats dump                 │
├──────────────────────────────────────────────────────┤
│  5. 分析瓶颈（Step 1-4 的完整流程）                    │
│     ├─ 宏观: IPC, cache miss, context switch          │
│     ├─ 热点: 火焰图 top-N 函数                        │
│     ├─ 相位: Prometheus phase timing                  │
│     ├─ 符号: per-symbol tick stats (top-20 slowest)   │
│     └─ 阶段: 冷启动 vs 稳态                            │
├──────────────────────────────────────────────────────┤
│  6. 读热点函数源码 + perf annotate + 交叉验证埋点      │
├──────────────────────────────────────────────────────┤
│  7. 判断: 有瓶颈且可优化?                              │
│     ├─ YES → 8. 生成优化方案(diff) → 9. 应用 → goto 2  │
│     └─ NO  → 10. 生成最终报告 → 持久化                  │
└──────────────────────────────────────────────────────┘
```

**循环终止条件：**
- 所有 >5% CPU 的热点都没有可行的优化方案（ROI 不如风险）
- 或 P50 tick < 20ms 且 P99 < 100ms（"足够快"阈值，可根据用户需求调整）
- 或连续 2 轮优化后 IPC 提升 <5%

---

## 性能报告持久化

每次 profiling 结束必须将以下文件保存到 `/kcex/cpp/bench-reports/`：

| 文件 | 命名格式 | 内容 |
|---|---|---|
| 综合报告 | `YYYY-MM-DD-spot-profiling-N.md` | Phase timing, 瓶颈分析, 优化建议, perf stat 摘要 |
| perf data | `YYYY-MM-DD-perf.data` | perf record 原始数据 |
| 火焰图 SVG | `YYYY-MM-DD-flame.svg` | 火焰图 |
| perf stat | `YYYY-MM-DD-perf-stat.txt` | perf stat 输出 |
| prometheus 快照 | `YYYY-MM-DD-prom-snapshot.txt` | 完整 Prometheus 指标 |
| symbol stats | `YYYY-MM-DD-symbol-stats.txt` | per-symbol tick stats dump |

同时更新 `/kcex/cpp/spot/dev/BENCHMARK.md` 的「已知瓶颈 / 改进记录」部分，记录本轮发现和改动。

---

## 关键 Prometheus 指标速查

| 指标名 | 含义 | 分析用途 |
|---|---|---|
| `kc_market_mm_tick_seconds_count{success="true"}` | 成功 tick 数 | throughput |
| `kc_market_mm_tick_seconds_count{success="false"}` | 失败 tick 数 | 健康检查 |
| `kc_market_mm_tick_seconds_bucket` | tick 延迟分桶 | 分位数（P50/P90/P99） |
| `kc_market_mm_tick_seconds_sum` | tick 总耗时 | 与 count 算 avg |
| `kc_market_mm_external_call_seconds_count{component="tick.phase"}` | phase 调用次数 | 各 phase 触发频率 |
| `kc_market_mm_external_call_seconds_bucket{component="tick.phase"}` | phase 延迟分桶 | phase 级尾延迟 |
| `kc_market_mm_external_call_seconds_sum{component="tick.phase"}` | phase 总耗时 | 与 count 算 avg |
| `kc_market_mm_strategy_update_count` | 策略触发计数 | force/cross/flash 分布 |
| `kc_market_mm_price_fallback_count` | 价格回退层命中 | emergency_entry/internal/quote_cache/emergency_grid/exhausted |
| `kc_market_mm_exchange_action_total` | exchange HTTP 调用 | cancel_add/open_orders 成功率 |
| `kc_market_mm_cold_start_complete` | 冷启动完成 gauge | 0=冷启动期, 1=稳态 |
| `kc_market_mm_manager_count` | 活跃 symbol 数 | 等于 thread count |
| `kc_market_mm_order_plan_count` | order plan 执行计数 | 订单吞吐 |

---

## 内存 Profiling

### jemalloc stats（已内置）

```bash
# spot 二进制用 jemalloc 链接时，KCEX_ENABLE_JEMALLOC=ON
# memoryStatsCollector 每 N 秒输出到日志:
grep 'memory_stats' /kcex/cpp/spot/dev/bench/bench-out/spot.log | tail -10
```

### RSS/线程数监控

```bash
SPOT_PID=$(pgrep kcex-mm-spot)
echo "RSS: $(awk '/VmRSS/{print $2/1024 " MB"}' /proc/$SPOT_PID/status)"
echo "Threads: $(awk '/Threads/{print $2}' /proc/$SPOT_PID/status)"
echo "voluntary ctxt: $(awk '/voluntary/{print $2}' /proc/$SPOT_PID/status)"
echo "nonvoluntary ctxt: $(awk '/nonvoluntary/{print $2}' /proc/$SPOT_PID/status)"
```

---

## Off-CPU / 上下文切换分析

```bash
SPOT_PID=$(pgrep kcex-mm-spot)

# 所有线程的上下文切换总和
for tid in /proc/$SPOT_PID/task/*; do
  grep -E 'voluntary|nonvoluntary' $tid/status
done | awk '{s+=$2} END {print "total switches:", s}'

# 实时监控切换速率
perf stat -e context-switches -p $SPOT_PID -- sleep 10

# off-CPU 记录（看哪些线程在等什么）
perf record -e sched:sched_switch -g -p $SPOT_PID -o /tmp/spot_offcpu.data -- sleep 30
```

---

## 输出规范

每次分析必须包含：
1. **当前阶段**：Step 0-6 的哪一步
2. **已确认发现**：基于数据的客观事实（引用 perf/Prometheus/log 的具体数值）
3. **暂存假设**：用"推测"或"假设"开头，注明待验证
4. **下一步行动**：精确的命令或代码文件

**🚨 每次 profiling 报告必须包含以下两张表：**

### 表 A: 每轮 Tick 表现（从 Prometheus tick histogram 计算）

必须列出 P10/P25/P50/P75/P90/P95/P99/P99.9 分位延迟：

| 分位 | 延迟 | 解读 |
|---|---|---|
| P10 | Xms | 最快 10% |
| P25 | Xms | |
| **P50** | **Xms** | 中位数，典型体验 |
| P75 | Xms | |
| P90 | Xms | 大部分用户体验 |
| **P95** | **Xms** | 尾延迟警戒线 |
| **P99** | **Xms** | 几乎最差情况 |

数据来源：`kc_market_mm_tick_seconds_bucket` histogram buckets，total count = `_count`。

### 表 B: 稳态每 Tick 时间花在哪里（Phase 分解）

必须列出每个 phase 的 avg/P50/P95 耗时和占总 tick 的比例：

| Phase | Avg | P50 | P95 | 占 Tick% | 说明 |
|---|---|---|---|---|---|
| `resolve_quote` | Xms | Xms | Xms | X% | Redis GET + market data + spread calc |
| `update_strategies` | Xms | Xms | Xms | X% | 策略更新 |
| └─ `strategy_plan` | Xms | Xms | Xms | X% | buildSideOrders (纯 CPU) |
| └─ `strategy_execute` | Xms | Xms | Xms | X% | HTTP cancelAndAdd |
| `reconcile_orders` | Xms | Xms | Xms | X% | 每 20 tick 执行一次 |
| └─ `reconcile_fetch` | Xms | Xms | Xms | X% | HTTP currentOrders |
| └─ `reconcile_classify` | Xms | Xms | Xms | X% | 订单分类 |
| └─ `reconcile_trim` | Xms | Xms | Xms | X% | 裁剪超限订单 |
| └─ `reconcile_sync` | Xms | Xms | Xms | X% | 同步 Redis |
| **Total tick** | **Xms** | **Xms** | **Xms** | **100%** | 不含 tick 间 sleep |

数据来源：`kc_market_mm_external_call_seconds_bucket{component="tick.phase"}` 各 operation 的 histogram buckets。

> **注意**: `reconcile_orders` 每 20 tick 才真正执行 HTTP fetch。`_count` 约为主 phase 的 1/20。Avg 计算要区分"每次调用"vs"均摊到每 tick"。

### 🚨 必须区分冷启动阶段和稳定运行阶段

每次 profiling 报告必须**将结果拆分为两个阶段**，明确指出哪个阶段拖慢了整体效率：

**冷启动阶段**（从启动到 `kc_market_mm_cold_start_complete` 变为 1）：
- 来源：日志中的 `startup_merge_empty` / `startup_merge_current_orders` 事件
- 时长：通常 <10s（867 个 symbol 的首次 mergeOrderBook）
- 判定标准：`grep 'cold_start_complete' spot.log` 找到时间戳
- 需要报告：
  - 冷启动总时长（第一个 tick 到 cold_start_complete）
  - 是否是首次 mergeOrderBook 导致的长尾（个别 symbol 可达 30s+）
  - 冷启动期间的 tick 成功率

**稳定运行阶段**（cold_start_complete=1 之后）：
- 来源：Prometheus histogram（累计，需减去冷启动部分）+ per-symbol stats 窗口
- 需要报告表 A（tick 分位）和表 B（phase 分解）
- **必须注明**：稳定运行期间是否有随时间退化（对比多个 30s 窗口的 global_avg 和 active symbol 数）
- 如果出现退化（global_avg 上升、active symbol 下降），必须分析原因

**判定哪个阶段拖慢整体**：
- 冷启动占比 = 冷启动时长 / 总运行时长。如果 <10%，冷启动不是瓶颈
- 如果 P99 远大于 P50（>50x），通常是冷启动尾部的个别大延迟，或者是稳定阶段的 HTTP 拥塞
- 从 per-symbol stats 窗口判断：如果第一个窗口的 global_avg 已经很高且持续上升 → 稳定阶段有问题；如果第一个窗口低后续上升 → 系统随时间退化

最终报告格式：
- 瓶颈总结（按 🔴🟡🟢 分级）
- 关键证据（perf output snippet + 源码片段 + Prometheus 数值）
- 优化方案（diff + 预期收益 + 风险）
- 验证命令

</what-to-do>

<supporting-info>

## 快速参考

### 命令备忘

```bash
# ── 容器管理（唯一入口：quick_start.sh）──
bash /kcex/cpp/spot/dev/quick_start.sh bench start-infra    # 只启 infra，验证通过后返回
bash /kcex/cpp/spot/dev/quick_start.sh bench start-spot     # 编译 + 前台启动 spot（需 infra 已就绪）
bash /kcex/cpp/spot/dev/quick_start.sh bench start          # infra + 编译 + 前台启动 spot
bash /kcex/cpp/spot/dev/quick_start.sh bench stop-spot      # 停止 spot
bash /kcex/cpp/spot/dev/quick_start.sh bench stop           # 停止 spot + infra（清理全部数据）
bash /kcex/cpp/spot/dev/quick_start.sh localdev start-infra  # localdev 同理
bash /kcex/cpp/spot/dev/quick_start.sh localdev start-spot
bash /kcex/cpp/spot/dev/quick_start.sh localdev start
bash /kcex/cpp/spot/dev/quick_start.sh localdev stop-spot
bash /kcex/cpp/spot/dev/quick_start.sh localdev stop
# ⚠️ 以上是唯一允许的容器管理命令。quick_start.sh 失败 → 停止 → 修脚本 → 重试。
# ⚠️ 绝对禁止手动 docker compose / docker stop / docker rm。

# ── 编译 + 重启 spot ──
cd /kcex/cpp/spot/build-bench && ninja -j$(nproc)
kill $(pgrep kcex-mm-spot) 2>/dev/null; sleep 1
cd /kcex/cpp/spot
./build-bench/kcex-mm-spot --config dev/config/bench.yaml --loop --interval-ms 500 \
  > dev/bench/bench-out/spot.log 2>&1 &

# ── Prometheus 健康 ──
curl -s localhost:18083/actuator/prometheus | grep 'kc_market_mm_tick_seconds_count'

# ── Perf ──
SPOT_PID=$(pgrep kcex-mm-spot)
perf stat -d -d -d -p $SPOT_PID -- sleep 60
perf record -F 99 -g --call-graph fp -p $SPOT_PID -o /tmp/spot_perf.data -- sleep 60
perf report -i /tmp/spot_perf.data --stdio -g

# ── 火焰图 ──
perf script -i /tmp/spot_perf.data | /tmp/FlameGraph/stackcollapse-perf.pl | /tmp/FlameGraph/flamegraph.pl > /tmp/flame.svg

# ── per-symbol tick stats ──
grep 'symbol_tick_stats' /kcex/cpp/spot/dev/bench/bench-out/spot.log | tail -5

# ── 冷启动完成 ──
grep 'cold_start_complete' /kcex/cpp/spot/dev/bench/bench-out/spot.log
```

### Perf 环境约束

- `perf_event_paranoid = 2` → 只能用 `--call-graph fp`，不能 dwarf
- 这意味着**编译必须启用 frame pointer**：CMake 默认 `-fomit-frame-pointer`，spot 的 CMakeLists.txt 可能需要加 `-fno-omit-frame-pointer` 才能获得完整调用栈
- `perf annotate` 需要二进制带 debug symbols（Release + `-g` 或在 `RelWithDebInfo` 模式）

### 火焰图工具路径

- `/tmp/FlameGraph/` — Brendan Gregg 的 FlameGraph 套件
- `/tmp/FlameGraph/stackcollapse-perf.pl`
- `/tmp/FlameGraph/flamegraph.pl`

### 源码路径映射

| 抽象 | 文件 |
|---|---|
| tick 主循环 | `spot/adapters/spot_service_runner.cpp` |
| resolveQuote | `spot/strategy/strategy_manager.cpp:78-181` |
| updateStrategiesOnce | `spot/strategy/strategy_manager.cpp:317-367` |
| reconcileOrders | `spot/strategy/strategy_manager.cpp:226-299` |
| buildSideOrders | `spot/strategy/strategy_base.cpp` |
| exposure/position | `spot/adapters/spot_strategy_context.cpp` |
| priceManager | `spot/strategy/price_manager.cpp` |
| exchange HTTP | `spot/adapters/spot_exchange_client.cpp` |
| market data | `spot/adapters/spot_market_data_provider.cpp` |
| metrics 实现 | `cpp-infra/kcex_infra/metrics.cpp` |
| mock API | `spot/dev/mock-cpp/main.cpp` |

### 构建选项

```
CMAKE_BUILD_TYPE=Release
KCEX_ENABLE_PROMETHEUS=ON
KMM_ENABLE_MYSQL=ON
KCEX_ENABLE_JEMALLOC=ON        # 推荐
USE_EMBEDED_MARKET_MODULE=ON
```

### Build directory

`spot/build-bench/` — 由 quick_start.sh 自动创建和管理。

### 报告目录

`/kcex/cpp/bench-reports/` — 所有 profiling 产物归档至此。

### 🧹 报告目录清理规则

**每次 profiling 开始前（Step 0），必须执行清理评估：**

1. **保留**：最近一次成功的综合报告（`*-spot-profiling-*.md`）及其对应的 perf.data、火焰图 SVG
2. **删除**：
   - 超过 7 天的所有产物（perf.data、火焰图、Prometheus 快照、perf stat）
   - 当天的零散中间文件（prom-before/after 快照、临时 perf.data 等）——只保留 1 份当天最终版本
   - 0 字节的空文件
3. **永远不删**：BENCHMARK.md、skill 文件、源码文件

清理命令参考：
```bash
OUTDIR="/kcex/cpp/bench-reports"

# 删除超过 7 天的旧文件
find "$OUTDIR" -type f -mtime +7 -delete

# 删除 0 字节空文件
find "$OUTDIR" -type f -size 0 -delete

# 如果当天产物超过 1 组，只保留最新的一组
# (perf.data + flame.svg + perf-stat.txt + prom-snapshot.txt 算一组)
TODAY=$(date +%Y-%m-%d)
for suffix in perf.data flame.svg perf-stat.txt; do
  files=$(ls -t "$OUTDIR/$TODAY"*"$suffix" 2>/dev/null)
  count=$(echo "$files" | wc -l)
  if [ "$count" -gt 1 ]; then
    echo "$files" | tail -n +2 | xargs rm -f
  fi
done
```

**🚨 此清理必须在每次 profiling 的 Step 0 执行。** 不清理会浪费磁盘空间（perf.data 单个可达 3MB+，Prometheus 快照可达 2MB+），且文件多了之后难以区分哪组是有效结果。

### BENCHMARK.md

`/kcex/cpp/spot/dev/BENCHMARK.md` — 每次 profiling 后更新「已知瓶颈 / 改进记录」部分。

### 关联 Skill

- `cpp-profiling` — 通用 Linux C++ perf 分析流程，本 skill 在此基础上针对 spot 定制
- `code-review-skill` — 修改代码后做 review
- `rigorous-test` — 修改后需要补测试时调用

### 关联 Memory (来自 /root/.claude/projects/-kcex-cpp/memory/)

- `[[benchmark-normal-mm-definition]]` — 正常做市的 9 项必要条件
- `[[benchmark-only-restart-spot]]` — 只重启 spot，不动 compose
- `[[mock-api-must-have-all-symbols]]` — Mock API 必须加载全部 867 symbol
- `[[bench-reports-dir]]` — benchmark 报告存档目录
- `[[benchmark-doc]]` — BENCHMARK.md 维护规则
- `[[local-dev-benchmark-baseline]]` — Local Dev 和 Benchmark 基准验收标准
- `[[no-compile-flags-workaround]]` — 禁止编译 flag 绕过 + 编译单测全过
- `[[infra-submodule-track-vito-dev]]` — cpp-infra 子模块追踪 vito/dev 分支
- `[[no-auto-commit]]` — 改完代码等用户主动要求才能提交

</supporting-info>
