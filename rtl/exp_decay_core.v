`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 单指数衰减脉冲整形核心
//
// 模拟核辐射探测器输出脉冲的指数衰减特性——脉冲瞬间跳起后按指数规律
// 缓慢衰减，等效于 RC 放电曲线的离散时间近似。
//
// 核心更新公式（每个采样通道依次执行）：
//   state   = state + (impulse << FRAC_BITS)     // ① 叠加新脉冲（含12位小数）
//   pulse   = state >> output_shift              // ② 输出 = 状态缩放
//   state   = state - (state >> decay_shift)     // ③ 指数衰减（每次减去固定比例）
//
// 多通道串行处理（SAMPLES_PER_CLK > 1 时）：
//   lane0 先更新 decay_state → lane1 在 lane0 更新后的状态上继续 →
//   下一周期的 lane0 继承上一周期 lane1 末尾的状态。
//   这保证了 decay_state 是一个全局连续的时间序列变量。
//
// 衰减时间常数：
//   每次采样衰减比例为 1 / 2^decay_shift。
//   在 500 MSa/s 等效采样率下：
//     decay_shift=4 → τ≈16 采样≈32 ns（快衰减，尖脉冲）
//     decay_shift=8 → τ≈256 采样≈512 ns（慢衰减，宽脉冲）
//
// PIPELINE（2级流水线，为满足 Artix-7 上 250 MHz 时序）：
//   Stage 1：衰减 + 累加 → pulse_state_vec_d → pulse_state_pipe
//   Stage 2：饱和检查 → pulse_vec（断开48位进位链的反馈路径）
// ═══════════════════════════════════════════════════════════════════════════
module exp_decay_core #(
    parameter integer SAMPLES_PER_CLK       = 2,            // 每时钟周期并行采样通道数
    parameter integer IMP_BITS              = 24,           // 输入脉冲幅度位宽
    parameter integer ACC_BITS              = 48,           // 内部累加器位宽（=36位整数+12位小数）
    parameter integer PULSE_BITS            = 32,           // 输出脉冲位宽
    parameter integer FRAC_BITS             = 12,           // 小数位数（Q36.12定点格式）
    parameter integer DECAY_BEFORE_ACCUMULATE = 0,          // 0=先累加后衰减（默认）, 1=先衰减后累加
    parameter [4:0]  FIXED_DECAY_SHIFT      = 5'd0,        // 固定衰减量（非零时覆盖配置值）
    parameter integer ENABLE_STATE_OVERFLOW  = 1            // 溢出检测使能
) (
    input  wire                                                 clk,
    input  wire                                                 rst_n,
    input  wire                                                 enable,            // 全局使能
    input  wire                                                 clear,             // 状态清零（软复位）
    input  wire [4:0]                                           decay_shift,       // 衰减速度控制（右移量）
    input  wire [4:0]                                           output_shift,      // 输出幅度缩放
    input  wire [SAMPLES_PER_CLK-1:0]                           impulse_valid_vec, // 脉冲有效标志
    input  wire [SAMPLES_PER_CLK*IMP_BITS-1:0]                  impulse_sum_vec,   // 脉冲幅度向量
    output reg  [SAMPLES_PER_CLK*PULSE_BITS-1:0]                pulse_vec,         // 整形后脉冲输出
    output reg                                                  state_overflow     // 状态溢出标志
);

    reg [ACC_BITS-1:0] decay_state;                            // 衰减状态（跨时钟周期保留）
    reg [ACC_BITS-1:0] work_state;                             // 循环内的工作变量
    reg [ACC_BITS-1:0] next_state;                             // 累加后的中间状态
    reg [ACC_BITS-1:0] decayed_state;                          // 衰减后的状态
    reg [ACC_BITS-1:0] impulse_ext;                            // 扩展到ACC_BITS位的脉冲
    reg [ACC_BITS-1:0] scaled_state;                           // 缩放后的状态（用于饱和检查）
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] impulse_ext_vec_d;      // 扩展脉冲向量（调试用）
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] pulse_state_vec_d;      // 脉冲状态向量
    reg [4:0]           output_shift_d;                        // 延迟的输出缩放量
    reg                 overflow_next;                         // 溢出标志（组合逻辑产生）
    reg                 pulse_overflow_next;                   // 脉冲溢出标志
    wire [4:0]          decay_shift_eff;                       // 有效衰减量

    // ── Stage 2 流水线寄存器：断开累加到饱和的进位链 ──
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] pulse_state_pipe;
    reg [4:0]                          output_shift_pipe;
    reg                                enable_pipe;
    reg                                overflow_pipe;

    integer i;

    // FIXED_DECAY_SHIFT 非零时覆盖配置值（用于固定参数场景）
    assign decay_shift_eff = (FIXED_DECAY_SHIFT != 5'd0) ?
                             FIXED_DECAY_SHIFT : decay_shift;

    // ══════════════════════════════════════════════════════════════════════
    // Stage 1：衰减 + 累加
    //
    // 每个采样通道依次执行：
    //   1. 检查该通道是否有新脉冲 → 扩展到48位Q36.12格式
    //   2. 累加脉冲到工作状态（或先衰减再累加，由参数控制）
    //   3. 溢出检测
    //   4. 记录输出脉冲状态
    //   5. 应用指数衰减，传给下一通道/周期
    //
    // 处理顺序保证：通道0 → 通道1 → 下一周期通道0 → ...
    // 这形成了连续的时间序列。
    // ══════════════════════════════════════════════════════════════════════
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decay_state    <= {ACC_BITS{1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d <= 5'd0;
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_pipe <= 5'd0;
            enable_pipe <= 1'b0;
            overflow_pipe <= 1'b0;
        end else if (clear) begin
            decay_state    <= {ACC_BITS{1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d <= 5'd0;
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_pipe <= 5'd0;
            enable_pipe <= 1'b0;
            overflow_pipe <= 1'b0;
        end else if (enable) begin
            work_state = decay_state;                        // 继承上一周期末尾的状态
            overflow_next = 1'b0;

            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                // ── 扩展脉冲到 ACC_BITS 位（含 FRAC_BITS 位小数） ──
                if (impulse_valid_vec[i]) begin
                    impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS] <=
                        {{(ACC_BITS-IMP_BITS-FRAC_BITS){1'b0}},
                         impulse_sum_vec[i*IMP_BITS +: IMP_BITS],
                         {FRAC_BITS{1'b0}}};                 // 左移FRAC_BITS位 → 定点小数
                end else begin
                    impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS] <= {ACC_BITS{1'b0}};
                end

                impulse_ext = impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS];

                if (DECAY_BEFORE_ACCUMULATE != 0) begin
                    // 模式1：先衰减 → 再累加新脉冲（更接近物理RC放电）
                    decayed_state = work_state - (work_state >> decay_shift_eff);
                    next_state = decayed_state + impulse_ext;

                    if ((ENABLE_STATE_OVERFLOW != 0) &&
                        (next_state < decayed_state)) begin
                        overflow_next = 1'b1;               // 累加溢出
                    end

                    pulse_state_vec_d[i*ACC_BITS +: ACC_BITS] <= next_state;
                    work_state = next_state;
                end else begin
                    // 模式0（默认）：先累加新脉冲 → 再衰减
                    next_state = work_state + impulse_ext;

                    if ((ENABLE_STATE_OVERFLOW != 0) &&
                        (next_state < work_state)) begin
                        overflow_next = 1'b1;
                    end

                    pulse_state_vec_d[i*ACC_BITS +: ACC_BITS] <= next_state;

                    decayed_state = next_state - (next_state >> decay_shift_eff);
                    work_state = decayed_state;              // 衰减后传给下一通道
                end
            end

            decay_state <= work_state;                       // 保存给下一时钟周期
            output_shift_d <= output_shift;

            // ── 流水线寄存器：将Stage 1结果交给Stage 2 ──
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
    // Stage 2：饱和检查 + 脉冲输出
    //
    // 用寄存器化后的 pulse_state_pipe 做右移缩放和饱和判断。
    // 将48位进位链和饱和判断的归约或逻辑与 Stage 1 的反馈路径
    // 隔离开来，这是满足250MHz时序的关键设计。
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
                // 检查高位是否有非零位（超出PULSE_BITS范围）
                if (|scaled_state[ACC_BITS-1:PULSE_BITS]) begin
                    pulse_vec[i*PULSE_BITS +: PULSE_BITS] <= {PULSE_BITS{1'b1}}; // 钳位到最大
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
