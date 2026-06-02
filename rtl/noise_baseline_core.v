`timescale 1ns/1ps

// Per-lane signed white-noise source.
// The raw RNG word is interpreted as signed uniform noise and right-shifted
// by noise_shift before being added in the mixer.
module noise_baseline_core #(
    parameter integer SAMPLES_PER_CLK = 2,
    parameter integer RNG_BITS        = 64,
    parameter integer NOISE_BITS      = 16    //ԭ16bit
) (
    input  wire                                      clk,
    input  wire                                      rst_n,
    input  wire                                      enable,
    input  wire                                      noise_enable,
    input  wire [4:0]                                noise_shift,
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0]       rng_noise_vec,
    output reg  signed [SAMPLES_PER_CLK*NOISE_BITS-1:0] noise_vec
);

    integer i;
    reg signed [NOISE_BITS-1:0] raw_noise;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_vec <= {(SAMPLES_PER_CLK*NOISE_BITS){1'b0}};
        end else if (enable && noise_enable) begin
            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                raw_noise = rng_noise_vec[i*RNG_BITS + RNG_BITS-NOISE_BITS +: NOISE_BITS];
                noise_vec[i*NOISE_BITS +: NOISE_BITS] <= raw_noise >>> noise_shift;
            end
        end else begin
            noise_vec <= {(SAMPLES_PER_CLK*NOISE_BITS){1'b0}};
        end
    end

endmodule
