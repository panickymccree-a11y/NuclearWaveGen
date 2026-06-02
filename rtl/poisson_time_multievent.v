`timescale 1ns/1ps

module const_div_u32_seq #(
    parameter integer DIVISOR = 6
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] dividend,
    output reg         busy,
    output reg         done,
    output reg  [31:0] quotient
);

    localparam integer REM_BITS = 6;
    localparam [REM_BITS-1:0] DIVISOR_CONST = DIVISOR[REM_BITS-1:0];

    reg [31:0] dividend_shift;
    reg [31:0] quotient_work;
    reg [REM_BITS-1:0] remainder;
    reg [5:0] bit_index;
    reg [REM_BITS-1:0] remainder_shift;
    reg [31:0] quotient_next;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            quotient       <= 32'd0;
            dividend_shift <= 32'd0;
            quotient_work  <= 32'd0;
            remainder      <= {REM_BITS{1'b0}};
            bit_index      <= 6'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy           <= 1'b1;
                dividend_shift <= dividend;
                quotient_work  <= 32'd0;
                remainder      <= {REM_BITS{1'b0}};
                bit_index      <= 6'd31;
            end else if (busy) begin
                remainder_shift = {remainder[REM_BITS-2:0], dividend_shift[31]};
                quotient_next = quotient_work;

                if (remainder_shift >= DIVISOR_CONST) begin
                    remainder = remainder_shift - DIVISOR_CONST;
                    quotient_next[bit_index] = 1'b1;
                end else begin
                    remainder = remainder_shift;
                    quotient_next[bit_index] = 1'b0;
                end

                quotient_work  <= quotient_next;
                dividend_shift <= {dividend_shift[30:0], 1'b0};

                if (bit_index == 6'd0) begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    quotient <= quotient_next;
                end else begin
                    bit_index <= bit_index - 6'd1;
                end
            end
        end
    end

endmodule

// Small-lambda Poisson event counter for each sample lane.
// rate_threshold_q32 represents lambda in Q0.32:
//   lambda = rate_cps / equivalent_sample_rate
//
// For the 10 Mcps / 500 MS/s default, lambda is 0.02. The k>=2 tail is
// small but measurable, so this module maps one uniform RNG word per lane
// into k=0..MAX_EVENTS_PER_SAMPLE using a compact Poisson-tail approximation:
//   P(k>=1) ~= lambda
//   P(k>=2) ~= lambda^2 / 2
//   P(k>=3) ~= lambda^3 / 6
//   P(k>=4) ~= lambda^4 / 24
module poisson_time_multievent #(
    parameter integer SAMPLES_PER_CLK      = 2,
    parameter integer RNG_BITS             = 64,
    parameter integer K_BITS               = 3,
    parameter integer MAX_EVENTS_PER_SAMPLE = 4
) (
    input  wire                                clk,
    input  wire                                rst_n,
    input  wire                                enable,
    input  wire [31:0]                         rate_threshold_q32,
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_time_vec,
    output wire [SAMPLES_PER_CLK-1:0]          event_valid_vec,
    output wire [SAMPLES_PER_CLK*K_BITS-1:0]   event_count_vec
);

    wire [31:0] threshold_ge1_q32;
    wire [31:0] threshold_ge2_q32;
    wire [31:0] threshold_ge3_q32;
    wire [31:0] threshold_ge4_q32;

    generate
        if (MAX_EVENTS_PER_SAMPLE <= 1) begin : g_single_event_thresholds
            reg [31:0] threshold_ge1_q32_r;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    threshold_ge1_q32_r <= 32'd0;
                end else begin
                    threshold_ge1_q32_r <= rate_threshold_q32;
                end
            end

            assign threshold_ge1_q32 = threshold_ge1_q32_r;
            assign threshold_ge2_q32 = 32'd0;
            assign threshold_ge3_q32 = 32'd0;
            assign threshold_ge4_q32 = 32'd0;
        end else begin : g_multi_event_thresholds
            // ── DSP pipeline registers with use_dsp attribute ──
            (* use_dsp = "yes" *) reg [63:0]  lambda_sq_q64_s1;
            (* use_dsp = "yes" *) reg [95:0]  lambda_cube_q96_s2;
            (* use_dsp = "yes" *) reg [127:0] lambda_fourth_q128_s3;

            // Extra pipeline stage (s4) to let DSP cascade settle before fabric reduction
            (* use_dsp = "yes" *) reg [127:0] lambda_fourth_q128_s4;

            reg [31:0] rate_threshold_s1;
            reg [31:0] rate_threshold_s2;
            reg [31:0] rate_threshold_s3;
            reg [31:0] rate_threshold_s4;
            reg [63:0] lambda_sq_q64_s2;
            reg [63:0] lambda_sq_q64_s3;
            reg [63:0] lambda_sq_q64_s4;
            reg [95:0] lambda_cube_q96_s3;
            reg [95:0] lambda_cube_q96_s4;

            // ── KEEP on threshold registers to prevent logic merging ──
            (* keep = "true" *) reg [31:0] threshold_ge1_q32_r;
            (* keep = "true" *) reg [31:0] threshold_ge2_q32_r;
            (* keep = "true" *) reg [31:0] threshold_ge3_q32_r;
            (* keep = "true" *) reg [31:0] threshold_ge4_q32_r;

            reg        div_start;
            wire       div6_busy;
            wire       div6_done;
            wire [31:0] div6_quotient;
            wire       div24_busy;
            wire       div24_done;
            wire [31:0] div24_quotient;
            (* keep = "true" *) reg [31:0] pending_threshold_ge1_q32;
            (* keep = "true" *) reg [31:0] pending_threshold_ge2_q32;
            reg [31:0] pending_div6_dividend;
            reg [31:0] pending_div24_dividend;

            const_div_u32_seq #(
                .DIVISOR(6)
            ) u_div6 (
                .clk(clk),
                .rst_n(rst_n),
                .start(div_start),
                .dividend(pending_div6_dividend),
                .busy(div6_busy),
                .done(div6_done),
                .quotient(div6_quotient)
            );

            const_div_u32_seq #(
                .DIVISOR(24)
            ) u_div24 (
                .clk(clk),
                .rst_n(rst_n),
                .start(div_start),
                .dividend(pending_div24_dividend),
                .busy(div24_busy),
                .done(div24_done),
                .quotient(div24_quotient)
            );

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rate_threshold_s1 <= 32'd0;
                    rate_threshold_s2 <= 32'd0;
                    rate_threshold_s3 <= 32'd0;
                    rate_threshold_s4 <= 32'd0;
                    lambda_sq_q64_s1  <= 64'd0;
                    lambda_sq_q64_s2  <= 64'd0;
                    lambda_sq_q64_s3  <= 64'd0;
                    lambda_sq_q64_s4  <= 64'd0;
                    lambda_cube_q96_s2 <= 96'd0;
                    lambda_cube_q96_s3 <= 96'd0;
                    lambda_cube_q96_s4 <= 96'd0;
                    lambda_fourth_q128_s3 <= 128'd0;
                    lambda_fourth_q128_s4 <= 128'd0;
                    threshold_ge1_q32_r <= 32'd0;
                    threshold_ge2_q32_r <= 32'd0;
                    threshold_ge3_q32_r <= 32'd0;
                    threshold_ge4_q32_r <= 32'd0;
                    pending_threshold_ge1_q32 <= 32'd0;
                    pending_threshold_ge2_q32 <= 32'd0;
                    pending_div6_dividend <= 32'd0;
                    pending_div24_dividend <= 32'd0;
                    div_start <= 1'b0;
                end else begin
                    div_start <= 1'b0;

                    // ── 4-stage multiplier pipeline ──
                    // Stage s1: λ² multiply
                    rate_threshold_s1 <= rate_threshold_q32;
                    lambda_sq_q64_s1 <= {32'd0, rate_threshold_q32} *
                                        {32'd0, rate_threshold_q32};

                    // Stage s2: λ³ multiply
                    rate_threshold_s2 <= rate_threshold_s1;
                    lambda_sq_q64_s2 <= lambda_sq_q64_s1;
                    lambda_cube_q96_s2 <= {32'd0, lambda_sq_q64_s1} *
                                          {64'd0, rate_threshold_s1};

                    // Stage s3: λ⁴ multiply
                    rate_threshold_s3 <= rate_threshold_s2;
                    lambda_sq_q64_s3 <= lambda_sq_q64_s2;
                    lambda_cube_q96_s3 <= lambda_cube_q96_s2;
                    lambda_fourth_q128_s3 <= {32'd0, lambda_cube_q96_s2} *
                                             {96'd0, rate_threshold_s2};

                    // Stage s4: Extra pipeline stage for DSP cascade settling
                    rate_threshold_s4 <= rate_threshold_s3;
                    lambda_sq_q64_s4 <= lambda_sq_q64_s3;
                    lambda_cube_q96_s4 <= lambda_cube_q96_s3;
                    lambda_fourth_q128_s4 <= lambda_fourth_q128_s3;

                    // Divider trigger: use s4 stage values
                    if (!div6_busy && !div24_busy && !div6_done && !div24_done) begin
                        pending_threshold_ge1_q32 <= rate_threshold_s4;
                        pending_threshold_ge2_q32 <= lambda_sq_q64_s4 >> 33;
                        pending_div6_dividend     <= lambda_cube_q96_s4[95:64];
                        pending_div24_dividend    <= lambda_fourth_q128_s4[127:96];
                        div_start                 <= 1'b1;
                    end

                    if (div6_done && div24_done) begin
                        threshold_ge1_q32_r <= pending_threshold_ge1_q32;
                        threshold_ge2_q32_r <= pending_threshold_ge2_q32;
                        threshold_ge3_q32_r <= div6_quotient;
                        threshold_ge4_q32_r <= div24_quotient;
                    end
                end
            end

            assign threshold_ge1_q32 = threshold_ge1_q32_r;
            assign threshold_ge2_q32 = threshold_ge2_q32_r;
            assign threshold_ge3_q32 = threshold_ge3_q32_r;
            assign threshold_ge4_q32 = threshold_ge4_q32_r;
        end
    endgenerate

    // ══════════════════════════════════════════════════════════════════════
    // 4-stage pipeline comparator
    // Stage 1: Register rng_time_vec input and threshold snapshot
    // Stage 2: Parallel 32-bit comparisons (all 4 thresholds INDEPENDENTLY)
    // Stage 3: Register comparison results
    // Stage 4: Priority encoder from registered bits + final register
    //
    // This breaks the 15-CARRY4 priority-comparator chain into:
    //   4 independent 32-bit comparators (max 8 CARRY4 each, ALL PARALLEL)
    //   → registered → simple LUT-based priority mux (1-2 LUT levels)
    // ══════════════════════════════════════════════════════════════════════

    genvar i;

    // ── Stage 1: Input registers ──
    (* max_fanout = 50 *) reg [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_time_vec_s1;
    reg [31:0] thresh_ge1_s1;
    reg [31:0] thresh_ge2_s1;
    reg [31:0] thresh_ge3_s1;
    reg [31:0] thresh_ge4_s1;
    reg        enable_s1;

    // ── Stage 2: Parallel comparison (combinational), then registered ──
    // One bit per lane: the result of rng[31:0] < threshold
    reg [SAMPLES_PER_CLK-1:0] cmp_ge1_s2;
    reg [SAMPLES_PER_CLK-1:0] cmp_ge2_s2;
    reg [SAMPLES_PER_CLK-1:0] cmp_ge3_s2;
    reg [SAMPLES_PER_CLK-1:0] cmp_ge4_s2;
    reg                       enable_s2;

    // ── Stage 3: Priority encoder output (registered) ──
    reg [SAMPLES_PER_CLK*K_BITS-1:0] event_count_s3;
    reg [SAMPLES_PER_CLK-1:0]        event_valid_s3;

    // ── Stage 4: Final output register ──
    reg [SAMPLES_PER_CLK-1:0]          event_valid_vec_r;
    reg [SAMPLES_PER_CLK*K_BITS-1:0]   event_count_vec_r;

    // ── Stage 1: Register rng_time inputs and threshold snapshot ──
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rng_time_vec_s1 <= {(SAMPLES_PER_CLK*RNG_BITS){1'b0}};
            thresh_ge1_s1   <= 32'd0;
            thresh_ge2_s1   <= 32'd0;
            thresh_ge3_s1   <= 32'd0;
            thresh_ge4_s1   <= 32'd0;
            enable_s1       <= 1'b0;
        end else begin
            rng_time_vec_s1 <= rng_time_vec;
            thresh_ge1_s1   <= threshold_ge1_q32;
            thresh_ge2_s1   <= threshold_ge2_q32;
            thresh_ge3_s1   <= threshold_ge3_q32;
            thresh_ge4_s1   <= threshold_ge4_q32;
            enable_s1       <= enable;
        end
    end

    // ── Stage 2: Parallel compare + register ──
    // All 4 comparisons run independently and in parallel — no priority chain
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_lane_s2
            wire [RNG_BITS-1:0] rng_s1_i;
            assign rng_s1_i = rng_time_vec_s1[(i+1)*RNG_BITS-1:i*RNG_BITS];

            // Parallel independent comparisons (each max 8 CARRY4 deep)
            wire cmp_ge1_w = (rng_s1_i[31:0] < thresh_ge1_s1);
            wire cmp_ge2_w = (rng_s1_i[31:0] < thresh_ge2_s1);
            wire cmp_ge3_w = (rng_s1_i[31:0] < thresh_ge3_s1);
            wire cmp_ge4_w = (rng_s1_i[31:0] < thresh_ge4_s1);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    cmp_ge1_s2[i] <= 1'b0;
                    cmp_ge2_s2[i] <= 1'b0;
                    cmp_ge3_s2[i] <= 1'b0;
                    cmp_ge4_s2[i] <= 1'b0;
                end else begin
                    cmp_ge1_s2[i] <= cmp_ge1_w;
                    cmp_ge2_s2[i] <= cmp_ge2_w;
                    cmp_ge3_s2[i] <= cmp_ge3_w;
                    cmp_ge4_s2[i] <= cmp_ge4_w;
                end
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_s2 <= 1'b0;
        end else begin
            enable_s2 <= enable_s1;
        end
    end

    // ── Stage 3: Priority encoder from registered compare bits → register ──
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_lane_s3
            reg [K_BITS-1:0] event_count_comb;

            always @(*) begin
                event_count_comb = {K_BITS{1'b0}};
                if (enable_s2) begin
                    if ((MAX_EVENTS_PER_SAMPLE >= 4) && cmp_ge4_s2[i]) begin
                        event_count_comb = 4;
                    end else if ((MAX_EVENTS_PER_SAMPLE >= 3) && cmp_ge3_s2[i]) begin
                        event_count_comb = 3;
                    end else if ((MAX_EVENTS_PER_SAMPLE >= 2) && cmp_ge2_s2[i]) begin
                        event_count_comb = 2;
                    end else if (cmp_ge1_s2[i]) begin
                        event_count_comb = 1;
                    end
                end
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    event_count_s3[(i+1)*K_BITS-1:i*K_BITS] <= {K_BITS{1'b0}};
                    event_valid_s3[i] <= 1'b0;
                end else begin
                    event_count_s3[(i+1)*K_BITS-1:i*K_BITS] <= event_count_comb;
                    event_valid_s3[i] <= |event_count_comb;
                end
            end
        end
    endgenerate

    // ── Stage 4: Final output register ──
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_valid_vec_r <= {SAMPLES_PER_CLK{1'b0}};
            event_count_vec_r <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
        end else begin
            event_valid_vec_r <= event_valid_s3;
            event_count_vec_r <= event_count_s3;
        end
    end

    assign event_valid_vec = event_valid_vec_r;
    assign event_count_vec = event_count_vec_r;

endmodule
