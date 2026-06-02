`timescale 1ns/1ps

// Discrete-time Poisson process generator.
// At 250 MHz with SAMPLES_PER_CLK=2, the equivalent sample rate is 500 MS/s.
// For each 1 ns sample lane:
//   event = (uniform_random_32 < rate_threshold_q32)
// where rate_threshold_q32 = round(rate_cps / sample_rate * 2^32).
module poisson_time_bernoulli #(
    parameter integer SAMPLES_PER_CLK = 2,
    parameter integer RNG_BITS        = 64
) (
    input  wire                                enable,
    input  wire [31:0]                         rate_threshold_q32,
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_time_vec,
    output wire [SAMPLES_PER_CLK-1:0]          event_valid_vec
);

    genvar i;

    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_lane
            wire [RNG_BITS-1:0] rng_i;
            assign rng_i = rng_time_vec[(i+1)*RNG_BITS-1:i*RNG_BITS];
            assign event_valid_vec[i] = enable && (rng_i[31:0] < rate_threshold_q32);
        end
    endgenerate

endmodule
