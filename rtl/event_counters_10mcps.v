`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 事件统计计数器
//
// 持续监控并累计各类事件数量，用于运行时调试和性能监控。
// 所有计数器均为64位饱和计数器，可通过 clear 信号（软复位）清零。
//
// 维护的计数器：
//   sample_count：    累计采样次数（每个有效周期 +SAMPLES_PER_CLK）
//   candidate_count： 候选事件总数（泊松过程初步判定的事件数）
//   emitted_count：   实际发出的事件总数（经幅度采样后确认的事件数）
//   saturation_count：发生饱和的采样次数（DAC输出被钳位的次数）
//
// 状态字（status_word）各bit含义：
//   bit[0]：state_overflow  —— 指数衰减状态溢出标志
//   bit[1]：saturation       —— 当前周期有采样通道饱和
//   bit[2]：multi_event      —— 当前周期有采样通道出现多事件（k≥2）
//
// 辅助函数：
//   popcount_vec：  统计各lane的饱和标志中有几个为1
//   sum_count_vec： 统计各lane的事件计数之和
//   has_multi_event：检查是否有任何lane的事件数≥2
// ═══════════════════════════════════════════════════════════════════════════
module event_counters_10mcps #(
    parameter integer SAMPLES_PER_CLK = 2,               // 每时钟周期并行采样通道数
    parameter integer K_BITS          = 3                // 事件计数位宽（最大表示7个事件/通道）
) (
    input  wire                                           clk,
    input  wire                                           rst_n,
    input  wire                                           enable,             // 全局使能
    input  wire                                           clear,              // 计数器清零（软复位）
    input  wire [SAMPLES_PER_CLK-1:0]                     event_valid_vec,    // 候选事件有效标志
    input  wire [SAMPLES_PER_CLK*K_BITS-1:0]              event_count_vec,    // 候选事件计数
    input  wire [SAMPLES_PER_CLK-1:0]                     impulse_valid_vec,  // 实际脉冲有效标志
    input  wire [SAMPLES_PER_CLK*K_BITS-1:0]              impulse_count_vec,  // 实际脉冲计数
    input  wire [SAMPLES_PER_CLK-1:0]                     saturation_vec,     // 饱和标志向量
    input  wire                                           state_overflow,     // 状态溢出标志
    output reg  [63:0]                                    sample_count,       // 累计采样数
    output reg  [63:0]                                    candidate_count,    // 累计候选事件数
    output reg  [63:0]                                    emitted_count,      // 累计实际发出事件数
    output reg  [63:0]                                    saturation_count,   // 累计饱和次数
    output reg  [31:0]                                    status_word         // 状态字（bits: 0=overflow,1=saturation,2=multi_event）
);

    // ── 辅助函数：统计向量中置位的bit数 ──
    function [7:0] popcount_vec;
        input [SAMPLES_PER_CLK-1:0] v;
        integer j;
        begin
            popcount_vec = 8'd0;
            for (j = 0; j < SAMPLES_PER_CLK; j = j + 1) begin
                popcount_vec = popcount_vec + v[j];
            end
        end
    endfunction

    // ── 辅助函数：各lane事件计数求和 ──
    function [15:0] sum_count_vec;
        input [SAMPLES_PER_CLK*K_BITS-1:0] v;
        integer j;
        begin
            sum_count_vec = 16'd0;
            for (j = 0; j < SAMPLES_PER_CLK; j = j + 1) begin
                sum_count_vec = sum_count_vec + v[j*K_BITS +: K_BITS];
            end
        end
    endfunction

    // ── 辅助函数：检查是否存在多事件（任意lane事件数≥2） ──
    function has_multi_event;
        input [SAMPLES_PER_CLK*K_BITS-1:0] v;
        integer j;
        begin
            has_multi_event = 1'b0;
            for (j = 0; j < SAMPLES_PER_CLK; j = j + 1) begin
                if (v[j*K_BITS +: K_BITS] > 1)
                    has_multi_event = 1'b1;
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count     <= 64'd0;
            candidate_count  <= 64'd0;
            emitted_count    <= 64'd0;
            saturation_count <= 64'd0;
            status_word      <= 32'd0;
        end else if (clear) begin
            sample_count     <= 64'd0;
            candidate_count  <= 64'd0;
            emitted_count    <= 64'd0;
            saturation_count <= 64'd0;
            status_word      <= 32'd0;
        end else if (enable) begin
            sample_count     <= sample_count + SAMPLES_PER_CLK;           // 每次增加采样通道数
            candidate_count  <= candidate_count + sum_count_vec(event_count_vec);
            emitted_count    <= emitted_count + sum_count_vec(impulse_count_vec);
            saturation_count <= saturation_count + popcount_vec(saturation_vec);
            status_word[0]   <= state_overflow;
            status_word[1]   <= |saturation_vec;                          // 任意通道饱和即为1
            status_word[2]   <= has_multi_event(event_count_vec);
        end
    end

endmodule
