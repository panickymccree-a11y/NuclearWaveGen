`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 64位 xorshift 伪随机数发生器
//
// 采用 xorshift64 算法，通过三级移位-异或操作产生高质量的伪随机序列。
// 每个时钟周期（enable=1时）产生一个新的64位随机数。
//
// xorshift64 状态更新公式：
//   s1 = state ^ (state << 13)
//   s2 = s1    ^ (s1   >> 7)
//   s3 = s2    ^ (s2   << 17)     → 新的随机数
//
// 特性：
//   - 周期长度 2^64 - 1，对于伪随机脉冲发生器完全足够
//   - 非零种子不会自行归零，因此只在显式加载种子时做零值保护
//   - 纯组合逻辑计算下一状态，寄存器仅保存当前状态
//   - 硬件开销：64个FF + 约200个LUT（移位和异或）
//
// 种子加载机制：
//   seed_load=1 时，可选择加载指定种子值或使用默认SEED参数
//   seed_zero=1 → 恢复默认SEED；seed_zero=0 → 加载seed_data
// ═══════════════════════════════════════════════════════════════════════════
module rng_xorshift64 #(
    parameter [63:0] SEED = 64'h9E37_79B9_7F4A_7C15   // 默认初始种子（非零常量）
) (
    input  wire        clk,                              // 系统时钟
    input  wire        rst_n,                            // 异步复位（低有效）
    input  wire        enable,                           // 使能信号：为1时每个周期更新状态
    input  wire        seed_load,                        // 种子加载脉冲：为1时加载新种子
    input  wire        seed_zero,                        // 种子归零标志：为1时使用默认SEED
    input  wire [63:0] seed_data,                        // 外部种子数据输入
    output wire [63:0] random_out                        // 64位随机数输出（当前状态的直接读出）
);

    reg [63:0] state;                                    // 64位内部状态寄存器

    assign random_out = state;                           // 输出即状态寄存器当前值

    // ══════════════════════════════════════════════════════════════════════
    // xorshift64 下一状态组合逻辑
    //
    // 三级变换链：
    //   第1级：state ^ (state << 13)   → 引入高位搅动
    //   第2级：上一步 ^ (上一步 >> 7)   → 引入低位搅动
    //   第3级：上一步 ^ (上一步 << 17)  → 再次高位混合
    //
    // 左移和右移交替使用，配合异或操作，确保每一位都能充分扩散
    // ══════════════════════════════════════════════════════════════════════
    wire [63:0] xs_s1 = state ^ (state << 13);          // 第一级：左移异或
    wire [63:0] xs_s2 = xs_s1 ^ (xs_s1 >> 7);           // 第二级：右移异或
    wire [63:0] xs_s3 = xs_s2 ^ (xs_s2 << 17);          // 第三级：左移异或 → 最终下一状态

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= SEED;                               // 复位时恢复默认种子
        end else if (seed_load) begin
            state <= seed_zero ? SEED : seed_data;       // 加载外部种子或恢复默认值
        end else if (enable) begin
            state <= xs_s3;                              // 正常运行时更新状态
        end
    end

endmodule
