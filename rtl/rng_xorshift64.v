`timescale 1ns/1ps

// 64-bit xorshift pseudo-random generator.
// One new 64-bit random word is produced whenever enable is high.
module rng_xorshift64 #(
    parameter [63:0] SEED = 64'h9E37_79B9_7F4A_7C15
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        seed_load,
    input  wire        seed_zero,
    input  wire [63:0] seed_data,
    output wire [63:0] random_out
);

    reg [63:0] state;

    assign random_out = state;

    // Xorshift64 next-state logic. A non-zero seed never transitions to zero,
    // so the zero guard is kept only on explicit seed loading.
    wire [63:0] xs_s1 = state ^ (state << 13);
    wire [63:0] xs_s2 = xs_s1 ^ (xs_s1 >> 7);
    wire [63:0] xs_s3 = xs_s2 ^ (xs_s2 << 17);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= SEED;
        end else if (seed_load) begin
            state <= seed_zero ? SEED : seed_data;
        end else if (enable) begin
            state <= xs_s3;
        end
    end

endmodule
