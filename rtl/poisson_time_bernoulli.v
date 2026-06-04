`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 离散时间伯努利泊松过程事件发生器
//
// 在每个采样通道内，用32位均匀随机数与速率阈值做简单比较：
//   event = (uniform_random[31:0] < rate_threshold_q32)
//
// 其中 rate_threshold_q32 是泊松速率 λ 的 Q0.32 定点表示：
//   rate_threshold_q32 = round(rate_cps / sample_rate_hz × 2^32)
//
// 例如：10 Mcps 事件率，500 MSa/s 采样率 →
//   λ = 0.02 → threshold = 0.02 × 2^32 ≈ 85,899,346
//
// 原理：
//   泊松过程在极短时间间隔 Δt 内，事件发生概率 P(k≥1) ≈ λ·Δt。
//   当 Δt = 1/fs 时，这个概率恰好等于 λ。
//   用32位均匀随机数比较实现伯努利试验，每个采样点独立判断。
//
// 注意：
//   本模块只判断"有/无事件"（二值），不处理多事件情况。
//   如需支持每个采样点多个事件（泊松尾部 k≥2），请使用
//   poisson_time_multievent 模块。
// ═══════════════════════════════════════════════════════════════════════════
module poisson_time_bernoulli #(
    parameter integer SAMPLES_PER_CLK = 2,               // 每时钟周期并行采样通道数
    parameter integer RNG_BITS        = 64               // 随机数位宽（实际只用低32位）
) (
    input  wire                                        enable,            // 全局使能
    input  wire [31:0]                                 rate_threshold_q32,// 速率阈值（Q0.32格式）
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0]         rng_time_vec,      // 时间判定随机数向量
    output wire [SAMPLES_PER_CLK-1:0]                  event_valid_vec    // 事件有效标志：bit[i]=1表示lane i有事件
);

    genvar i;

    // ══════════════════════════════════════════════════════════════════════
    // 每个采样通道独立比较：取对应RNG字的低32位与阈值比较
    //
    // 比较逻辑：
    //   当 enable=1 且 rng[31:0] < threshold 时，判定有事件
    //   无符号整数比较：rng值越小代表概率越低，恰好符合泊松概率模型
    // ══════════════════════════════════════════════════════════════════════
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_lane
            wire [RNG_BITS-1:0] rng_i;
            assign rng_i = rng_time_vec[(i+1)*RNG_BITS-1:i*RNG_BITS];
            assign event_valid_vec[i] = enable && (rng_i[31:0] < rate_threshold_q32);
        end
    endgenerate

endmodule
