`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 核事件波形生成器核心引擎（10 Mcps）
//
// 完整的核辐射探测器随机脉冲信号生成引擎。每个时钟周期并行产生
// SAMPLES_PER_CLK 个时间连续采样值，模拟随机泊松到达的核粒子
// 与探测器相互作用产生的指数衰减脉冲序列。
//
// 时钟假设：
//   clk = 250 MHz（独立调试模式）/ 125 MHz（DAC通道模式）
//   SAMPLES_PER_CLK = 2，等效采样率 = 500 MSa/s
//
// ═══════════════════════════════════════════════════════════════════════════
//
// 内部子模块连接（数据流）：
//
//   ┌──────────────┐
//   │  cfg_regfile │ ← 配置总线（仅 STATIC_CONFIG=0 时启用）
//   │  _10mcps     │
//   └──────┬───────┘
//          │ 控制参数（run_enable, decay_shift, output_shift, ...）
//          ↓
//   ┌──────────────────────────────────────────────────────────────┐
//   │ ① rng_bank_10mcps                                           │
//   │    生成3组独立随机数流：                                      │
//   │      time RNG  → poisson_time_multievent                     │
//   │      amp RNG   → amplitude_sampler_icdf (经3拍延迟对齐)      │
//   │      noise RNG → noise_baseline_core                         │
//   └──────┬───────────────────────────────────────────────────────┘
//          │   event_valid_vec + event_count_vec
//          ↓
//   ┌──────────────────────────────────────────────────────────────┐
//   │ ② amplitude_sampler_icdf + amp_lut_multiport (ICDF LUT)     │
//   │    用 amp RNG 查表得到随机幅度 → 多事件累加 → impulse_sum    │
//   └──────┬───────────────────────────────────────────────────────┘
//          │   impulse_valid_vec + impulse_sum_vec
//          ↓
//   ┌──────────────────────────────────────────────────────────────┐
//   │ ③ exp_decay_core / exp_decay_bi_core（由 DECAY_MODE 选择）   │
//   │    指数衰减 IIR 滤波器 → 将瞬时脉冲扩展为指数衰减脉冲序列    │
//   └──────┬───────────────────────────────────────────────────────┘
//          │   pulse_vec + noise_vec
//          ↓
//   ┌──────────────────────────────────────────────────────────────┐
//   │ ④ mixer_saturator_simple                                    │
//   │    pulse + baseline_offset + noise → 钳位到 DAC 范围         │
//   └──────┬───────────────────────────────────────────────────────┘
//          │   dac_sample_vec
//          ↓
//       输出到 DAC
//
// ═══════════════════════════════════════════════════════════════════════════
//
// 两种配置模式：
//   STATIC_CONFIG=1：所有参数硬编码（用于 DAC 通道的固定部署）
//   STATIC_CONFIG=0：通过 cfg_regfile 运行时配置总线动态调整参数
//
// 两种衰减模式：
//   DECAY_MODE=0：单指数衰减 exp(-t/τ) → exp_decay_core
//   DECAY_MODE=1：双指数衰减 exp(-t/τf)-exp(-t/τr) → exp_decay_bi_core
//
// ═══════════════════════════════════════════════════════════════════════════
module nuc_event_gen_10mcps_top #(
    // ── 系统参数 ──
    parameter integer SAMPLES_PER_CLK       = 2,             // 每时钟周期并行采样通道数
    parameter integer CORE_CLK_HZ           = 250000000,     // 核心时钟频率（Hz）
    parameter integer MAX_RATE_CPS          = 10000000,      // 最大事件速率（counts per second）

    // ── 位宽参数 ──
    parameter integer RNG_BITS              = 64,            // 随机数位宽
    parameter integer DAC_BITS              = 16,            // DAC 输出位宽
    parameter integer AMP_BITS              = 16,            // 幅度LUT位宽
    parameter integer IMP_BITS              = 24,            // 脉冲累加位宽
    parameter integer ACC_BITS              = 48,            // 内部累加器位宽（36位整数+12位小数）
    parameter integer PULSE_BITS            = 32,            // 脉冲输出位宽
    parameter integer ICDF_ADDR_BITS        = 14,            // ICDF LUT地址位宽（14位→16K深度）
    parameter integer K_BITS                = 3,             // 事件计数位宽
    parameter integer MAX_EVENTS_PER_SAMPLE = 4,             // 每采样最大事件数
    parameter integer AMP_READ_PORTS        = SAMPLES_PER_CLK * MAX_EVENTS_PER_SAMPLE,
    parameter integer NOISE_BITS            = 16,            // 噪声位宽
    parameter integer FRAC_BITS             = 12,            // 定点小数位宽

    // ── 单指数衰减默认参数 ──
    parameter [4:0]  DEFAULT_DECAY_SHIFT     = 5'd8,        // 默认衰减速度
    parameter [4:0]  DEFAULT_OUTPUT_SHIFT    = 5'd12,       // 默认输出缩放
    parameter [4:0]  DEFAULT_NOISE_SHIFT     = 5'd8,        // 默认噪声缩放

    // ── 高级控制参数 ──
    parameter integer DECAY_BEFORE_ACCUMULATE = 0,           // 0=先累加后衰减, 1=先衰减后累加
    parameter [4:0]  FIXED_DECAY_SHIFT       = 5'd0,        // 固定衰减量（非零时覆盖配置）
    parameter integer ENABLE_STATE_OVERFLOW  = 1,            // 状态溢出检测
    parameter integer ENABLE_STATUS_COUNTERS = 1,            // 事件统计计数器使能
    parameter integer STATIC_CONFIG          = 0,            // 0=运行时配置, 1=静态配置

    // ── 静态配置参数（STATIC_CONFIG=1时生效） ──
    parameter integer STATIC_RUN_ENABLE      = 1,            // 静态运行使能
    parameter [31:0] STATIC_RATE_THRESHOLD_Q32 = 32'd0,     // 静态速率阈值（0=用计算值）
    parameter integer STATIC_AMP_LUT_EN      = 1,            // 静态LUT使能
    parameter [15:0] STATIC_FIXED_AMP        = 16'd8192,     // 静态固定幅度
    parameter [4:0]  STATIC_DECAY_SHIFT      = DEFAULT_DECAY_SHIFT,
    parameter [4:0]  STATIC_OUTPUT_SHIFT     = DEFAULT_OUTPUT_SHIFT,
    parameter signed [31:0] STATIC_BASELINE_OFFSET = 32'sd0,
    parameter integer STATIC_NOISE_ENABLE    = 0,
    parameter [4:0]  STATIC_NOISE_SHIFT      = DEFAULT_NOISE_SHIFT,

    // ── RNG 参数 ──
    parameter [63:0] RNG_SEED_SALT           = 64'd0,       // 种子盐值
    parameter integer DECAY_MODE             = 0,            // 0=单指数, 1=双指数
    parameter [4:0]  STATIC_RISE_SHIFT      = 5'd5,          // 静态快时间常数（双指数模式）
    parameter [4:0]  STATIC_FALL_SHIFT      = 5'd9,          // 静态慢时间常数（双指数模式）

    // ── 速率阈值（Q0.32格式）：λ = MAX_RATE_CPS / (CORE_CLK_HZ × SAMPLES_PER_CLK) ──
    parameter [31:0] MAX_RATE_THRESHOLD_Q32 =
        ((((64'd1 * MAX_RATE_CPS) << 32) +
          (((64'd1 * CORE_CLK_HZ) * SAMPLES_PER_CLK) / 2)) /
         ((64'd1 * CORE_CLK_HZ) * SAMPLES_PER_CLK))
) (
    // ── 时钟和复位 ──
    input  wire                                clk,
    input  wire                                rst_n,

    // ── 配置总线接口 ──
    input  wire                                cfg_valid,
    input  wire                                cfg_write,
    input  wire [7:0]                          cfg_addr,
    input  wire [31:0]                         cfg_wdata,
    output wire [31:0]                         cfg_rdata,
    output wire                                cfg_ready,

    // ── 幅度LUT配置接口 ──
    input  wire                                amp_lut_we,
    input  wire [ICDF_ADDR_BITS-1:0]           amp_lut_addr,
    input  wire [AMP_BITS-1:0]                 amp_lut_wdata,

    // ── 输出接口 ──
    output wire [SAMPLES_PER_CLK*DAC_BITS-1:0] dac_sample_vec,   // DAC采样向量
    output wire                                dac_sample_valid,  // 采样有效
    output wire [SAMPLES_PER_CLK-1:0]          event_valid_vec,   // 事件有效（调试用）
    output wire [SAMPLES_PER_CLK-1:0]          impulse_valid_vec, // 脉冲有效（调试用）
    output wire [SAMPLES_PER_CLK-1:0]          saturation_vec,    // 饱和标志（调试用）
    output wire [31:0]                         status_word        // 状态字
);

    // ── 辅助函数：计算32位值的有效位宽 ──
    function integer bit_width_u32;
        input [31:0] value;
        integer bit_idx;
        begin
            bit_width_u32 = 1;
            for (bit_idx = 0; bit_idx < 32; bit_idx = bit_idx + 1) begin
                if (value[bit_idx])
                    bit_width_u32 = bit_idx + 1;
            end
        end
    endfunction

    localparam integer RATE_THRESHOLD_BITS = bit_width_u32(MAX_RATE_THRESHOLD_Q32);

    // ══════════════════════════════════════════════════════════════════════
    // 控制信号
    // ══════════════════════════════════════════════════════════════════════
    wire        run_enable;
    wire        soft_reset_pulse;
    wire [31:0] rate_threshold_q32;
    wire        amp_lut_en;
    wire [15:0] fixed_amp;
    wire [4:0]  decay_shift;
    wire [4:0]  output_shift;
    wire signed [31:0] baseline_offset;
    wire        noise_enable;
    wire [4:0]  noise_shift;
    wire [4:0]  rise_shift;
    wire [4:0]  fall_shift;
    wire        seed_load;
    wire [7:0]  seed_sel;
    wire        seed_zero;
    wire [63:0] seed_data;

    // ══════════════════════════════════════════════════════════════════════
    // 状态计数器信号
    // ══════════════════════════════════════════════════════════════════════
    wire [63:0] sample_count;
    wire [63:0] candidate_count;
    wire [63:0] emitted_count;
    wire [63:0] saturation_count;
    wire [31:0] counter_status_word;

    // ══════════════════════════════════════════════════════════════════════
    // RNG 输出向量
    // ══════════════════════════════════════════════════════════════════════
    wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_time_vec;
    wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec;
    wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_noise_vec;
    wire [SAMPLES_PER_CLK*K_BITS-1:0]   event_count_vec;

    // ══════════════════════════════════════════════════════════════════════
    // RNG幅度流水线对齐
    //
    // poisson_time_multievent 有4级流水线延迟，amp RNG 必须同步延迟
    // 以使 event_valid/event_count 与对应的 amp RNG 值在时间上对齐。
    // 延迟量：event判断有4级 → rng_amp 需延迟3拍（第1拍在sampler内部对齐）
    // ══════════════════════════════════════════════════════════════════════
    reg [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec_d1;
    reg [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec_d2;
    reg [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec_d3;
    wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec_delayed = rng_amp_vec_d3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rng_amp_vec_d1 <= {(SAMPLES_PER_CLK*RNG_BITS){1'b0}};
            rng_amp_vec_d2 <= {(SAMPLES_PER_CLK*RNG_BITS){1'b0}};
            rng_amp_vec_d3 <= {(SAMPLES_PER_CLK*RNG_BITS){1'b0}};
        end else begin
            rng_amp_vec_d1 <= rng_amp_vec;
            rng_amp_vec_d2 <= rng_amp_vec_d1;
            rng_amp_vec_d3 <= rng_amp_vec_d2;
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    // ICDF LUT 和脉冲信号
    // ══════════════════════════════════════════════════════════════════════
    wire [AMP_READ_PORTS*ICDF_ADDR_BITS-1:0]  icdf_rd_addr_vec;
    wire [AMP_READ_PORTS*AMP_BITS-1:0]        icdf_rd_data_vec;
    wire [SAMPLES_PER_CLK*IMP_BITS-1:0]       impulse_sum_vec;
    wire [SAMPLES_PER_CLK*K_BITS-1:0]         impulse_count_vec;
    wire [SAMPLES_PER_CLK*PULSE_BITS-1:0]     pulse_vec;
    wire signed [SAMPLES_PER_CLK*NOISE_BITS-1:0] noise_vec;
    wire state_overflow;

    assign dac_sample_valid = run_enable;
    assign status_word      = counter_status_word;

    // ══════════════════════════════════════════════════════════════════════
    // 配置源选择
    //
    // STATIC_CONFIG=1：将所有控制信号硬连线到静态参数
    // STATIC_CONFIG=0：由 cfg_regfile 模块提供动态配置
    // ══════════════════════════════════════════════════════════════════════
    generate
        if (STATIC_CONFIG != 0) begin : g_static_config
            assign cfg_rdata           = 32'd0;
            assign cfg_ready           = 1'b1;
            assign run_enable          = (STATIC_RUN_ENABLE != 0);
            assign soft_reset_pulse    = 1'b0;
            assign rate_threshold_q32  = (STATIC_RATE_THRESHOLD_Q32 != 32'd0) ?
                                         STATIC_RATE_THRESHOLD_Q32 : MAX_RATE_THRESHOLD_Q32;
            assign amp_lut_en          = (STATIC_AMP_LUT_EN != 0);
            assign fixed_amp           = STATIC_FIXED_AMP;
            assign decay_shift         = STATIC_DECAY_SHIFT;
            assign output_shift        = STATIC_OUTPUT_SHIFT;
            assign baseline_offset     = STATIC_BASELINE_OFFSET;
            assign noise_enable        = (STATIC_NOISE_ENABLE != 0);
            assign noise_shift         = STATIC_NOISE_SHIFT;
            assign rise_shift          = STATIC_RISE_SHIFT;
            assign fall_shift          = STATIC_FALL_SHIFT;
            assign seed_load           = 1'b0;
            assign seed_sel            = 8'd0;
            assign seed_zero           = 1'b1;
            assign seed_data           = 64'd0;
        end else begin : g_cfg_regfile
            cfg_regfile_10mcps #(
                .MAX_RATE_THRESHOLD_Q32(MAX_RATE_THRESHOLD_Q32),
                .DEFAULT_DECAY_SHIFT(DEFAULT_DECAY_SHIFT),
                .DEFAULT_OUTPUT_SHIFT(DEFAULT_OUTPUT_SHIFT),
                .DEFAULT_NOISE_SHIFT(DEFAULT_NOISE_SHIFT)
            ) u_cfg (
                .clk(clk),
                .rst_n(rst_n),
                .cfg_valid(cfg_valid),
                .cfg_write(cfg_write),
                .cfg_addr(cfg_addr),
                .cfg_wdata(cfg_wdata),
                .cfg_rdata(cfg_rdata),
                .cfg_ready(cfg_ready),
                .run_enable(run_enable),
                .soft_reset_pulse(soft_reset_pulse),
                .rate_threshold_q32(rate_threshold_q32),
                .amp_lut_en(amp_lut_en),
                .fixed_amp(fixed_amp),
                .decay_shift(decay_shift),
                .output_shift(output_shift),
                .baseline_offset(baseline_offset),
                .noise_enable(noise_enable),
                .noise_shift(noise_shift),
                .seed_load(seed_load),
                .rise_shift(rise_shift),
                .fall_shift(fall_shift),
                .seed_sel(seed_sel),
                .seed_zero(seed_zero),
                .seed_data(seed_data),
                .sample_count(sample_count),
                .candidate_count(candidate_count),
                .emitted_count(emitted_count),
                .saturation_count(saturation_count),
                .status_word(counter_status_word)
            );
        end
    endgenerate

    // ══════════════════════════════════════════════════════════════════════
    // 子模块实例化
    // ══════════════════════════════════════════════════════════════════════

    // ── ① 随机数发生器阵列 ──
    rng_bank_10mcps #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .RNG_BITS(RNG_BITS),
        .SEED_SALT(RNG_SEED_SALT)
    ) u_rng (
        .clk(clk),
        .rst_n(rst_n),
        .enable(run_enable),
        .seed_load(seed_load),
        .seed_sel(seed_sel),
        .seed_zero(seed_zero),
        .seed_data(seed_data),
        .rng_time_vec(rng_time_vec),
        .rng_amp_vec(rng_amp_vec),
        .rng_noise_vec(rng_noise_vec)
    );

    // ── ② 泊松时间多事件判定 ──
    poisson_time_multievent #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .RNG_BITS(RNG_BITS),
        .K_BITS(K_BITS),
        .MAX_EVENTS_PER_SAMPLE(MAX_EVENTS_PER_SAMPLE),
        .RATE_THRESHOLD_BITS(RATE_THRESHOLD_BITS)
    ) u_timebase (
        .clk(clk),
        .rst_n(rst_n),
        .enable(run_enable),
        .rate_threshold_q32(rate_threshold_q32),
        .rng_time_vec(rng_time_vec),
        .event_valid_vec(event_valid_vec),
        .event_count_vec(event_count_vec)
    );

    // ── ③ ICDF 幅度查找表（多端口BRAM复制） ──
    amp_lut_multiport #(
        .PORTS(AMP_READ_PORTS),
        .ADDR_BITS(ICDF_ADDR_BITS),
        .DATA_BITS(AMP_BITS),
        .INIT_RAMP(1),
        .INIT_FILE("NONE")
    ) u_amp_lut (
        .clk(clk),
        .wr_en(amp_lut_we),
        .wr_addr(amp_lut_addr),
        .wr_data(amp_lut_wdata),
        .rd_addr_vec(icdf_rd_addr_vec),
        .rd_data_vec(icdf_rd_data_vec)
    );

    // ── ④ 幅度采样器 ──
    amplitude_sampler_icdf #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .RNG_BITS(RNG_BITS),
        .ICDF_ADDR_BITS(ICDF_ADDR_BITS),
        .AMP_BITS(AMP_BITS),
        .IMP_BITS(IMP_BITS),
        .K_BITS(K_BITS),
        .MAX_EVENTS_PER_SAMPLE(MAX_EVENTS_PER_SAMPLE),
        .AMP_READ_PORTS(AMP_READ_PORTS)
    ) u_amp_sampler (
        .clk(clk),
        .rst_n(rst_n),
        .enable(run_enable),
        .amp_lut_en(amp_lut_en),
        .fixed_amp(fixed_amp),
        .event_valid_vec(event_valid_vec),
        .event_count_vec(event_count_vec),
        .rng_amp_vec(rng_amp_vec_delayed),
        .icdf_rd_addr_vec(icdf_rd_addr_vec),
        .icdf_rd_data_vec(icdf_rd_data_vec),
        .impulse_valid_vec(impulse_valid_vec),
        .impulse_count_vec(impulse_count_vec),
        .impulse_sum_vec(impulse_sum_vec)
    );

    // ── ⑤ 指数衰减整形（单指数或双指数，由 DECAY_MODE 选择） ──
    generate
        if (DECAY_MODE == 0) begin : g_single_exp_decay
            exp_decay_core #(
                .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
                .IMP_BITS(IMP_BITS),
                .ACC_BITS(ACC_BITS),
                .PULSE_BITS(PULSE_BITS),
                .FRAC_BITS(FRAC_BITS),
                .DECAY_BEFORE_ACCUMULATE(DECAY_BEFORE_ACCUMULATE),
                .FIXED_DECAY_SHIFT(FIXED_DECAY_SHIFT),
                .ENABLE_STATE_OVERFLOW(ENABLE_STATE_OVERFLOW)
            ) u_decay (
                .clk(clk),
                .rst_n(rst_n),
                .enable(run_enable),
                .clear(soft_reset_pulse),
                .decay_shift(decay_shift),
                .output_shift(output_shift),
                .impulse_valid_vec(impulse_valid_vec),
                .impulse_sum_vec(impulse_sum_vec),
                .pulse_vec(pulse_vec),
                .state_overflow(state_overflow)
            );
        end else begin : g_bi_exp_decay
            exp_decay_bi_core #(
                .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
                .IMP_BITS(IMP_BITS),
                .ACC_BITS(ACC_BITS),
                .PULSE_BITS(PULSE_BITS),
                .FRAC_BITS(FRAC_BITS),
                .ENABLE_STATE_OVERFLOW(ENABLE_STATE_OVERFLOW)
            ) u_decay (
                .clk(clk),
                .rst_n(rst_n),
                .enable(run_enable),
                .clear(soft_reset_pulse),
                .rise_shift(rise_shift),
                .fall_shift(fall_shift),
                .output_shift(output_shift),
                .impulse_valid_vec(impulse_valid_vec),
                .impulse_sum_vec(impulse_sum_vec),
                .pulse_vec(pulse_vec),
                .state_overflow(state_overflow)
            );
        end
    endgenerate

    // ── ⑥ 噪声源 ──
    noise_baseline_core #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .RNG_BITS(RNG_BITS),
        .NOISE_BITS(NOISE_BITS)
    ) u_noise (
        .clk(clk),
        .rst_n(rst_n),
        .enable(run_enable),
        .noise_enable(noise_enable),
        .noise_shift(noise_shift),
        .rng_noise_vec(rng_noise_vec),
        .noise_vec(noise_vec)
    );

    // ── ⑦ 混音器 + 饱和限幅 ──
    mixer_saturator_simple #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .PULSE_BITS(PULSE_BITS),
        .NOISE_BITS(NOISE_BITS),
        .DAC_BITS(DAC_BITS)
    ) u_mixer (
        .clk(clk),
        .rst_n(rst_n),
        .enable(run_enable),
        .baseline_offset(baseline_offset),
        .pulse_vec(pulse_vec),
        .noise_vec(noise_vec),
        .dac_sample_vec(dac_sample_vec),
        .saturation_vec(saturation_vec)
    );

    // ── ⑧ 事件统计计数器（可选） ──
    generate
        if (ENABLE_STATUS_COUNTERS != 0) begin : g_status_counters
            event_counters_10mcps #(
                .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
                .K_BITS(K_BITS)
            ) u_counters (
                .clk(clk),
                .rst_n(rst_n),
                .enable(run_enable),
                .clear(soft_reset_pulse),
                .event_valid_vec(event_valid_vec),
                .event_count_vec(event_count_vec),
                .impulse_valid_vec(impulse_valid_vec),
                .impulse_count_vec(impulse_count_vec),
                .saturation_vec(saturation_vec),
                .state_overflow(state_overflow),
                .sample_count(sample_count),
                .candidate_count(candidate_count),
                .emitted_count(emitted_count),
                .saturation_count(saturation_count),
                .status_word(counter_status_word)
            );
        end else begin : g_no_status_counters
            assign sample_count        = 64'd0;
            assign candidate_count     = 64'd0;
            assign emitted_count       = 64'd0;
            assign saturation_count    = 64'd0;
            assign counter_status_word = 32'd0;
        end
    endgenerate

endmodule
