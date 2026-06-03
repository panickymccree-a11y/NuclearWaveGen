`timescale 1ns/1ps

// Random stream bank.
// seed_sel mapping:
//   0..SAMPLES_PER_CLK-1     : time RNG streams
//   16..16+SAMPLES_PER_CLK-1 : amplitude RNG streams
//   32..32+SAMPLES_PER_CLK-1 : noise RNG streams
module rng_bank_10mcps #(
    parameter integer SAMPLES_PER_CLK = 2,
    parameter integer RNG_BITS        = 64,
    parameter [63:0]  SEED_SALT       = 64'd0
) (
    input  wire                               clk,
    input  wire                               rst_n,
    input  wire                               enable,
    input  wire                               seed_load,
    input  wire [7:0]                         seed_sel,
    input  wire                               seed_zero,
    input  wire [63:0]                        seed_data,
    output wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_time_vec,
    output wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec,
    output wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_noise_vec
);

    genvar i;

    reg        seed_load_r;
    reg [7:0]  seed_sel_r;
    reg        seed_zero_r;
    reg [63:0] seed_data_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_load_r <= 1'b0;
            seed_sel_r  <= 8'd0;
            seed_zero_r <= 1'b1;
            seed_data_r <= 64'd0;
        end else begin
            seed_load_r <= seed_load;
            if (seed_load) begin
                seed_sel_r  <= seed_sel;
                seed_zero_r <= seed_zero;
                seed_data_r <= seed_data;
            end
        end
    end

    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_time_rng
            wire [63:0] rnd_time;

            rng_xorshift64 #(
                .SEED(64'h9E37_79B9_7F4A_7C15 ^ SEED_SALT ^
                      (64'hBF58_476D_1CE4_E5B9 * (i + 1)))
            ) u_rng_time (
                .clk(clk),
                .rst_n(rst_n),
                .enable(enable),
                .seed_load(seed_load_r && (seed_sel_r == i)),
                .seed_zero(seed_zero_r),
                .seed_data(seed_data_r),
                .random_out(rnd_time)
            );

            assign rng_time_vec[(i+1)*RNG_BITS-1:i*RNG_BITS] = rnd_time[RNG_BITS-1:0];
        end
    endgenerate

    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_amp_rng
            wire [63:0] rnd_amp;

            rng_xorshift64 #(
                .SEED(64'hD1B5_4A32_D192_ED03 ^ SEED_SALT ^
                      (64'h94D0_49BB_1331_11EB * (i + 1)))
            ) u_rng_amp (
                .clk(clk),
                .rst_n(rst_n),
                .enable(enable),
                .seed_load(seed_load_r && (seed_sel_r == (8'd16 + i))),
                .seed_zero(seed_zero_r),
                .seed_data(seed_data_r),
                .random_out(rnd_amp)
            );

            assign rng_amp_vec[(i+1)*RNG_BITS-1:i*RNG_BITS] = rnd_amp[RNG_BITS-1:0];
        end
    endgenerate

    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_noise_rng
            wire [63:0] rnd_noise;

            rng_xorshift64 #(
                .SEED(64'hA076_1D64_78BD_642F ^ SEED_SALT ^
                      (64'hE703_7ED1_A0B4_28DB * (i + 1)))
            ) u_rng_noise (
                .clk(clk),
                .rst_n(rst_n),
                .enable(enable),
                .seed_load(seed_load_r && (seed_sel_r == (8'd32 + i))),
                .seed_zero(seed_zero_r),
                .seed_data(seed_data_r),
                .random_out(rnd_noise)
            );

            assign rng_noise_vec[(i+1)*RNG_BITS-1:i*RNG_BITS] = rnd_noise[RNG_BITS-1:0];
        end
    endgenerate

endmodule
