`timescale 1ns/1ps

// One AD9747 DAC channel generator.
// The channel runs at 125 MHz and produces two consecutive 16-bit samples
// per cycle for a 250 MSPS physical DAC port.
module nuc_event_gen_dac_channel #(
    parameter integer CORE_CLK_HZ           = 125000000,
    parameter integer MAX_RATE_CPS          = 10000000,
    parameter integer RNG_BITS              = 64,
    parameter integer DAC_BITS              = 16,
    parameter integer AMP_BITS              = 16,
    parameter integer IMP_BITS              = 24,
    parameter integer ACC_BITS              = 48,
    parameter integer PULSE_BITS            = 32,
    parameter integer ICDF_ADDR_BITS        = 14,
    parameter integer K_BITS                = 3,
    parameter integer MAX_EVENTS_PER_SAMPLE = 3,
    parameter integer NOISE_BITS            = 16,
    parameter integer FRAC_BITS             = 12,
    parameter [4:0]  DECAY_SHIFT            = 5'd8,
    parameter [4:0]  OUTPUT_SHIFT           = 5'd16,
    parameter integer AMP_LUT_EN            = 1,
    parameter [15:0] FIXED_AMP              = 16'd8192,
    parameter signed [31:0] BASELINE_OFFSET = 32'sd0,
    parameter integer NOISE_ENABLE          = 0,
    parameter [4:0]  NOISE_SHIFT            = 5'd8,
    parameter [63:0] RNG_SEED_SALT          = 64'd0
) (
    input  wire                      clk_125m,
    input  wire                      rst_n,
    input  wire                      enable,
    output wire [2*DAC_BITS-1:0]     sample_pair,
    output wire                      sample_valid,
    output reg                       sample_toggle
);

    localparam integer SAMPLES_PER_CLK = 2;

    wire [31:0] cfg_rdata_unused;
    wire        cfg_ready_unused;
    wire [SAMPLES_PER_CLK-1:0] event_valid_unused;
    wire [SAMPLES_PER_CLK-1:0] impulse_valid_unused;
    wire [SAMPLES_PER_CLK-1:0] saturation_unused;
    wire [31:0] status_unused;

    always @(posedge clk_125m or negedge rst_n) begin
        if (!rst_n) begin
            sample_toggle <= 1'b0;
        end else if (enable && sample_valid) begin
            sample_toggle <= ~sample_toggle;
        end
    end

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
        .RNG_SEED_SALT(RNG_SEED_SALT)
    ) u_core (
        .clk(clk_125m),
        .rst_n(rst_n),
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
