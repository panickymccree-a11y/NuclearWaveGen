`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 双指数（Bi-Exponential）衰减脉冲整形核心
//
// 产生经典的核辐射脉冲形状：
//   pulse_shape ∝ exp(-t/τ_fall) - exp(-t/τ_rise)
//
// 即"快上升-慢下降"的脉冲：信号先快速攀升到峰值，然后缓慢衰减回基线。
// 这是核辐射探测器输出脉冲最典型的数学模型。
//
// 原理：两个独立指数衰减状态的差值
//
//   两个状态（state_fast 和 state_slow）同时接收同一个脉冲信号，
//   但以不同的速度衰减：
//     state_fast — 快衰减（rise_shift 小 → 衰减快）→ 控制上升沿
//     state_slow — 慢衰减（fall_shift 大 → 衰减慢）→ 控制下降沿
//
//   输出 = state_slow - state_fast
//
//   脉冲到达瞬间：两状态相等 → pulse=0（从零开始）
//   快状态迅速衰减 → 差值增大 → 脉冲上升
//   快状态趋近零后差值开始减小 → 脉冲以慢状态速度下降
//
// 参数含义：
//   rise_shift — 快时间常数控制（越小上升越快）
//     rise_shift=5 → τ≈32 采样≈64 ns（500 MSPS时）
//   fall_shift — 慢时间常数控制（越大下降越慢）
//     fall_shift=9 → τ≈512 采样≈1.024 μs（500 MSPS时）
//   output_shift — 输出幅度缩放（需比单指数模式大约3-4位）
//
// 流水线：2级，与 exp_decay_core 相同架构。
//   Stage 1：双状态累加+衰减 per lane
//   Stage 2：饱和检查+脉冲输出
// ═══════════════════════════════════════════════════════════════════════════
module exp_decay_bi_core #(
    parameter integer SAMPLES_PER_CLK = 2,                   // 每时钟周期并行采样通道数
    parameter integer IMP_BITS        = 24,                  // 输入脉冲幅度位宽
    parameter integer ACC_BITS        = 48,                  // 内部累加器位宽
    parameter integer PULSE_BITS      = 32,                  // 输出脉冲位宽
    parameter integer FRAC_BITS       = 12,                  // 小数位宽（Q36.12格式）
    parameter integer ENABLE_STATE_OVERFLOW = 1              // 溢出检测使能
) (
    input  wire                                                 clk,
    input  wire                                                 rst_n,
    input  wire                                                 enable,          // 全局使能
    input  wire                                                 clear,           // 状态清零
    input  wire [4:0]                                           rise_shift,      // 快时间常数（控制上升速度）
    input  wire [4:0]                                           fall_shift,      // 慢时间常数（控制下降速度）
    input  wire [4:0]                                           output_shift,    // 输出幅度缩放
    input  wire [SAMPLES_PER_CLK-1:0]                           impulse_valid_vec, // 脉冲有效标志
    input  wire [SAMPLES_PER_CLK*IMP_BITS-1:0]                  impulse_sum_vec, // 脉冲幅度向量
    output reg  [SAMPLES_PER_CLK*PULSE_BITS-1:0]                pulse_vec,       // 整形后脉冲输出
    output reg                                                  state_overflow   // 状态溢出标志
);

    // ══════════════════════════════════════════════════════════════════════
    // 双状态寄存器
    // ══════════════════════════════════════════════════════════════════════
    reg [ACC_BITS-1:0] state_fast;                             // 快衰减状态
    reg [ACC_BITS-1:0] state_slow;                             // 慢衰减状态

    reg [ACC_BITS-1:0] work_fast;                              // 工作变量（循环内）
    reg [ACC_BITS-1:0] work_slow;
    reg [ACC_BITS-1:0] next_fast;                              // 累加后快状态
    reg [ACC_BITS-1:0] next_slow;                              // 累加后慢状态
    reg [ACC_BITS-1:0] decayed_fast;                           // 衰减后快状态
    reg [ACC_BITS-1:0] decayed_slow;                           // 衰减后慢状态
    reg [ACC_BITS-1:0] impulse_ext;                            // 扩展脉冲
    reg [ACC_BITS-1:0] scaled_state;                           // 缩放后状态

    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] impulse_ext_vec_d;      // 扩展脉冲向量
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] pulse_state_vec_d;      // 脉冲状态向量
    reg [4:0]                          output_shift_d;
    reg                                overflow_next;
    reg                                pulse_overflow_next;

    // ── Stage 2 流水线寄存器 ──
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] pulse_state_pipe;
    reg [4:0]                          output_shift_pipe;
    reg                                enable_pipe;
    reg                                overflow_pipe;

    integer i;

    // ══════════════════════════════════════════════════════════════════════
    // Stage 1：双状态衰减 + 累加
    //
    // 对每个采样通道：
    //   1. 同时向快和慢状态累加脉冲（两者起点相同）
    //   2. 记录差值 state_slow - state_fast 作为输出
    //   3. 分别对两个状态应用独立速度的指数衰减
    //
    // 通道间串行传递保证了连续时间序列。
    // ══════════════════════════════════════════════════════════════════════
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_fast       <= {ACC_BITS{1'b0}};
            state_slow       <= {ACC_BITS{1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d   <= 5'd0;
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_pipe <= 5'd0;
            enable_pipe      <= 1'b0;
            overflow_pipe    <= 1'b0;
        end else if (clear) begin
            state_fast       <= {ACC_BITS{1'b0}};
            state_slow       <= {ACC_BITS{1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d   <= 5'd0;
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_pipe <= 5'd0;
            enable_pipe      <= 1'b0;
            overflow_pipe    <= 1'b0;
        end else if (enable) begin
            work_fast  = state_fast;
            work_slow  = state_slow;
            overflow_next = 1'b0;

            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                // ── 扩展脉冲到 ACC_BITS 位 ──
                if (impulse_valid_vec[i]) begin
                    impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS] <=
                        {{(ACC_BITS-IMP_BITS-FRAC_BITS){1'b0}},
                         impulse_sum_vec[i*IMP_BITS +: IMP_BITS],
                         {FRAC_BITS{1'b0}}};
                end else begin
                    impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS] <= {ACC_BITS{1'b0}};
                end

                impulse_ext = impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS];

                // ── 同时向两个状态累加脉冲 ──
                next_fast = work_fast + impulse_ext;
                next_slow = work_slow + impulse_ext;

                // ── 溢出检测 ──
                if ((ENABLE_STATE_OVERFLOW != 0) &&
                    (next_fast < work_fast || next_slow < work_slow)) begin
                    overflow_next = 1'b1;
                end

                // ── 输出 = 慢状态 - 快状态（双指数特征） ──
                pulse_state_vec_d[i*ACC_BITS +: ACC_BITS] <= next_slow - next_fast;

                // ── 分别衰减两个状态（独立速度） ──
                decayed_fast = next_fast - (next_fast >> rise_shift);
                decayed_slow = next_slow - (next_slow >> fall_shift);

                work_fast = decayed_fast;
                work_slow = decayed_slow;
            end

            state_fast <= work_fast;
            state_slow <= work_slow;
            output_shift_d <= output_shift;

            // ── 流水线转发 ──
            pulse_state_pipe <= pulse_state_vec_d;
            output_shift_pipe <= output_shift_d;
            enable_pipe <= 1'b1;
            overflow_pipe <= overflow_next;
        end else begin
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            enable_pipe <= 1'b0;
            overflow_pipe <= 1'b0;
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    // Stage 2：饱和检查 + 输出
    //
    // 双指数模式下，正常运行时 state_slow ≥ state_fast（慢状态总是
    // 衰减更少），差值非负。但仍保留了负值保护（理论安全冗余）。
    // ══════════════════════════════════════════════════════════════════════
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulse_vec      <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
            state_overflow <= 1'b0;
        end else if (clear) begin
            pulse_vec      <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
            state_overflow <= 1'b0;
        end else if (enable_pipe) begin
            pulse_overflow_next = 1'b0;

            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                scaled_state = pulse_state_pipe[i*ACC_BITS +: ACC_BITS] >> output_shift_pipe;
                if (|scaled_state[ACC_BITS-1:PULSE_BITS]) begin
                    pulse_vec[i*PULSE_BITS +: PULSE_BITS] <= {PULSE_BITS{1'b1}}; // 饱和钳位
                    pulse_overflow_next = 1'b1;
                end else begin
                    pulse_vec[i*PULSE_BITS +: PULSE_BITS] <= scaled_state[PULSE_BITS-1:0];
                end
            end

            state_overflow <= overflow_pipe | pulse_overflow_next;
        end else begin
            pulse_vec <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
        end
    end

endmodule
