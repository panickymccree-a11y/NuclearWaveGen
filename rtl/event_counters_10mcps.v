`timescale 1ns/1ps

module event_counters_10mcps #(
    parameter integer SAMPLES_PER_CLK = 2,
    parameter integer K_BITS          = 3
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         enable,
    input  wire                         clear,
    input  wire [SAMPLES_PER_CLK-1:0]   event_valid_vec,
    input  wire [SAMPLES_PER_CLK*K_BITS-1:0] event_count_vec,
    input  wire [SAMPLES_PER_CLK-1:0]   impulse_valid_vec,
    input  wire [SAMPLES_PER_CLK*K_BITS-1:0] impulse_count_vec,
    input  wire [SAMPLES_PER_CLK-1:0]   saturation_vec,
    input  wire                         state_overflow,
    output reg  [63:0]                  sample_count,
    output reg  [63:0]                  candidate_count,
    output reg  [63:0]                  emitted_count,
    output reg  [63:0]                  saturation_count,
    output reg  [31:0]                  status_word
);

    function [7:0] popcount_vec;
        input [SAMPLES_PER_CLK-1:0] v;
        integer j;
        begin
            popcount_vec = 8'd0;
            for (j = 0; j < SAMPLES_PER_CLK; j = j + 1) begin
                popcount_vec = popcount_vec + v[j];
            end
        end
    endfunction

    function [15:0] sum_count_vec;
        input [SAMPLES_PER_CLK*K_BITS-1:0] v;
        integer j;
        begin
            sum_count_vec = 16'd0;
            for (j = 0; j < SAMPLES_PER_CLK; j = j + 1) begin
                sum_count_vec = sum_count_vec + v[j*K_BITS +: K_BITS];
            end
        end
    endfunction

    function has_multi_event;
        input [SAMPLES_PER_CLK*K_BITS-1:0] v;
        integer j;
        begin
            has_multi_event = 1'b0;
            for (j = 0; j < SAMPLES_PER_CLK; j = j + 1) begin
                if (v[j*K_BITS +: K_BITS] > 1)
                    has_multi_event = 1'b1;
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count     <= 64'd0;
            candidate_count  <= 64'd0;
            emitted_count    <= 64'd0;
            saturation_count <= 64'd0;
            status_word      <= 32'd0;
        end else if (clear) begin
            sample_count     <= 64'd0;
            candidate_count  <= 64'd0;
            emitted_count    <= 64'd0;
            saturation_count <= 64'd0;
            status_word      <= 32'd0;
        end else if (enable) begin
            sample_count     <= sample_count + SAMPLES_PER_CLK;
            candidate_count  <= candidate_count + sum_count_vec(event_count_vec);
            emitted_count    <= emitted_count + sum_count_vec(impulse_count_vec);
            saturation_count <= saturation_count + popcount_vec(saturation_vec);
            status_word[0]   <= state_overflow;
            status_word[1]   <= |saturation_vec;
            status_word[2]   <= has_multi_event(event_count_vec);
        end
    end

endmodule
