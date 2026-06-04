`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 带符号白噪声源（每采样通道独立）
//
// 从噪声 RNG 的64位输出中截取低 NOISE_BITS 位作为有符号均匀白噪声，
// 经可配置的算术右移（noise_shift）缩放后输出。
//
// 噪声生成流程：
//   1. 从 RNG 输出中取 [NOISE_BITS-1:0] 位，解释为有符号数（2的补码）
//   2. 算术右移 noise_shift 位（保留符号位，相当于除以 2^noise_shift）
//   3. noise_enable=0 时输出全零（关闭噪声）
//
// 噪声幅度控制：
//   noise_shift 越大 → 噪声幅度越小
//   例如 NOISE_BITS=16, noise_shift=8 → 有效噪声范围约 [-128, 127]
//
// 用途：
//   模拟核辐射探测器的电子噪声基底，使输出波形更接近真实物理信号。
//   噪声在 mixer_saturator_simple 模块中与脉冲信号叠加。
// ═══════════════════════════════════════════════════════════════════════════
module noise_baseline_core #(
    parameter integer SAMPLES_PER_CLK = 2,               // 每时钟周期并行采样通道数
    parameter integer RNG_BITS        = 64,              // 随机数位宽
    parameter integer NOISE_BITS      = 16               // 噪声位宽（从RNG中截取的低位位数）
) (
    input  wire                                                 clk,
    input  wire                                                 rst_n,
    input  wire                                                 enable,         // 全局使能
    input  wire                                                 noise_enable,   // 噪声开关：0=关闭（输出全零）
    input  wire [4:0]                                           noise_shift,    // 噪声幅度缩放右移量
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0]                  rng_noise_vec,  // 噪声随机数向量
    output reg  signed [SAMPLES_PER_CLK*NOISE_BITS-1:0]         noise_vec       // 噪声输出向量（有符号）
);

    integer i;
    reg signed [NOISE_BITS-1:0] raw_noise;               // 原始噪声值（有符号）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_vec <= {(SAMPLES_PER_CLK*NOISE_BITS){1'b0}};
        end else if (enable && noise_enable) begin
            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                // 从RNG高位截取 NOISE_BITS 位，解释为有符号数
                raw_noise = rng_noise_vec[i*RNG_BITS + RNG_BITS-NOISE_BITS +: NOISE_BITS];
                // 算术右移缩放（>>> 保留符号位）
                noise_vec[i*NOISE_BITS +: NOISE_BITS] <= raw_noise >>> noise_shift;
            end
        end else begin
            noise_vec <= {(SAMPLES_PER_CLK*NOISE_BITS){1'b0}};  // 未使能时输出零
        end
    end

endmodule
