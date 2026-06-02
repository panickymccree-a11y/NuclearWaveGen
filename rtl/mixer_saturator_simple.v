`timescale 1ns/1ps

// Adds a signed baseline and clips the result to unsigned DAC code range.
module mixer_saturator_simple #(
    parameter integer SAMPLES_PER_CLK = 2,
    parameter integer PULSE_BITS      = 32,
    parameter integer NOISE_BITS      = 16,
    parameter integer DAC_BITS        = 16
) (
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  enable,
    input  wire signed [31:0]                    baseline_offset,
    input  wire [SAMPLES_PER_CLK*PULSE_BITS-1:0] pulse_vec,
    input  wire signed [SAMPLES_PER_CLK*NOISE_BITS-1:0] noise_vec,
    output reg  [SAMPLES_PER_CLK*DAC_BITS-1:0]   dac_sample_vec,
    output reg  [SAMPLES_PER_CLK-1:0]            saturation_vec
);

    localparam integer PULSE_MIX_BITS = PULSE_BITS + 3;
    localparam integer MIX_BITS = (PULSE_MIX_BITS > 34) ? PULSE_MIX_BITS : 34;

    reg [PULSE_BITS-1:0]       pulse_i;
    reg signed [NOISE_BITS-1:0] noise_i;
    reg signed [MIX_BITS-1:0]  mix_value;
    reg signed [MIX_BITS-1:0]  baseline_ext;
    reg signed [MIX_BITS-1:0]  noise_ext;
    reg signed [MIX_BITS-1:0]  dac_max_ext;
    reg signed [SAMPLES_PER_CLK*MIX_BITS-1:0] mix_value_d;

    integer i;

    always @(*) begin
        baseline_ext = {{(MIX_BITS-32){baseline_offset[31]}}, baseline_offset};
        dac_max_ext  = {{(MIX_BITS-DAC_BITS){1'b0}}, {DAC_BITS{1'b1}}};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac_sample_vec <= {(SAMPLES_PER_CLK*DAC_BITS){1'b0}};
            saturation_vec <= {SAMPLES_PER_CLK{1'b0}};
            mix_value_d    <= {(SAMPLES_PER_CLK*MIX_BITS){1'b0}};
        end else if (enable) begin
            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                mix_value = mix_value_d[i*MIX_BITS +: MIX_BITS];

                if (mix_value <= 0) begin
                    dac_sample_vec[i*DAC_BITS +: DAC_BITS] <= {DAC_BITS{1'b0}};
                    saturation_vec[i] <= (mix_value < 0);
                end else if (mix_value >= dac_max_ext) begin
                    dac_sample_vec[i*DAC_BITS +: DAC_BITS] <= {DAC_BITS{1'b1}};
                    saturation_vec[i] <= 1'b1;
                end else begin
                    dac_sample_vec[i*DAC_BITS +: DAC_BITS] <= mix_value[DAC_BITS-1:0];
                    saturation_vec[i] <= 1'b0;
                end

                pulse_i = pulse_vec[i*PULSE_BITS +: PULSE_BITS];
                noise_i = noise_vec[i*NOISE_BITS +: NOISE_BITS];
                noise_ext = {{(MIX_BITS-NOISE_BITS){noise_i[NOISE_BITS-1]}}, noise_i};
                mix_value_d[i*MIX_BITS +: MIX_BITS] <=
                    $signed({{(MIX_BITS-PULSE_BITS){1'b0}}, pulse_i}) +
                    baseline_ext + noise_ext;
            end
        end else begin
            dac_sample_vec <= {(SAMPLES_PER_CLK*DAC_BITS){1'b0}};
            saturation_vec <= {SAMPLES_PER_CLK{1'b0}};
            mix_value_d    <= {(SAMPLES_PER_CLK*MIX_BITS){1'b0}};
        end
    end

endmodule
