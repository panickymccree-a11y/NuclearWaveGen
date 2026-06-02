# XC7A100T 实现审查报告

> 目标器件：XC7A100T-2 (Artix-7, Speed Grade -2)
> 目标时钟：250 MHz (4 ns period)
> 等效采样率：500 MS/s (SAMPLES_PER_CLK=2)

---

## 零、数据流总览与关键路径标注

```
                         配置总线 (低速, 无时序压力)
                         ──────────────────────────────────────────────────────
                         │     │          │       │        │         │
                         ▼     ▼          ▼       ▼        ▼         ▼
                    ┌────────┐ ┌────────┐ ┌──────────┐ ┌────────┐ ┌──────────────┐
                    │rate_q32│ │decay   │ │output    │ │noise   │ │baseline      │
                    │        │ │_shift  │ │_shift    │ │_ctrl   │ │_offset       │
                    └───┬────┘ └───┬────┘ └────┬─────┘ └───┬────┘ └──────┬───────┘
                        │          │           │           │              │
                        ▼          │           │           ▼              │
    ┌──────────────────────┐       │           │    ┌──────────────┐      │
    │  poisson_time_       │       │           │    │ noise_       │      │
    │  multievent          │       │           │    │ baseline     │      │
    │                      │       │           │    │ _core        │      │
    │  ╔══════════════╗    │       │           │    │              │      │
    │  ║ P1 CRITICAL  ║    │       │           │    │ ✅ ~1.5ns    │      │
    │  ║ ~15ns 路径   ║    │       │           │    └──────┬───────┘      │
    │  ║ 3级组合乘+÷  ║    │       │           │           │              │
    │  ╚══════════════╝    │       │           │           │              │
    │                      │       │           │           │              │
    │  λ²,λ³,λ⁴ 阈值计算   │       │           │           │              │
    └──────────┬───────────┘       │           │           │              │
               │                   │           │           │              │
               ▼                   │           │           │              │
    ┌──────────────────────┐       │           │           │              │
    │  amplitude_sampler   │       │           │           │              │
    │  _icdf               │       │           │           │              │
    │                      │       │           │           │              │
    │  ╔══════════════╗    │       │           │           │              │
    │  ║ P2 MARGINAL  ║    │       │           │           │              │
    │  ║ ~6.8ns 路径  ║    │       │           │           │              │
    │  ║ 4级串联加法  ║    │       │           │           │              │
    │  ╚══════════════╝    │       │           │           │              │
    │                      │       │           │           │              │
    │  BRAM → + → + → + → +→ reg  │           │           │              │
    └──────────┬───────────┘       │           │           │              │
               │ impulse_sum       │           │           │              │
               ▼                   ▼           ▼           │              │
    ┌─────────────────────────────────────────────┐        │              │
    │  exp_decay_core                             │        │              │
    │                                             │        │              │
    │  ╔═══════════════════════════════════════╗  │        │              │
    │  ║ P0 CRITICAL — MUST FIX FIRST         ║  │        │              │
    │  ║ ~10ns 路径 (Lane0: 5ns + Lane1: 5ns) ║  │        │              │
    │  ║                                      ║  │        │              │
    │  ║  Lane0:  +impulse → >>output → >>decay → sub  ║        │
    │  ║          │48bitADD│  │shift │  │shift │  │    ║        │
    │  ║          └──1.8ns─┘  └─0.3ns┘  └─0.3ns┘      ║        │
    │  ║          └────────── ~5ns total ──────────┘   ║        │
    │  ║                                      ║  │        │              │
    │  ║  Lane1:  同Lane0（依赖Lane0的work_state）║  │        │              │
    │  ║          └────────── ~5ns total ──────────┘   ║        │              │
    │  ╚═══════════════════════════════════════════╝  │        │              │
    │                                             │        │              │
    │  state(48bit) ──→ lane0 ──→ lane1 ──→ reg   │        │              │
    └──────────────────────┬──────────────────────┘        │              │
                           │ pulse_vec                     │ noise_vec    │
                           ▼                               ▼              ▼
                ┌─────────────────────────────────────────────────────────┐
                │  mixer_saturator_simple                                  │
                │                                                         │
                │  ✅ ~3ns, OK                                             │
                │  pulse + baseline + noise → saturate → dac_sample       │
                └──────────────────────────┬──────────────────────────────┘
                                           │
                                           ▼
                                    ┌──────────────┐
                                    │  DAC 输出     │
                                    │  16bit × 2    │
                                    └──────────────┘


     ═══════════════════════════════════════════════════════════════════
                        RNG 子系统 (6× xorshift64)
     ═══════════════════════════════════════════════════════════════════
                         │
            ┌────────────┼────────────┐
            ▼            ▼            ▼
       rng_time[1:0]  rng_amp[1:0]  rng_noise[1:0]
       (2×64bit)      (2×64bit)     (2×64bit)
            │            │            │
            ▼            ▼            ▼
       Poisson判定   ICDF地址    噪声生成
       (multievent)  (高14bit)   (高16bit→>>>shift)
            │            │            │
            └────────────┴────────────┘
                         │
                   全部 ✅ OK
                   (~1ns/LUT级)


    时序预算 (每 4ns 时钟周期, XC7A100T-2 worst-case slow corner):
    ┌──────────────────────────────────────────────────────────────┐
    │                                                            │
    │  <── Tclk2Q ──><──── 组合逻辑 ────><── Tsetup ──>         │
    │  <─ 0.5ns ──><─     max 3.0ns    ──><─ 0.5ns ──>         │
    │                                                            │
    │  可用组合逻辑预算: ~3.0ns (含布线延迟)                     │
    │  DSP48E1 单级延迟: ~1.5-2.0ns                              │
    │  CARRY4 单级延迟: ~120-180ps (每级4bit进位)                │
    │  BRAM Tcko:       ~1.5-2.0ns                               │
    │  LUT6 延迟:       ~0.3-0.6ns                               │
    └──────────────────────────────────────────────────────────────┘


    修复后的目标流水线结构:
    ──────────────────────────────────────────────────────────────

    Stage 0 (RNG):     xorshift64 状态更新        [1ns / 4ns] ✅
    Stage 1 (Poisson): 阈值比较 + 事件计数判定     [2ns / 4ns] ✅
    Stage 2 (ICDF):    LUT 地址生成                [1ns / 4ns] ✅
    Stage 3 (BRAM):    BRAM 读 (同步)              [BRAM 固有延迟]
    Stage 4 (Amp Sum): 幅度累加 Part1 (slot0,1)    [3ns / 4ns] ✅
    Stage 5 (Amp Sum): 幅度累加 Part2 (slot2,3)    [3ns / 4ns] ✅
    Stage 6 (Decay):   Lane0 衰减更新 (DSP48映射)  [2ns / 4ns] ✅
    Stage 7 (Decay):   Lane1 衰减更新 (DSP48映射)  [2ns / 4ns] ✅
    Stage 8 (Mix):     混音 + 饱和                 [3ns / 4ns] ✅

    总流水线延迟: 8 周期 (32ns) — 对实时脉冲生成无影响


    关键路径分级标注:
    ┌─────┬──────────────────────┬────────────────────────────────┐
    │ 级别│ 路径                 │ 修复策略                       │
    ├─────┼──────────────────────┼────────────────────────────────┤
    │ 🔴  │ Lane0→Lane1 顺序计算 │ 拆分为 2 个流水级，每级单 lane │
    │ 🔴  │ λ²→λ³→λ⁴ 组合乘法   │ 插入 3 级寄存器流水线化乘法    │
    │ 🟡  │ 4级加法器串联        │ 拆为 2+2 两级流水              │
    │ 🟢  │ 其余组合路径         │ 无需修改                       │
    └─────┴──────────────────────┴────────────────────────────────┘
```

---

## 一、资源估算

| 资源类型 | 估算用量 | XC7A100T 总量 | 利用率 |
|----------|----------|---------------|--------|
| LUTs | ~2,000 | 63,400 | 3.2% |
| FFs | ~3,000 | 126,800 | 2.4% |
| DSP48E1 | 20-44 | 240 | 8-18% |
| BRAM36 | 8 | 135 | 5.9% |

**结论：** 资源总量充足，无资源瓶颈。DSP 用量取决于乘法器的映射方式。

---

## 二、逐模块时序分析

### 2.1 `rng_xorshift64` — ✅ 无问题

**关键路径：**
```
state_reg → XOR(x<<13) → XOR(x>>7) → XOR(x<<17) → next_state
```

- 移位量为常量，综合后为纯布线（无逻辑）
- 3 级 XOR 级联 ≈ 1 个 LUT6 层级
- 路径延迟：< 1 ns
- **裕量充足**

### 2.2 `rng_bank_10mcps` — ✅ 无问题

- 6 个 xorshift64 实例完全并行
- 实例间无依赖
- **无时序问题**

### 2.3 `poisson_time_multievent` — 🔴 严重时序违规

**关键路径分析：**

```
rate_threshold_q32 (reg)
  → 32×32 乘法 → lambda_sq_q64        // 第1级组合逻辑
  → 64×32 乘法 → lambda_cube_q96       // 第2级组合逻辑
  → 96×32 乘法 → lambda_fourth_q128    // 第3级组合逻辑
  → ÷6 / ÷24   → threshold_ge3/ge4     // 除法器（组合逻辑）
  → 比较器     → event_count (reg)     // 终点寄存器
```

**逐级延迟估算 (XC7A100T-2, worst-case slow corner)：**

| 运算 | 实现方式 | 估算延迟 |
|------|----------|----------|
| 32×32 → 64 | 4× DSP48E1 级联 | ~3.0 ns |
| 64×32 → 96 | 6× DSP48E1 级联 | ~4.2 ns |
| 96×32 → 128 | 8× DSP48E1 级联 | ~5.5 ns |
| ÷6 (常数除) | DSP/LUT 乘倒数 | ~2.0 ns |
| 比较 & MUX | LUT | ~0.5 ns |
| **累计** | | **~15 ns** |

> **时序余量：4 ns 需求 vs ~15 ns 实际 → 违反达 11 ns，无法通过布局布线补救。**

**根本问题：** λ²、λ³、λ⁴ 阈值的计算是纯组合逻辑，无任何流水线寄存器。即使 `rate_threshold_q32` 为准静态信号（仅在配置时变化），静态时序分析 (STA) 仍然会报告此路径失败。

**⚠️ 注意：** 不能简单地对此路径设置 `set_false_path` 或 `set_multicycle_path`，因为：
- `rate_threshold_q32` 虽然变化缓慢，但从寄存器出发的路径必须满足单周期约束
- 在使能信号路径上打多周期标签是危险的做法，容易掩盖真正的功能错误

**当前路径 vs 修复后路径对比：**

```
当前 (纯组合, ~15ns, 无法收敛):
  rate_threshold_q32 ──→ [32×32] ──→ [64×32] ──→ [96×32] ──→ [÷6,÷24] ──→ 比较器 ──→ event_count
       (reg)              DSP×4      DSP×6      DSP×8       LUT/DSP        LUT        (reg)
                         ~3.0ns     ~4.2ns     ~5.5ns       ~2.0ns       ~0.5ns
                         └────────────────── ~15.2ns total ──────────────────────────┘
                                         ❌ 远超 4ns 约束

修复后 (3级流水线, <4ns/级, 可收敛):
  Stage 1:                Stage 2:                   Stage 3:
  rate_threshold_q32 ──→ [32×32] ──→ reg ──→ [64×32] ──→ reg ──→ [96×32] ──→ reg ──→ [÷6,÷24] ──→ reg
       (reg)              DSP×4    (pipe1)  DSP×6    (pipe2)  DSP×8    (pipe3)   LUT/DSP   (threshold)
                         ~3.0ns             ~4.2ns             ~5.5ns             ~2.0ns
                                                                                         │
                                                                                         ▼
                                                                              比较器 ──→ event_count
                                                                              LUT ~0.5ns  (reg)
                                                                            └── ~2.5ns ──┘
                                                                                 ✅
```

**推荐修复方案：管道化阈值计算**

```
// 方法一：3级流水线（推荐）
reg [63:0]  lambda_sq_q64_r;
reg [95:0]  lambda_cube_q96_r;
reg [127:0] lambda_fourth_q128_r;
reg [31:0]  threshold_ge2_q32_r;
reg [31:0]  threshold_ge3_q32_r;
reg [31:0]  threshold_ge4_q32_r;

always @(posedge clk) begin
    lambda_sq_q64_r      <= rate_threshold_q32 * rate_threshold_q32;
    lambda_cube_q96_r    <= lambda_sq_q64_r * rate_threshold_q32;
    lambda_fourth_q128_r <= lambda_cube_q96_r * rate_threshold_q32;
    threshold_ge2_q32_r  <= lambda_sq_q64_r >> 33;
    threshold_ge3_q32_r  <= (lambda_cube_q96_r >> 64) / 6;
    threshold_ge4_q32_r  <= (lambda_fourth_q128_r >> 96) / 24;
end
```

- 代价：增加 3 周期延迟（阈值稳定后自动对齐）
- 收益：每级路径缩短到 ~3-5 ns，满足 4 ns 时序
- 副作用：切换 rate 后需等待 3 个周期阈值才生效（对人工配置来说可忽略）

```
// 方法二：利用 cfg_regfile 写入时触发计算（更省资源）
// 阈值仅在配置写入时重新计算，计算完成后锁存
// 优点：DSP 可被多个计算阶段复用
```

**DSP48 使用优化建议：**

使用 Vivado 的 `(* use_dsp = "yes" *)` 属性引导乘法器映射到 DSP48，并在乘法器间插入流水线寄存器。特别注意 ÷6 和 ÷24：建议用乘法替代：
```
// threshold_ge3 = λ³ / 6 = λ³ × (2^32 / 6) >> 32 = λ³ × 0x2AAAAAAB >> 32
// 使用 DSP48 预加器+乘法器单周期完成
```

---

### 2.4 `amplitude_sampler_icdf` — 🟡 时序紧张

**关键路径：**

```
BRAM rd_data (Tcko ≈ 1.8 ns)
  → MUX (选 slot 对应端口)        // ~0.2 ns
  → +0 (初始化 amp_acc)           //   跳线
  → +amp[0] (第1次累加)           // ~1.0 ns (24bit CARRY)
  → +amp[1] (第2次累加)           // ~1.0 ns
  → +amp[2] (第3次累加)           // ~1.0 ns
  → +amp[3] (第4次累加)           // ~1.0 ns
  → saturation check              // ~0.5 ns
  → impulse_sum (reg setup)       // ~0.3 ns
```

**估算总延迟：1.8 + 0.2 + 0 + 1.0×4 + 0.5 + 0.3 = 6.8 ns**

> **时序余量：4 ns 需求 vs 6.8 ns 实际 → 违反约 2.8 ns，Speed Grade -3 也紧张。**

**问题本质：** `for (j=0; j<MAX_EVENTS_PER_SAMPLE; j++)` 展开为 4 个串联加法器。BRAM 输出到寄存器的路径穿过了全部 4 级进位链。

**推荐修复方案：**

```
// 方案一：2级流水线（推荐）
// Cycle N:   累加 slot 0,1 → partial_sum_01
// Cycle N+1: 累加 slot 2,3 + partial_sum_01 → final_sum
// 代价：脉冲输出延迟增加 1 拍

// 方案二：并行加法树
// (amp0 + amp1) 和 (amp2 + amp3) 并行计算，再求和
// 路径缩短为 2 级加法器，约 3.5 ns
// 代价：增加约 100 LUTs
```

---

### 2.5 `exp_decay_core` — 🔴 严重时序违规

**这是整个设计最关键的问题。** 由于 `SAMPLES_PER_CLK=2` 且通道间为时序交错（lane 1 依赖 lane 0 的结果），单个 4 ns 周期内必须完成：

```
Lane 0:
  impulse_ext 组合                                // ~0.3 ns
  next_state = work_state + impulse_ext (48bit)   // ~1.8 ns (12级CARRY4)
  溢出判断                                        // ~0.1 ns
  scaled_state = next_state >> output_shift       // ~0.3 ns
  饱和检查                                        // ~0.2 ns
  work_state = next_state - (next_state >> decay_shift) (48bit)  // ~2.0 ns

Lane 1:  (依赖 Lane 0 的 work_state)
  impulse_ext 组合                                // ~0.3 ns
  next_state = work_state + impulse_ext (48bit)   // ~1.8 ns
  溢出判断                                        // ~0.1 ns
  scaled_state = next_state >> output_shift       // ~0.3 ns
  饱和检查                                        // ~0.2 ns
  work_state = next_state - (next_state >> decay_shift) (48bit)  // ~2.0 ns
```

**估算总延迟：** Lane 0 约 5 ns + Lane 1 约 5 ns = **~10 ns**

> **时序余量：4 ns 需求 vs ~10 ns 实际 → 违反约 6 ns。这是结构性问题，无法通过布局布线优化解决。**

**当前路径 vs 修复后路径对比：**

```
当前 (顺序计算, 2 lanes/cycle, ~10ns, 无法收敛):
  clock cycle N (4ns):
  ┌──────────────────────────────────────────────────────────────┐
  │  decay_state(reg)                                            │
  │    │                                                         │
  │    ▼                                                         │
  │  Lane 0: +impulse ──→ >>output ──→ >>decay ──→ sub ──→ work_state_0
  │          │48bit ADD│  │shift   │  │shift  │  │48bit SUB│
  │          └──1.8ns──┘  └─0.3ns─┘  └─0.3ns─┘  └──2.0ns──┘
  │          └──────────────── ~5ns Lane0 total ─────────────────┘
  │    │                                                         │
  │    ▼                                                         │
  │  Lane 1: +impulse ──→ >>output ──→ >>decay ──→ sub ──→ work_state_1
  │          │48bit ADD│  │shift   │  │shift  │  │48bit SUB│
  │          └──1.8ns──┘  └─0.3ns─┘  └─0.3ns─┘  └──2.0ns──┘
  │          └──────────────── ~5ns Lane1 total ─────────────────┘
  │    │                                                         │
  │    ▼                                                         │
  │  decay_state(reg) ← work_state_1                             │
  └──────────────────────────────────────────────────────────────┘
  └────────────── ~10ns total, needs 4ns ──────────────┘
                          ❌ 严重违规


修复后 (方案一: 拆为2周期, 每周期1 lane):
  clock cycle N (4ns):                   clock cycle N+1 (4ns):
  ┌───────────────────────────────┐      ┌───────────────────────────────┐
  │  decay_state(reg)             │      │  work_state_0(reg)            │
  │    │                          │      │    │                          │
  │    ▼                          │      │    ▼                          │
  │  Lane 0 完整计算:             │      │  Lane 1 完整计算:             │
  │  +impulse                     │      │  +impulse                     │
  │    │ 48bit ADD   ~1.8ns ✅    │      │    │ 48bit ADD   ~1.8ns ✅    │
  │    ▼                          │      │    ▼                          │
  │  >>output_shift  ~0.3ns ✅    │      │  >>output_shift  ~0.3ns ✅    │
  │    │                          │      │    │                          │
  │    ▼                          │      │    ▼                          │
  │  saturation chk  ~0.2ns ✅    │      │  saturation chk  ~0.2ns ✅    │
  │    │                          │      │    │                          │
  │    ▼                          │      │    ▼                          │
  │  >>decay_shift   ~0.3ns ✅    │      │  >>decay_shift   ~0.3ns ✅    │
  │    │                          │      │    │                          │
  │    ▼                          │      │    ▼                          │
  │  48bit SUB       ~2.0ns ✅    │      │  48bit SUB       ~2.0ns ✅    │
  │    │                          │      │    │                          │
  │    ▼                          │      │    ▼                          │
  │  work_state_0(reg) ←─         │      │  decay_state(reg) ← work_state_1
  └───────────────────────────────┘      └───────────────────────────────┘
  └── ~4.6ns (含reg开销) ──┘              └── ~4.6ns ──┘
  仍略超, 需DSP48辅助                     仍略超, 需DSP48辅助


修复后 (方案一+DSP48: 推荐组合):
  使用 DSP48E1 的 48-bit ALU 模式, 加法/减法延迟降至 ~1.0ns
  
  clock cycle N (4ns):                   clock cycle N+1 (4ns):
  ┌───────────────────────────────┐      ┌───────────────────────────────┐
  │  Lane 0:                      │      │  Lane 1:                      │
  │  DSP48 ADD 48bit  ~1.0ns ✅   │      │  DSP48 ADD 48bit  ~1.0ns ✅   │
  │  Shift + cmp     ~0.5ns ✅    │      │  Shift + cmp     ~0.5ns ✅    │
  │  DSP48 SUB 48bit ~1.0ns ✅   │      │  DSP48 SUB 48bit ~1.0ns ✅   │
  │  ─────────────────────────    │      │  ─────────────────────────    │
  │  Total: ~2.5ns, 裕量 1.5ns ✅ │      │  Total: ~2.5ns, 裕量 1.5ns ✅ │
  └───────────────────────────────┘      └───────────────────────────────┘

  代价: 输出需做 lane 交错缓冲 (FIFO深度=2, 先入先出)
  总延迟: +1 周期 (对实时脉冲生成无影响)
```

**推荐修复方案（按推荐度排序）：**

```
// 方案一：拆周期 + DSP48 累加器（强烈推荐）
// - 每个时钟周期只处理 1 个 lane
// - 将 48-bit 加减法映射到 DSP48E1 的 ALU
// - DSP48E1 48-bit ADD/SUB 延迟 < 1.5ns
// - 单 lane 总延迟 < 3ns, 4ns 周期内裕量充足
// - 需增加 lane 交错输出缓冲 (2-deep FIFO)

// 方案二：降低 SAMPLES_PER_CLK 到 1
// - 等效采样率降至 250 MS/s
// - 最简单, 仅改 parameter, 不改 RTL
// - 代价：采样率减半

// 方案三：并行化（打破通道间依赖）
// - 维护两个独立的衰减状态（每通道一个），独立更新
// - 两个 lane 完全并行, 无依赖
// - 代价：改变了物理模型——两个通道不再模拟同一条衰减曲线
// - 适用场景：多通道独立信号源（非本设计意图）

// 方案四：纯多周期路径（不推荐）
// - 不做缓冲, 直接让 lane0/lane1 在不同周期输出
// - 输出不连续, 下游无法消费
// - 不建议使用
```

**DSP48 累加器映射示例：**

```verilog
// 使用 DSP48 原语或 RTL 引导推断
(* use_dsp = "yes" *) reg [47:0] decay_state;
// 48-bit 加减操作映射到 DSP48 的 ALU 模式
// DSP48E1 内置 48-bit 加法器, 比 LUT carry chain 快 3-5 倍
```

---

### 2.6 `noise_baseline_core` — ✅ 无问题

- 取 RNG 高 16 bit → 符号扩展 → 算术右移 → 输出
- 纯组合路径 < 1.5 ns
- **裕量充足**

### 2.7 `mixer_saturator_simple` — ✅ 基本无问题

**关键路径：**
```
pulse + baseline_ext + noise_ext → compare → MUX
```

- 35-bit 三操作数加法 + 比较 + MUX
- 估算：~3 ns
- 在 4 ns 周期内可行，裕量约 1 ns
- 注意：35-bit 加法器的进位链略长（9 级 CARRY4），注意约束

### 2.8 `event_counters_10mcps` — ✅ 无问题

- 64-bit 计数器自增路径：约 2.5-3.0 ns（16 级 CARRY4）
- 满足 4 ns，裕量约 1 ns
- 如有余量不足，可对计数器使能进行打拍，拆分进位链

### 2.9 `cfg_regfile_10mcps` — ✅ 无问题

- 寄存器写入：单周期路径，短进位
- 寄存器读取：组合读出 MUX，约 1-2 ns
- **无时序问题**

### 2.10 `amp_lut_multiport` / `amp_lut_single_port` — ✅ 无问题

- BRAM 输出到寄存器的路径：Tcko + 布线 ≈ 2 ns
- BRAM 本身的时钟到输出延迟为块内存固有特性
- **需注意：** BRAM 读延迟为 1 个时钟周期，设计已正确处理

---

## 三、综合风险评估

| 模块 | 风险等级 | 时序裕量 | 建议动作 |
|------|----------|----------|----------|
| rng_xorshift64 | 🟢 低 | > 3 ns | 无需修改 |
| rng_bank_10mcps | 🟢 低 | > 3 ns | 无需修改 |
| **poisson_time_multievent** | 🔴 高 | **-11 ns** | 必须流水线化 |
| **amplitude_sampler_icdf** | 🟡 中 | **-2.8 ns** | 建议流水线化 |
| **exp_decay_core** | 🔴 高 | **-6 ns** | 必须流水线化或使用 DSP48 |
| noise_baseline_core | 🟢 低 | > 2 ns | 无需修改 |
| mixer_saturator_simple | 🟢 低 | ~1 ns | 监控 |
| event_counters_10mcps | 🟢 低 | ~1 ns | 监控 |
| cfg_regfile_10mcps | 🟢 低 | > 2 ns | 无需修改 |
| amp_lut_* | 🟢 低 | ~2 ns | 无需修改 |

---

## 四、时钟域与复位

### 4.1 单时钟域设计

全部逻辑使用同一 `clk` (250 MHz)，无跨时钟域问题。

### 4.2 复位策略

- 所有模块使用 `rst_n`（异步复位、同步释放）
- `cfg_regfile` 提供 `soft_reset_pulse` 用于运行中清零衰减状态和计数器
- **建议：** 添加 XDC 约束中的 `set_false_path -from [get_ports rst_n]` 避免复位树成为时序瓶颈。（异步复位在 Xilinx 7-series 中的恢复/移除检查需要单独的时序约束）

```tcl
# 推荐 XDC 复位约束
set_false_path -from [get_ports rst_n] -to [all_registers]
set_max_delay -datapath_only -from [get_ports rst_n] -to [all_registers] 5.0
```

---

## 五、BRAM 配置建议

`amp_lut_single_port` 使用 `(* ram_style = "block" *)` 属性强制 BRAM 推断。

**XC7A100T BRAM36 特性：**
- 原生支持 1K×36, 2K×18, 4K×9, 8K×4, 16K×2, 32K×1 配置
- 16K×16 需要 2 个 BRAM36 拼接（每个提供 16K×9，拼接为 16K×18）
- 8 个副本 × 2 BRAM36 = **16 BRAM36**（非前述 8 个）

**读写冲突处理：** 当前设计读和写使用同一时钟沿。在 Vivado 综合中，`WRITE_MODE` 默认 `WRITE_FIRST`（写优先）或 `READ_FIRST`，取决于综合设置。由于 LUT 的读写使用不同地址（读地址来自 RNG，写地址来自外部配置），实际不会冲突。

**建议添加综合属性：**
```verilog
(* ram_style = "block", rw_addr_collision = "no" *)
```

---

## 六、DSP48 资源详细估算

| 模块 | 运算 | DSP 估算 | 备注 |
|------|------|----------|------|
| poisson_time_multievent | 32×32→64 | 4 | 可用 2 DSP（拆分为两个 25×18）|
| | 64×32→96 | 8 | 可用 4-6 DSP |
| | 96×32→128 | 12 | 可用 6-8 DSP |
| | ÷6, ÷24 | 4 | 常数乘法变体 |
| **小计** | | **28** | 流水线化后可复用降至 ~16 |

> XC7A100T 有 240 个 DSP48E1，28 个用量完全可接受。

---

## 七、功耗初步评估

| 功耗来源 | 估算 | 说明 |
|----------|------|------|
| 时钟树 (250 MHz) | ~200 mW | XC7A100T 6 个 CMT |
| 逻辑动态功耗 | ~100 mW | LUT 翻转率低，大部分为数据通路线 |
| BRAM (8×2=16 BRAM36) | ~80 mW | 每周期 8 路同时读取 |
| DSP (28 slices) | ~150 mW | 持续运算 |
| **静态功耗** | ~200 mW | XC7A100T 典型值 |
| **总估算** | **~730 mW** | 远低于 XC7A100T 封装限制 |

---

## 八、优先修复排序

| 优先级 | 模块 | 问题 | 影响 |
|--------|------|------|------|
| **P0** | exp_decay_core | 双通道顺序计算违反 4ns 约束 | 无法通过时序收敛 |
| **P1** | poisson_time_multievent | 3 级组合乘法器 + 除法器 | 无法通过时序收敛 |
| **P2** | amplitude_sampler_icdf | 4 级串联加法器 | 时序紧张，可能无法收敛 |
| P3 | 整体 | 添加 XDC 时序约束 | 确保正确的时序分析 |
| P4 | 整体 | 添加复位约束 | 避免恢复/移除违例 |

---

## 九、推荐 XDC 约束框架

```tcl
# 时钟约束
create_clock -name clk -period 4.000 [get_ports clk]

# 输入延迟（配置总线，假设为低速接口）
set_input_delay -clock clk -max 3.0 [get_ports {cfg_*}]
set_input_delay -clock clk -min 0.0 [get_ports {cfg_*}]

# 输出延迟（DAC 输出）
set_output_delay -clock clk -max 1.0 [get_ports {dac_sample_*}]
set_output_delay -clock clk -min 0.0 [get_ports {dac_sample_*}]

# 复位
set_false_path -from [get_ports rst_n]

# 多周期路径（仅当阈值计算管道化后）
# set_multicycle_path -setup 3 -from [get_cells ...threshold_reg*] -to [get_cells ...event_count*]
# set_multicycle_path -hold  2 -from [get_cells ...threshold_reg*] -to [get_cells ...event_count*]
```

---

## 十、总结

在 XC7A100T-2 上以 250 MHz 实现本设计，资源（LUT/FF/BRAM/DSP）充足，但有 **两个无法绕过** 的时序阻塞问题：

1. **`exp_decay_core`**：双通道顺序计算的独热路径是设计的架构性瓶颈，强烈推荐将 48-bit 算术映射到 DSP48 硬件累加器，单 DSP slice 可将关键路径缩短到 < 2 ns。

2. **`poisson_time_multievent`**：三阶级联组合乘法器 + 除法器的阈值计算必须流水线化，插入 3 级寄存器可将每条路径缩短到单级乘法（~4 ns 内可行）。

修复这两点后，250 MHz 时序收敛是可行的。`amplitude_sampler_icdf` 和 `event_counters` 虽有紧张路径，但在 P0/P1 修复后若仍有余量问题，可通过局部流水线化或 DSP 映射解决。
