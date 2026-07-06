---
name: spot-profiling-loop
description: KCEX Spot 自动 profiling 优化循环。不断 profile → 分析热点 → 尝试优化 → commit 记录 → 再 profile，直到收敛。每次 commit 累积记录尝试了什么、哪些走通了、哪些没走通。Use when 启动自动性能优化循环、跑持续的 profiling 迭代。
---

<what-to-do>

你是 KCEX Spot 做市系统的自动性能优化引擎。你运行一个**永不停止**的循环：profile → 找热点 → 优化 → commit → 再 profile。每次 commit message 是一个持续累积的实验日志，记录做了什么尝试、效果如何、为什么放弃某些方向。

## 🎯 终极性能目标

**800+ symbol 压测场景下，每个 symbol 的 tick P99 ≤ 50ms。**

这是本 skill 的最高优化目标。每一轮优化都必须以缩小与这个目标的差距为导向。

### 目标拆解

| 阶段 | 里程碑 | 说明 |
|---|---|---|
| 短期 | Tick P50 < 100ms | 中位数可控 |
| 中期 | Tick P90 < 100ms, P99 < 200ms | 多数 tick 稳定 |
| 长期 | Tick P99 < 50ms | 终极目标：尾延迟可控 |

### Tick 延迟是首要指标

在所有性能指标中，**tick P99 延迟是第一优先级**，优先级高于：
- IPC（指令每周期）— 只是诊断工具，不是目标
- CPU 利用率 — 只要能降低延迟，CPU 高也可以接受
- 吞吐量 — 做市系统对延迟敏感，而非吞吐

每轮 profiling 必须输出 **tick 延迟分位表**（P50/P90/P95/P99），并判断距离 50ms 目标还有多远。

## 🚨 继承约束

你继承 `spot-profiling` skill 的**全部约束**，包括但不限于：
- quick_start.sh 是管理压测依赖的唯一入口
- 只重启 spot，绝不重启 compose（除非 infra 变了）
- perf_event_paranoid=2，只能用 `--call-graph fp`
- Mock API 必须加载全部 867 symbol
- 禁止加编译 flag 绕过错误
- 改完代码编译+单测全 green 才能进入下一步

**注意**：spot-profiling-loop 引用 spot-profiling 作为基础 skill。所有 profiling 的数据采集、指标分析、验证流程，按照 spot-profiling 的 Step 0-6 标准流程执行。本 skill 只描述循环调度和决策逻辑。

## 循环流程

```
┌─────────────────────────────────────────────────────────┐
│  Step 0: 环境检查 + 清理 bench-reports                  │
│    ├─ infra 不活? → quick_start.sh bench start-infra    │
│    ├─ spot 不活? → quick_start.sh bench start-spot      │
│    └─ 清理 bench-reports（按 spot-profiling 清理规则）   │
├─────────────────────────────────────────────────────────┤
│  Step 1: Profiling (spot-profiling Step 1-4)            │
│    ├─ perf stat 60s + perf record 60s + 火焰图          │
│    ├─ Prometheus 快照（前后各一次）                      │
│    └─ per-symbol tick stats dump                        │
├─────────────────────────────────────────────────────────┤
│  Step 2: 热点分析                                       │
│    ├─ 读取 perf report top-N 函数                       │
│    ├─ 读取 Prometheus phase timing                      │
│    ├─ 读取最近一次 per-symbol stats                     │
│    └─ 生成瓶颈排序表（按 CPU% + 延迟影响排序）           │
├─────────────────────────────────────────────────────────┤
│  Step 3: 决策 — 选择本轮优化目标                         │
│    ├─ 评估每个瓶颈的 ROI（收益/风险比）                  │
│    ├─ 排除已尝试且失败的优化方向                          │
│    ├─ 排除已尝试且收益不显著的优化方向                    │
│    └─ 选一个目标，写出预期收益 + 风险 + 验证方法           │
├─────────────────────────────────────────────────────────┤
│  Step 4: 实现优化                                       │
│    ├─ 只做小的、局部的改动（≤50 行，≤3 个文件）          │
│    ├─ 不改变代码执行意图（不改业务逻辑）                  │
│    ├─ 编译 + 运行 cpp-infra 全量单测（48 tests green）   │
│    └─ 只重启 spot（不动 compose）                        │
├─────────────────────────────────────────────────────────┤
│  Step 5: 验证                                           │
│    ├─ 等待冷启动完成 + 30s 稳态                          │
│    ├─ 重跑 perf stat 30s（采样短一些，验证即可）         │
│    ├─ 对比优化前后的关键指标（IPC / tick P50 / Phase avg）│
│    └─ 验证 9 项正常做市条件                              │
├─────────────────────────────────────────────────────────┤
│  Step 6: Commit or Revert                                │
│    ├─ 有提升 → commit（实验日志格式）→ goto Step 1       │
│    ├─ 无提升 → git checkout . 回退 → commit 失败记录     │
│    └─ goto Step 1                                        │
└─────────────────────────────────────────────────────────┘
```

## 循环终止条件

以下条件**全部满足**时，循环自然终止（但通常不会全部满足，所以本质上是不停的）：

1. Tick P99 ≤ 50ms（终极目标达成）
2. 所有 >5% CPU 的热点都已尝试优化（成功或放弃）
3. 所有 >100ms P50 的 Phase 都已尝试优化
4. 连续 3 轮尝试无显著收益（tick P99 下降 <5% 且 tick P50 下降 <5%）

**终止后**：生成最终报告，更新 BENCHMARK.md，把本轮所有 commit 的摘要追加进去。

## 决策框架

### 热点优先级排序

每轮从以下维度给热点打分（1-10），选总分最高的：

| 维度 | 权重 | 说明 |
|---|---|---|
| **Tick 延迟影响** | 35% | 热点对 tick P99 的贡献。占 tick 总延迟 >50% → 10 分；<10% → 2 分。从 Prometheus phase timing 计算各 phase 占 tick 总延迟的比例 |
| **影响面** | 25% | CPU% 或吞吐影响。>20% CPU → 10 分；<5% CPU → 2 分 |
| **优化难度** | 20% | 预计改动量。1-2 行 → 10 分；重构架构 → 2 分 |
| **确定性** | 10% | 优化是否大概率有效。明确瓶颈 → 10 分；猜测 → 3 分 |
| **风险** | 10% | 反向：高风险 → 低分。改注释 → 10 分；改核心算法 → 3 分 |

**注意**：Tick 延迟影响 和 影响面 要结合起来看。一个热点可能 CPU 占比不高（I/O wait 为主），但直接贡献了 tick 延迟（如 HTTP 调用阻塞了整个 tick），这种情况要优先优化。

### 优化方向库（按优先级排，可复用）

| 方向 | 典型改动 | 预期收益 | 风险 |
|---|---|---|---|
| 消除全局锁竞争 | `shared_mutex` 替代 `mutex`，或去锁化 | 高（P50 ↓30-70%） | 低 |
| 连接池/复用 | 增加连接数、修复 keep-alive | 高（成功率 ↑） | 中 |
| 减少内存分配 | `string_view` 替代 `string`、预分配 buffer | 中（CPU ↓5-10%） | 低-中 |
| 缓存热数据 | 本地缓存替代 Redis/HTTP 查询 | 高（延迟 ↓50%+） | 中 |
| 批量 I/O | Pipeline Redis 命令、合并 HTTP 请求 | 中-高 | 中-高 |
| 减少 JSON 解析 | 缓存解析结果、用更快的 parser | 中 | 中 |
| 调整并发模型 | 更多 shard、连接池 | 高 | 高 |

### 已尝试记录

每轮 commit 累积记录。决策时先读 git log 看哪些方向已经试过。格式见下方「Commit Message 格式」。

## 约束细则

### 改动范围限制

- **≤50 行**新增代码（不含测试）
- **≤3 个文件**修改
- **不动业务逻辑**：不改策略算法、不改风控逻辑、不改价格计算
- **只动 I/O 路径和架构层**：CoroHttpClient、CoroRedis、metrics、shard 配置、连接管理
- **不引入新依赖**
- **不许绕过编译错误**：编译不过就修代码，不加 flag 绕过

### 🚨 线程数 / 连接数 必须基于 nproc

**所有线程池、连接池、并发数的配置，必须基于 `std::thread::hardware_concurrency()`（即 `nproc`）动态计算，禁止硬编码数字。**

| 场景 | 正确做法 | 错误做法 |
|---|---|---|
| 线程池大小 | `nproc * N` 或 `nproc + N` | `thread_pool(128)` |
| HTTP 连接池 | `nproc * K` | `max_connections = 64` |
| shard 数量 | `nproc` 或 `nproc * 2` | `num_shards = 32` |
| 并发度上限 | `nproc * M` | `max_concurrency = 256` |

**规则**：
- 代码中如果发现硬编码的数字（如 `32`、`64`、`128`、`256`、`1024`）用于线程/连接/shard，优先怀疑它是否应该从 nproc 推导
- 每个硬编码数字必须能解释为什么这个值与机器核数无关（如：这是 Redis 单实例的连接上限，不随机器变化）
- **性能优化时**：如果发现 I/O 等待时间过长但 CPU 空闲，可能硬编码的线程/连接数太低了 → 改为基于 nproc 动态放大
- **内存优化时**：如果发现连接数过多导致内存压力 → 改为基于 nproc 设置上限

**典型优化模式**：
```cpp
// ❌ 错误：硬编码
static constexpr int kMaxConnections = 64;

// ✅ 正确：基于 nproc 动态计算
static int maxConnections() {
    static int v = [] {
        int n = std::thread::hardware_concurrency();
        return std::max(8, n * 4);  // 至少 8，每核 4 个连接
    }();
    return v;
}
```

### 每次尝试前必须

1. 写明：要优化什么瓶颈、做什么改动、预期什么指标改善多少
2. 写明：怎么验证（对比哪些 Prometheus 指标）
3. 写明：失败了怎么办（git checkout . 还是保留部分改动）

### 每次验证必须

1. 冷启动完成后再采集数据
2. 至少等 30s 稳态
3. 对比优化前后至少 3 个指标（IPC / tick P50 / 目标 Phase avg）
4. 确认 9 项正常做市条件仍然满足

### 🚨 Profiling 必须在真实稳态下进行

**空订单的 tick 延迟没有参考价值。** 首次启动 spot 时订单很少（几百到几千），HTTP 调用数据量小，延迟会"很好看"（P50 < 5ms）。随着做市系统运行，mock API 会累积到 **~50,000 个活跃订单**，此时每次 `currentOrders`、`cancelAndAdd` 的 payload 才接近真实压测场景。

**规则：**
- **首次启动**（spot 刚拉起来，mock API orders < 10,000）：等订单累积到 50,000 级别再开始 profiling。可通过 `curl http://127.0.0.1:18090/health | grep orders` 确认
- **后续轮次**（只重启 spot，不动 compose）：mock API 内存状态保留，启动即可 profiling
- **如果 compose 被重启**（mock API 进程重建）：等同于首次启动，需要重新等订单累积
- **忽略指标时机**：P50 < 10ms 但 orders < 10,000 的数据不可信，必须等 orders 到 50,000 再判定优化效果

**判断标准：** 以 `"orders":50000` 的稳态延迟为准，不以空订单阶段的低延迟为优化成功依据。

### 失败处理

如果优化尝试失败（指标无明显改善或恶化）：
1. `git checkout .` 回退代码改动
2. **仍然 commit**：commit message 记录"尝试了 X，因为 Y 原因无效，回退"
3. 把这个方向标记为"已尝试-无效"，下次决策跳过

## Commit Message 格式

每次 commit 使用以下格式，形成累积的实验日志：

```
profiling-loop #N: <本轮优化简述>

## 尝试
- <做了什么改动，改了哪个文件>

## 效果
- IPC: X → Y
- Tick P50: Xms → Yms
- <目标 Phase> avg: Xms → Yms
- 其他: <其他观察>

## 结论
- <有效/无效/部分有效>
- <为什么有效/无效>
- <下一步建议>

## 累积记录
| # | 方向 | 效果 | 结论 |
|---|---|---|---|
| 1 | <方向> | <效果> | <结论> |
| 2 | ... | ... | ... |

Co-Authored-By: Claude <noreply@anthropic.com>
```

首次 commit 的「累积记录」表只有一行。后续每轮追加一行，形成完整实验日志。

## 快速启动

```bash
# 由用户通过 /spot-profiling-loop 命令触发。
# 该命令触发后，你开始循环，不需要再等用户确认每步操作。
# 但 commit 前需要用户确认（通过 AskUserQuestion 或直接 commit 取决于用户设置）。
```

## 关联 Skill

- `spot-profiling` — 基础 profiling 流程，本 skill 引用其 Step 0-6 标准流程
- `code-review-skill` — 修改代码后做 review
- `spot-commit` — commit 规范
