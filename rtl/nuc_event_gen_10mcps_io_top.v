`timescale 1ns/1ps

// Physical IO wrapper for implementation. Debug/status outputs stay inside
// the core and remain readable through cfg_rdata when needed.
module nuc_event_gen_10mcps_io_top #(
    parameter integer SAMPLES_PER_CLK       = 2,
    parameter integer CORE_CLK_HZ           = 250000000,
    parameter integer MAX_RATE_CPS          = 10000000,
    parameter integer RNG_BITS              = 64,
    parameter integer DAC_BITS              = 16,
    parameter integer AMP_BITS              = 16,
    parameter integer IMP_BITS              = 24,
    parameter integer ACC_BITS              = 48,
    parameter integer PULSE_BITS            = 32,
    parameter integer ICDF_ADDR_BITS        = 14,
    parameter integer K_BITS                = 3,
    parameter integer NOISE_BITS            = 16,
    parameter integer FRAC_BITS             = 12,
    parameter [4:0]  DEFAULT_DECAY_SHIFT    = 5'd8,
    parameter [4:0]  DEFAULT_OUTPUT_SHIFT   = 5'd12,
    parameter [4:0]  DEFAULT_NOISE_SHIFT    = 5'd8,
    parameter integer MAX_EVENTS_PER_SAMPLE = 4,
    parameter integer DECAY_BEFORE_ACCUMULATE = 0,
    parameter [4:0]  FIXED_DECAY_SHIFT      = 5'd0,
    parameter integer ENABLE_STATE_OVERFLOW = 1,
    parameter integer ENABLE_STATUS_COUNTERS = 1
) (
    input  wire                                clk,
    input  wire                                rst_n,

    input  wire                                cfg_valid,
    input  wire                                cfg_write,
    input  wire [7:0]                          cfg_addr,
    input  wire [31:0]                         cfg_wdata,
    output wire [31:0]                         cfg_rdata,
    output wire                                cfg_ready,

    input  wire                                amp_lut_we,
    input  wire [ICDF_ADDR_BITS-1:0]           amp_lut_addr,
    input  wire [AMP_BITS-1:0]                 amp_lut_wdata,

    output wire [SAMPLES_PER_CLK*DAC_BITS-1:0] dac_sample_vec,
    output wire                                dac_sample_valid
);

    wire [SAMPLES_PER_CLK-1:0] event_valid_unused;
    wire [SAMPLES_PER_CLK-1:0] impulse_valid_unused;
    wire [SAMPLES_PER_CLK-1:0] saturation_unused;
    wire [31:0]                status_unused;

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
        .NOISE_BITS(NOISE_BITS),
        .FRAC_BITS(FRAC_BITS),
        .DEFAULT_DECAY_SHIFT(DEFAULT_DECAY_SHIFT),
        .DEFAULT_OUTPUT_SHIFT(DEFAULT_OUTPUT_SHIFT),
        .DEFAULT_NOISE_SHIFT(DEFAULT_NOISE_SHIFT),
        .MAX_EVENTS_PER_SAMPLE(MAX_EVENTS_PER_SAMPLE),
        .DECAY_BEFORE_ACCUMULATE(DECAY_BEFORE_ACCUMULATE),
        .FIXED_DECAY_SHIFT(FIXED_DECAY_SHIFT),
        .ENABLE_STATE_OVERFLOW(ENABLE_STATE_OVERFLOW),
        .ENABLE_STATUS_COUNTERS(ENABLE_STATUS_COUNTERS)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(cfg_valid),
        .cfg_write(cfg_write),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata),
        .cfg_ready(cfg_ready),
        .amp_lut_we(amp_lut_we),
        .amp_lut_addr(amp_lut_addr),
        .amp_lut_wdata(amp_lut_wdata),
        .dac_sample_vec(dac_sample_vec),
        .dac_sample_valid(dac_sample_valid),
        .event_valid_vec(event_valid_unused),
        .impulse_valid_vec(impulse_valid_unused),
        .saturation_vec(saturation_unused),
        .status_word(status_unused)
    );

endmodule
