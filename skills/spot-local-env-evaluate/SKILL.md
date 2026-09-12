---
name: spot-local-env-evaluate
description: 启动 KCEX Spot 连接本地开发环境（Docker Compose + Mock API），观察做市行为和订单管理，检查限流/铺单/模式切换是否正常
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - TaskCreate
  - TaskUpdate
  - TaskList
  - Agent
  - Skill
  - SendMessage
---

# Spot Local Env Evaluate

启动 KCEX Spot C++ 做市系统连接本地开发环境（Docker Compose 管理全部服务），
运行几分钟，检查做市链路是否正常：行情解析 → 模式切换 → 策略铺单 → Mock API 提交 → reconcile。

## 强约束：启停必须走 quick_start.sh

**Infra 和 Spot 的启动/停止只能通过 `./dev/quick_start.sh localdev` 完成。**
不允许绕过它直接调 `docker compose`、`make`、`cmake`、`pkill` 或任何裸命令。

如果 `quick_start.sh` 报错：
1. 停下来，不要尝试自己去修
2. 把错误信息原文报告给用户
3. 让用户决定如何处理

## 强约束：编译只能走 build.sh debug

**代码编译只能通过 `bash build.sh debug` 完成，严禁手动调用 `cmake`、`make`、`g++` 等任何裸编译命令。**

原因：
- `build.sh debug` 会显式设置 `CC=/usr/bin/gcc-14`、`CXX=/usr/bin/g++-14`（GCC 14.2），避免 WSL2 上 `/usr/local/bin` 的 GCC 14.3 误报
- 手动 `cmake ..` 会用系统默认编译器，可能与 build.sh 不一致，导致缓存污染、误报甚至构建失败
- 如果有编译问题，停下来报告用户，不要自己绕过 build.sh

## 程序启动方式

```bash
# 1. 启动 infra（MySQL + Redis + Mock API + Mock C++）
cd /kcex/cpp/spot
./dev/quick_start.sh localdev start-infra

# 2. 构建 + 前台启动 spot
#    （自动 Debug 构建，config=dev/config/local-dev.yaml，interval=3000ms）
./dev/quick_start.sh localdev start-spot > /tmp/spot_localdev_run.log 2>&1 &
```

### 关键信息

| 项目 | 值 |
|---|---|
| 配置文件 | `dev/config/local-dev.yaml` |
| 构建类型 | Debug |
| 构建目录 | `build-debug/` |
| Exchange API | `http://127.0.0.1:18090`（Mock API） |
| MySQL | 127.0.0.1:3306, quant/quant/quant |
| Redis | 127.0.0.1:6379, db=2, password=redis123 |
| Prometheus | 无（`PROMETHEUS_PORT: 0`） |
| Mock C++ | `dev/mock-cpp/`，处理下单/撤单请求 |
| Symbol | BTC-USDT（localdev 默认只激活这一个） |
| Tick 间隔 | 3000ms（BTC-USDT `min_wait_time` 被 quick_start.sh 设为 3s） |

### 与 test-env / pre-env 的关键差异

| 维度 | localdev | test-env |
|---|---|---|
| 服务位置 | Docker Compose（全部本地） | 远程 RDS / Redis / Exchange |
| 下单目标 | Mock C++ API | 真实测试交易所 |
| Symbol 数 | 1（BTC-USDT） | N（按 MySQL 配置） |
| 行情源 | Redis Feed（Binance WS trades） | Redis Feed（test env） |
| 启动方式 | `quick_start.sh localdev` | 环境变量 + 裸 binary |
| 是否需要 proxy | 否 | 可能需要 proxychains |

## 观察方法

### 1. 启动确认
```bash
# 等待进程启动并加载 symbol
until grep -q "tick_done" /tmp/spot_localdev_run.log 2>/dev/null; do sleep 3; done
echo "Spot started — first tick_done seen"
```

### 2. tick_done 汇总日志（每个 tick 一行）
```bash
grep "tick_done" /tmp/spot_localdev_run.log | tail -10
```

日志字段含义（与 test-env 相同，参见 spot-test-env-evaluate skill）。

### 3. 模式切换
```bash
grep "mode_transition\|price_ban_mode\|price_default_grid_mode" /tmp/spot_localdev_run.log | tail -10
```

### 4. Reconcile 行为
```bash
grep "reconcile\|openOrders" /tmp/spot_localdev_run.log | tail -10
```

### 5. 错误和异常
```bash
grep "ERROR\|WARNING" /tmp/spot_localdev_run.log | tail -20
```

### 6. 盘口状态

与 spot-test-env-evaluate 中相同的盘口观察方法：

```bash
# 盘口变化时间线
grep "tick_done" /tmp/spot_localdev_run.log | \
  grep -oP 'planned\([^)]+\) executed\([^)]+\) rate_limit=\d+'

# 首次 tick（冷启动盘口）
grep "tick_done" /tmp/spot_localdev_run.log | head -3

# 最后几个 tick（稳态盘口）
grep "tick_done" /tmp/spot_localdev_run.log | tail -5

# Grid 网格更新
grep "special_grid_done\|default_grid_orders_replace\|ban_orders_replace" /tmp/spot_localdev_run.log

# Reconcile 对盘口的影响
grep "reconcile_cold_start\|reconcile_oversized\|reconcile_expired\|reconcile_cancel_unknown" /tmp/spot_localdev_run.log

# Mock API 交互（cancel/add 结果）
grep "cancel_add_done\|add_done\|cancel_done" /tmp/spot_localdev_run.log | tail -20
```

### 7. 日志级别调整（运行时）
```bash
# spot 必须用 LOG_LEVEL=DEBUG 启动才支持 /loglevel endpoint（LOG_HISTORY=1）
# 如果启动时未设 LOG_HISTORY=1，需要重新启动
```

## 做市行为正常性检查清单

### Phase 0 — Infra 就绪
- [ ] MySQL 连接正常，`spot_symbol_configs` 表有 BTC-USDT
- [ ] Redis 连接正常，`PING` 返回 `PONG`
- [ ] Mock API health endpoint 可访问（`http://127.0.0.1:18090/health`）

### Phase 1 — 行情解析
- [ ] 行情能从 Redis Feed 正常拉取（`tick_done` 中 `ask1 > 0, bid1 > 0`）
- [ ] 非 Emergency 行情时根据 HedgeBias 选择 Ban/Normal 路径
- [ ] Emergency 行情时走 fallback chain → emergency_grid → Skip

### Phase 2 — 订单对账（Reconcile）
- [ ] 冷启动 reconcile 正常执行
- [ ] Mock API 返回的 `currentOrders` 被正确解析

### Phase 3 — 策略规划
- [ ] Normal 模式：每个 step 产出 `UpdatePlan`
- [ ] 3s tick 间隔下，`strategies` 在每个 tick 都参与规划（不会因 minWaitTime 跳过）
- [ ] `minWaitTimeSeconds` 调度正常

### Phase 4 — Mock API 提交
- [ ] 订单通过 `cancelAndAdd` 提交到 Mock API
- [ ] Mock API 返回 `placeResult` 且 `accepted > 0`
- [ ] exchange orderId 被正确回填
- [ ] 空 diff 时跳过 exchange 调用

### Phase 5 — 盘口收敛
- [ ] 冷启动阶段：首个 tick `planned add > 0`（建立初始盘口）
- [ ] 稳态收敛：`planned(cxl=0 add=0)` 出现（盘口对齐）
- [ ] Mock API 的 cancelResult 被正确记录

## 停止方法

```bash
# 停止 spot + infra（清理全部数据）
./dev/quick_start.sh localdev stop
```

如果想保留 infra（仅重启 spot）：
```bash
./dev/quick_start.sh localdev stop-spot
```

## 常见问题

### `quick_start.sh` 报错 "Infra is not running"
先执行 `start-infra`，再执行 `start-spot`。

### MySQL 表为空
quick_start.sh 的 `localdev start-infra` 不执行 `activate all symbols`（那是 bench 模式的特有逻辑）。
localdev 只有 BTC-USDT 在 seed SQL 中默认 `all_open=1`。如果 BTC-USDT 也不在，检查 seed SQL。

### Mock API 返回空数据
Mock API 在 `quick_start.sh` 中通过 docker compose 启动，symbol 列表由 mock_symbols 相关配置自动处理。

### 判断 spot 是否正在运行
```bash
pgrep -f "kcex[-_]mm[-_]spot"
```

### spot 启停异常
不要自己用 `kill`、`pkill`、`docker compose down`。始终用：
```bash
./dev/quick_start.sh localdev stop-spot   # 仅停 spot
./dev/quick_start.sh localdev stop        # 停 spot + infra
```

如果 `quick_start.sh` 启停失败，停下来报告问题。

## 评估报告模板

每次运行评估后，按以下模板输出报告。**盘口变化是必填项**。

```markdown
# Spot 本地环境评估报告

**运行时间**: <开始时间> ~ <结束时间>（共 N 个 tick）
**Symbol**: BTC-USDT
**日志级别**: INFO
**日志文件**: /tmp/spot_localdev_run.log

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
- 判断: 系统需要建立 **M** 个订单的初始盘口

### 2.2 最终盘口（稳态）

最后一个 tick_done:
```
<tick_done 日志原文>
```

- 最终 planned: cxl=**N**, add=**M**
- 最终 executed: cxl=**N**, add=**M**, ok=**M**
- 收敛状态: 已收敛 / 仍在调整

### 2.3 盘口建立过程

按时间线描述盘口从 0 到稳态：

```
Tick #1  | planned(cxl=0 add=6)  executed(cxl=0 add=6 ok=6)  rate_limit=0 | 首次铺单
Tick #2  | planned(cxl=0 add=0)  executed(cxl=0 add=0 ok=0)  rate_limit=0 | 盘口收敛 ✅
...
```

### 2.4 Mock API 交互统计

| 指标 | 值 |
|---|---|
| cancelAndAdd 总次数 | N |
| 总 accepted 订单 | M |
| 总 rejected 订单 | N |
| cancel 次数 / 成功率 | N / X% |

### 2.5 网格更新（如有）

```
<special_grid_done / ban_orders_replace 日志>
```

## 3. 模式切换

<mode_transition 日志摘录>

## 4. Reconcile

<reconcile 相关日志摘录>

## 5. 异常汇总

| 类型 | 次数 | 典型日志 |
|---|---|---|
| 各类 WARNING/ERROR | N | <日志> |

## 6. 综合判定

- 做市链路: ✅ 正常 / ⚠️ 有问题（说明）
- 盘口收敛: ✅ 正常（N tick 内收敛）/ ⚠️ 未收敛（原因）
- 模式切换: ✅ 正常 / ⚠️ 异常
- Mock API 交互: ✅ 正常 / ⚠️ 有问题
- 总体: ✅ 通过 / ⚠️ 需关注

### 建议/备注
- <任何值得注意的发现>
```
