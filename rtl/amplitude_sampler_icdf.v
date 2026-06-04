`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 随机幅度采样器（ICDF 查表法）
//
// 根据泊松时间判定模块输出的事件数量和有效标志，为每个采样通道的
// 每个事件从 ICDF 幅度查找表（amp_lut_multiport）中读取对应的幅度值，
// 再将同一通道内所有事件的幅度累加，得到该通道该时刻的总脉冲高度。
//
// 两种幅度模式（由 amp_lut_en 控制）：
//   amp_lut_en = 0：所有事件使用固定的 fixed_amp 幅度（均匀脉冲高度）
//   amp_lut_en = 1：用幅度RNG的高位作为LUT地址查表得到随机幅度
//
// 查表地址生成：
//   对每个事件的 amp RNG，取其高位 [RNG_BITS-1 - ICDF_ADDR_BITS*(j+1) +: ICDF_ADDR_BITS]
//   作为 LUT 读地址。每个事件用不同的 RNG 位段，保证同一通道内
//   多个事件的幅度相互独立。
//
// 多事件幅度累加（成对加法器树）：
//   为了在单个周期内累加最多 MAX_EVENTS_PER_SAMPLE 个幅度值，
//   采用两两配对 → 汇总的两级加法树。
//   PAIR_COUNT = ceil(MAX_EVENTS_PER_SAMPLE / 2) 个配对累加器，
//   每个配对累加两个相邻事件的幅度，汇总再累加配对结果。
//
// 流水线设计（3级）：
//   Stage 1（addr_gen）： 事件标志 + RNG → LUT读地址（组合逻辑）
//   Stage 2（bram_read）：BRAM 同步读取（1周期延迟），数据寄存器化
//   Stage 3（accumulate）：配对加法 → 汇总 → 输出 impulse_sum
//
// BRAM数据寄存器化：
//   icdf_rd_data_d 将 BRAM 的 Tco（Artix-7 约2.1ns）从累加路径中断开，
//   同时延迟控制信号（event_valid_d2, event_count_d2）以对齐数据。
// ═══════════════════════════════════════════════════════════════════════════
module amplitude_sampler_icdf #(
    parameter integer SAMPLES_PER_CLK      = 2,            // 每时钟周期并行采样通道数
    parameter integer RNG_BITS             = 64,           // 随机数位宽
    parameter integer ICDF_ADDR_BITS       = 14,           // LUT地址位宽（14位→16K深）
    parameter integer AMP_BITS             = 16,           // 幅度数据位宽
    parameter integer IMP_BITS             = 24,           // 脉冲累加位宽（含饱和保护）
    parameter integer K_BITS               = 3,            // 每通道事件计数位宽
    parameter integer MAX_EVENTS_PER_SAMPLE = 4,           // 每个采样点最大事件数
    parameter integer AMP_READ_PORTS       = SAMPLES_PER_CLK * MAX_EVENTS_PER_SAMPLE
) (
    input  wire                                                 clk,
    input  wire                                                 rst_n,
    input  wire                                                 enable,             // 全局使能
    input  wire                                                 amp_lut_en,         // 0=固定幅度, 1=ICDF查表
    input  wire [AMP_BITS-1:0]                                  fixed_amp,          // 固定幅度值
    input  wire [SAMPLES_PER_CLK-1:0]                           event_valid_vec,    // 事件有效标志
    input  wire [SAMPLES_PER_CLK*K_BITS-1:0]                    event_count_vec,    // 每通道事件计数
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0]                  rng_amp_vec,        // 幅度随机数向量
    output wire [AMP_READ_PORTS*ICDF_ADDR_BITS-1:0]             icdf_rd_addr_vec,   // LUT读地址向量
    input  wire [AMP_READ_PORTS*AMP_BITS-1:0]                   icdf_rd_data_vec,   // LUT读数据向量
    output reg  [SAMPLES_PER_CLK-1:0]                           impulse_valid_vec,  // 脉冲有效标志
    output reg  [SAMPLES_PER_CLK*K_BITS-1:0]                    impulse_count_vec,  // 脉冲计数
    output reg  [SAMPLES_PER_CLK*IMP_BITS-1:0]                  impulse_sum_vec     // 脉冲幅度总和
);

    // ── Stage 2 控制信号寄存器 ──
    reg [SAMPLES_PER_CLK-1:0]            event_valid_d;
    reg [SAMPLES_PER_CLK*K_BITS-1:0]     event_count_d;
    reg                                  amp_lut_en_d;
    reg [AMP_BITS-1:0]                   fixed_amp_d;

    // ── RNG幅度向量延迟──
    reg [SAMPLES_PER_CLK*RNG_BITS-1:0]   rng_amp_d;

    // ── Stage 3 BRAM数据寄存器 ──
    reg [AMP_READ_PORTS*AMP_BITS-1:0]    icdf_rd_data_d;       // BRAM读出数据寄存器
    reg [SAMPLES_PER_CLK-1:0]            event_valid_d2;       // 对齐后的有效标志
    reg [SAMPLES_PER_CLK*K_BITS-1:0]     event_count_d2;       // 对齐后的事件计数
    reg                                  amp_lut_en_d2;
    reg [AMP_BITS-1:0]                   fixed_amp_d2;

    // ── 累加参数 ──
    localparam integer ACC_WIDTH  = IMP_BITS + 8;              // 内部累加位宽（含8位余量防溢出）
    localparam integer PAIR_COUNT = (MAX_EVENTS_PER_SAMPLE + 1) / 2; // 配对累加器数量

    // ── Stage 3 输出流水线 ──
    reg [SAMPLES_PER_CLK-1:0]                       impulse_valid_pipe;
    reg [SAMPLES_PER_CLK*K_BITS-1:0]                impulse_count_pipe;
    reg [SAMPLES_PER_CLK*PAIR_COUNT*ACC_WIDTH-1:0]  amp_pair_sum_d;      // 配对累加结果

    genvar gi;
    genvar gj;

    // ══════════════════════════════════════════════════════════════════════
    // Stage 1：生成 LUT 读地址（组合逻辑）
    //
    // 对每个采样通道的每个事件槽位，取 amp RNG 的不同位段作为地址。
    // 第 j 个事件用 bits [RNG_BITS-1-j*ADDR_BITS -: ADDR_BITS]。
    // 无效的事件槽位地址设为全零（不关心，反正不用）。
    // ══════════════════════════════════════════════════════════════════════
    generate
        for (gi = 0; gi < SAMPLES_PER_CLK; gi = gi + 1) begin : g_addr
            wire [RNG_BITS-1:0] rng_i;
            wire [K_BITS-1:0]   event_count_i;

            assign rng_i = rng_amp_d[(gi+1)*RNG_BITS-1:gi*RNG_BITS];
            assign event_count_i = event_count_vec[(gi+1)*K_BITS-1:gi*K_BITS];

            for (gj = 0; gj < MAX_EVENTS_PER_SAMPLE; gj = gj + 1) begin : g_slot
                localparam integer PORT_INDEX = gi * MAX_EVENTS_PER_SAMPLE + gj;

                // 仅当LUT使能、通道有效、且槽位索引小于事件数时，才用RNG位段作地址
                assign icdf_rd_addr_vec[(PORT_INDEX+1)*ICDF_ADDR_BITS-1:PORT_INDEX*ICDF_ADDR_BITS] =
                    (amp_lut_en && event_valid_vec[gi] && (event_count_i > gj)) ?
                    rng_i[RNG_BITS-1-(gj*ICDF_ADDR_BITS) -: ICDF_ADDR_BITS] :
                    {ICDF_ADDR_BITS{1'b0}};
            end
        end
    endgenerate

    integer i;
    integer j;
    integer pair_idx;
    integer slot_idx;
    reg [K_BITS-1:0]   event_count_i;
    reg [ACC_WIDTH-1:0] amp_pair_acc;                          // 配对累加器
    reg [ACC_WIDTH-1:0] amp_total_acc;                         // 通道总累加器

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_valid_d     <= {SAMPLES_PER_CLK{1'b0}};
            event_count_d     <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            amp_lut_en_d      <= 1'b0;
            fixed_amp_d       <= {AMP_BITS{1'b0}};
            rng_amp_d         <= {(SAMPLES_PER_CLK*RNG_BITS){1'b0}};
            // BRAM数据流水线
            icdf_rd_data_d    <= {(AMP_READ_PORTS*AMP_BITS){1'b0}};
            event_valid_d2    <= {SAMPLES_PER_CLK{1'b0}};
            event_count_d2    <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            amp_lut_en_d2     <= 1'b0;
            fixed_amp_d2      <= {AMP_BITS{1'b0}};
            // 输出流水线
            impulse_valid_pipe <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_pipe <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            amp_pair_sum_d     <= {(SAMPLES_PER_CLK*PAIR_COUNT*ACC_WIDTH){1'b0}};
            impulse_valid_vec <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_vec <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_sum_vec   <= {(SAMPLES_PER_CLK*IMP_BITS){1'b0}};
        end else if (enable) begin
            // ── Stage 2：寄存控制信号和RNG ──
            rng_amp_d        <= rng_amp_vec;
            event_valid_d <= event_valid_vec;
            event_count_d <= event_count_vec;
            amp_lut_en_d  <= amp_lut_en;
            fixed_amp_d   <= fixed_amp;

            // ── Stage 3：BRAM数据寄存器（断开Tco）+ 累加 ──
            icdf_rd_data_d <= icdf_rd_data_vec;
            event_valid_d2 <= event_valid_d;
            event_count_d2 <= event_count_d;
            amp_lut_en_d2  <= amp_lut_en_d;
            fixed_amp_d2   <= fixed_amp_d;

            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                event_count_i = event_count_d2[i*K_BITS +: K_BITS];
                impulse_valid_pipe[i] <= event_valid_d2[i];
                impulse_count_pipe[i*K_BITS +: K_BITS] <= event_count_i;

                // ── 配对累加：每两个相邻事件一组 ──
                for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
                    amp_pair_acc = {ACC_WIDTH{1'b0}};

                    for (j = 0; j < 2; j = j + 1) begin
                        slot_idx = pair_idx * 2 + j;
                        if ((slot_idx < MAX_EVENTS_PER_SAMPLE) &&
                            event_valid_d2[i] && (slot_idx < event_count_i)) begin
                            if (amp_lut_en_d2) begin
                                // 查表模式：从BRAM读出的数据
                                amp_pair_acc = amp_pair_acc +
                                    {{(ACC_WIDTH-AMP_BITS){1'b0}},
                                     icdf_rd_data_d[(i*MAX_EVENTS_PER_SAMPLE+slot_idx)*AMP_BITS +: AMP_BITS]};
                            end else begin
                                // 固定幅度模式
                                amp_pair_acc = amp_pair_acc +
                                    {{(ACC_WIDTH-AMP_BITS){1'b0}}, fixed_amp_d2};
                            end
                        end
                    end

                    amp_pair_sum_d[(i*PAIR_COUNT+pair_idx)*ACC_WIDTH +: ACC_WIDTH] <= amp_pair_acc;
                end
            end

            // ── 输出级：汇总配对结果 → 饱和保护 → 输出 ──
            impulse_valid_vec <= impulse_valid_pipe;
            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                event_count_i = impulse_count_pipe[i*K_BITS +: K_BITS];
                impulse_count_vec[i*K_BITS +: K_BITS] <= event_count_i;
                amp_total_acc = {ACC_WIDTH{1'b0}};

                // 汇总所有配对结果
                for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
                    amp_total_acc = amp_total_acc +
                        amp_pair_sum_d[(i*PAIR_COUNT+pair_idx)*ACC_WIDTH +: ACC_WIDTH];
                end

                if (impulse_valid_pipe[i] && (event_count_i != {K_BITS{1'b0}})) begin
                    // 饱和保护：累加结果超出 IMP_BITS 范围时钳位到最大值
                    if (|amp_total_acc[ACC_WIDTH-1:IMP_BITS]) begin
                        impulse_sum_vec[i*IMP_BITS +: IMP_BITS] <= {IMP_BITS{1'b1}};
                    end else begin
                        impulse_sum_vec[i*IMP_BITS +: IMP_BITS] <= amp_total_acc[IMP_BITS-1:0];
                    end
                end else begin
                    impulse_sum_vec[i*IMP_BITS +: IMP_BITS] <= {IMP_BITS{1'b0}};
                end
            end
        end else begin
            // enable=0 时所有寄存器清零
            event_valid_d     <= {SAMPLES_PER_CLK{1'b0}};
            event_count_d     <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            icdf_rd_data_d    <= {(AMP_READ_PORTS*AMP_BITS){1'b0}};
            event_valid_d2    <= {SAMPLES_PER_CLK{1'b0}};
            event_count_d2    <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_valid_pipe <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_pipe <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            amp_pair_sum_d     <= {(SAMPLES_PER_CLK*PAIR_COUNT*ACC_WIDTH){1'b0}};
            impulse_valid_vec <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_vec <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_sum_vec   <= {(SAMPLES_PER_CLK*IMP_BITS){1'b0}};
        end
    end

endmodule
