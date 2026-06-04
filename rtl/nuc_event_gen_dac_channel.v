`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 单 DAC 通道生成器封装
//
// 将一个 nuc_event_gen_10mcps_top 核心引擎封装为一个独立的 AD9747
// DAC 输出通道。运行在 125 MHz，每时钟周期产生2个并行采样（sample_pair）。
//
// 参数传递：
//   所有核心参数均从此模块的参数列表透传到内部 nuc_event_gen_10mcps_top，
//   使得在 io_top 层级可以为每个 DAC 通道独立设置参数。
//
// 配置模式：
//   采用 STATIC_CONFIG=1 静态配置模式——所有参数硬编码/参数化，
//   不使用 cfg_regfile 运行时总线。适合固定参数的 FPGA 部署场景。
//
// sample_toggle：
//   每收到一个有效采样对，翻转一次。可用于调试和外部对齐。
// ═══════════════════════════════════════════════════════════════════════════
module nuc_event_gen_dac_channel #(
    parameter integer CORE_CLK_HZ           = 125000000,     // 核心时钟频率（Hz）
    parameter integer MAX_RATE_CPS          = 10000000,      // 最大事件速率（cps）
    parameter integer RNG_BITS              = 64,            // 随机数位宽
    parameter integer DAC_BITS              = 16,            // DAC数据位宽
    parameter integer AMP_BITS              = 16,            // 幅度LUT数据位宽
    parameter integer IMP_BITS              = 24,            // 脉冲累加位宽
    parameter integer ACC_BITS              = 48,            // 内部累加器位宽
    parameter integer PULSE_BITS            = 32,            // 脉冲输出位宽
    parameter integer ICDF_ADDR_BITS        = 14,            // ICDF LUT地址位宽
    parameter integer K_BITS                = 3,             // 事件计数位宽
    parameter integer MAX_EVENTS_PER_SAMPLE = 3,             // 每采样最大事件数
    parameter integer NOISE_BITS            = 16,            // 噪声位宽
    parameter integer FRAC_BITS             = 12,            // 定点小数位宽
    parameter [4:0]  DECAY_SHIFT            = 5'd4,         // 单指数衰减速度
    parameter [4:0]  OUTPUT_SHIFT           = 5'd14,        // 输出幅度缩放
    parameter integer AMP_LUT_EN            = 1,             // 幅度LUT使能（0=固定幅度）
    parameter [15:0] FIXED_AMP              = 16'd8192,      // 固定幅度值
    parameter signed [31:0] BASELINE_OFFSET = 32'sd0,       // 基线偏移（有符号）
    parameter integer NOISE_ENABLE          = 0,             // 噪声使能
    parameter [4:0]  NOISE_SHIFT            = 5'd8,         // 噪声幅度缩放
    parameter integer DECAY_MODE            = 0,             // 0=单指数, 1=双指数
    parameter [4:0]  RISE_SHIFT             = 5'd5,         // 双指数快时间常数
    parameter [4:0]  FALL_SHIFT             = 5'd9,         // 双指数慢时间常数
    parameter [63:0] RNG_SEED_SALT          = 64'd0         // RNG种子盐值（区分通道）
) (
    input  wire                      clk_125m,              // 125 MHz 核心时钟
    input  wire                      rst_n,                 // 复位（低有效）
    input  wire                      enable,                // 通道使能
    output wire [2*DAC_BITS-1:0]     sample_pair,           // 采样对 {lane1, lane0}
    output wire                      sample_valid,          // 采样对有效
    output reg                       sample_toggle          // 采样翻转指示（调试用）
);

    localparam integer SAMPLES_PER_CLK = 2;                  // 固定：每周期2个采样

    // ── 未使用信号（静态配置模式不需要总线接口） ──
    wire [31:0] cfg_rdata_unused;
    wire        cfg_ready_unused;
    wire [SAMPLES_PER_CLK-1:0] event_valid_unused;
    wire [SAMPLES_PER_CLK-1:0] impulse_valid_unused;
    wire [SAMPLES_PER_CLK-1:0] saturation_unused;
    wire [31:0] status_unused;

    // ── 采样翻转计数：每次有效输出翻转一次 ──
    always @(posedge clk_125m or negedge rst_n) begin
        if (!rst_n) begin
            sample_toggle <= 1'b0;
        end else if (enable && sample_valid) begin
            sample_toggle <= ~sample_toggle;
        end
    end

    // ── 核心波形引擎实例 ──
    nuc_event_gen_10mcps_top #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .CORE_CLK_HZ(CORE_CLK_HZ),
        .MAX_RATE_CPS(MAX_RATE_CPS),
        .RNG_BITS(RNG_BITS),
        .DAC_BITS(DAC_BITS),
        .AMP_BITS(AMP_BITS),
        .IMP_BITS(IMP_BITS),
        .ACC_BITS(ACC_BITS),
        .PULSE_BITS(PULSE_BITS),
        .ICDF_ADDR_BITS(ICDF_ADDR_BITS),
        .K_BITS(K_BITS),
        .MAX_EVENTS_PER_SAMPLE(MAX_EVENTS_PER_SAMPLE),
        .NOISE_BITS(NOISE_BITS),
        .FRAC_BITS(FRAC_BITS),
        .DEFAULT_DECAY_SHIFT(DECAY_SHIFT),
        .DEFAULT_OUTPUT_SHIFT(OUTPUT_SHIFT),
        .DEFAULT_NOISE_SHIFT(NOISE_SHIFT),
        // 静态配置模式：不使用 cfg_regfile，所有参数硬编码
        .ENABLE_STATUS_COUNTERS(0),
        .STATIC_CONFIG(1),
        .STATIC_RUN_ENABLE(1),
        .STATIC_AMP_LUT_EN(AMP_LUT_EN),
        .STATIC_FIXED_AMP(FIXED_AMP),
        .STATIC_DECAY_SHIFT(DECAY_SHIFT),
        .STATIC_OUTPUT_SHIFT(OUTPUT_SHIFT),
        .STATIC_BASELINE_OFFSET(BASELINE_OFFSET),
        .STATIC_NOISE_ENABLE(NOISE_ENABLE),
        .STATIC_NOISE_SHIFT(NOISE_SHIFT),
        .DECAY_MODE(DECAY_MODE),
        .STATIC_RISE_SHIFT(RISE_SHIFT),
        .STATIC_FALL_SHIFT(FALL_SHIFT),
        .RNG_SEED_SALT(RNG_SEED_SALT)
    ) u_core (
        .clk(clk_125m),
        .rst_n(rst_n),
        // 总线接口全部接地（静态配置模式不使用）
        .cfg_valid(1'b0),
        .cfg_write(1'b0),
        .cfg_addr(8'd0),
        .cfg_wdata(32'd0),
        .cfg_rdata(cfg_rdata_unused),
        .cfg_ready(cfg_ready_unused),
        .amp_lut_we(1'b0),
        .amp_lut_addr({ICDF_ADDR_BITS{1'b0}}),
        .amp_lut_wdata({AMP_BITS{1'b0}}),
        .dac_sample_vec(sample_pair),
        .dac_sample_valid(sample_valid),
        .event_valid_vec(event_valid_unused),
        .impulse_valid_vec(impulse_valid_unused),
        .saturation_vec(saturation_unused),
        .status_word(status_unused)
    );

endmodule
