`timescale 1ns/1ps

// Top module for a 10 Mcps random nuclear event generator.
// Clock assumption:
//   clk = 250 MHz, SAMPLES_PER_CLK = 2, equivalent sample rate = 500 MS/s.
module nuc_event_gen_10mcps_top #(
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
    parameter integer MAX_EVENTS_PER_SAMPLE = 4,
    parameter integer AMP_READ_PORTS        = SAMPLES_PER_CLK * MAX_EVENTS_PER_SAMPLE,
    parameter integer NOISE_BITS            = 16,   //Ô­Îª16
    parameter integer FRAC_BITS             = 12,
    parameter [4:0]  DEFAULT_DECAY_SHIFT     = 5'd8,
    parameter [4:0]  DEFAULT_OUTPUT_SHIFT    = 5'd12,
    parameter [4:0]  DEFAULT_NOISE_SHIFT     = 5'd8,
    parameter integer DECAY_BEFORE_ACCUMULATE = 0,
    parameter [4:0]  FIXED_DECAY_SHIFT       = 5'd0,
    parameter integer ENABLE_STATE_OVERFLOW  = 1,
    parameter integer ENABLE_STATUS_COUNTERS = 1,
    parameter [31:0] MAX_RATE_THRESHOLD_Q32 =
        ((((64'd1 * MAX_RATE_CPS) << 32) +
          (((64'd1 * CORE_CLK_HZ) * SAMPLES_PER_CLK) / 2)) /
         ((64'd1 * CORE_CLK_HZ) * SAMPLES_PER_CLK))
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
    output wire                                dac_sample_valid,
    output wire [SAMPLES_PER_CLK-1:0]          event_valid_vec,
    output wire [SAMPLES_PER_CLK-1:0]          impulse_valid_vec,
    output wire [SAMPLES_PER_CLK-1:0]          saturation_vec,
    output wire [31:0]                         status_word
);

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
    wire        seed_load;
    wire [7:0]  seed_sel;
    wire        seed_zero;
    wire [63:0] seed_data;

    wire [63:0] sample_count;
    wire [63:0] candidate_count;
    wire [63:0] emitted_count;
    wire [63:0] saturation_count;
    wire [31:0] counter_status_word;

    wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_time_vec;
    wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec;
    wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_noise_vec;
    wire [SAMPLES_PER_CLK*K_BITS-1:0]   event_count_vec;

    // â”?â”? rng_amp pipeline delay to match comparator's 4-stage pipe (was 1, now 4 â†? +3) â”?â”?
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
    wire [AMP_READ_PORTS*ICDF_ADDR_BITS-1:0]  icdf_rd_addr_vec;
    wire [AMP_READ_PORTS*AMP_BITS-1:0]        icdf_rd_data_vec;
    wire [SAMPLES_PER_CLK*IMP_BITS-1:0]       impulse_sum_vec;
    wire [SAMPLES_PER_CLK*K_BITS-1:0]         impulse_count_vec;
    wire [SAMPLES_PER_CLK*PULSE_BITS-1:0]     pulse_vec;
    wire signed [SAMPLES_PER_CLK*NOISE_BITS-1:0] noise_vec;
    wire state_overflow;

    assign dac_sample_valid = run_enable;
    assign status_word      = counter_status_word;

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
        .seed_sel(seed_sel),
        .seed_zero(seed_zero),
        .seed_data(seed_data),
        .sample_count(sample_count),
        .candidate_count(candidate_count),
        .emitted_count(emitted_count),
        .saturation_count(saturation_count),
        .status_word(counter_status_word)
    );

    rng_bank_10mcps #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .RNG_BITS(RNG_BITS)
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
