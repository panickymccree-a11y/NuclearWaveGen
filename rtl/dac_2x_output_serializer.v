`timescale 1ns/1ps

// Bridges two 125 MHz sample pairs into two 250 MHz parallel DAC ports.
// Each channel's lane 0 sample is emitted first, followed by lane 1.
module dac_2x_output_serializer #(
    parameter integer DAC_BITS = 16
) (
    input  wire                  clk_125m,
    input  wire                  rst_125_n,
    input  wire                  clk_250m,
    input  wire                  rst_250_n,
    input  wire [2*DAC_BITS-1:0] ch1_sample_pair,
    input  wire [2*DAC_BITS-1:0] ch2_sample_pair,
    input  wire                  sample_valid,
    output reg  [DAC_BITS-1:0]   dac1_data,
    output reg  [DAC_BITS-1:0]   dac2_data
);

    function [1:0] bin_to_gray;
        input [1:0] bin;
        begin
            bin_to_gray = {bin[1], bin[1] ^ bin[0]};
        end
    endfunction

    reg [2*DAC_BITS-1:0] ch1_fifo [0:3];
    reg [2*DAC_BITS-1:0] ch2_fifo [0:3];

    reg [1:0] wr_ptr_bin;
    reg [1:0] wr_ptr_gray;
    wire [1:0] wr_ptr_bin_next = wr_ptr_bin + 2'd1;

    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_gray_sync_0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_gray_sync_1;
    reg [1:0] rd_ptr_bin;
    reg [1:0] rd_ptr_gray;
    reg emit_second;
    reg [DAC_BITS-1:0] ch1_lane1_hold;
    reg [DAC_BITS-1:0] ch2_lane1_hold;

    wire fifo_has_data = (wr_gray_sync_1 != rd_ptr_gray);
    wire [1:0] rd_ptr_bin_next = rd_ptr_bin + 2'd1;

    integer i;

    always @(posedge clk_125m or negedge rst_125_n) begin
        if (!rst_125_n) begin
            wr_ptr_bin <= 2'd0;
            wr_ptr_gray <= 2'd0;
            for (i = 0; i < 4; i = i + 1) begin
                ch1_fifo[i] <= {(2*DAC_BITS){1'b0}};
                ch2_fifo[i] <= {(2*DAC_BITS){1'b0}};
            end
        end else if (sample_valid) begin
            ch1_fifo[wr_ptr_bin] <= ch1_sample_pair;
            ch2_fifo[wr_ptr_bin] <= ch2_sample_pair;
            wr_ptr_bin <= wr_ptr_bin_next;
            wr_ptr_gray <= bin_to_gray(wr_ptr_bin_next);
        end
    end

    always @(posedge clk_250m or negedge rst_250_n) begin
        if (!rst_250_n) begin
            wr_gray_sync_0 <= 2'd0;
            wr_gray_sync_1 <= 2'd0;
            rd_ptr_bin <= 2'd0;
            rd_ptr_gray <= 2'd0;
            emit_second   <= 1'b0;
            ch1_lane1_hold <= {DAC_BITS{1'b0}};
            ch2_lane1_hold <= {DAC_BITS{1'b0}};
            dac1_data <= {DAC_BITS{1'b0}};
            dac2_data <= {DAC_BITS{1'b0}};
        end else begin
            wr_gray_sync_0 <= wr_ptr_gray;
            wr_gray_sync_1 <= wr_gray_sync_0;

            if (emit_second) begin
                emit_second <= 1'b0;
                dac1_data <= ch1_lane1_hold;
                dac2_data <= ch2_lane1_hold;
                rd_ptr_bin <= rd_ptr_bin_next;
                rd_ptr_gray <= bin_to_gray(rd_ptr_bin_next);
            end else if (fifo_has_data) begin
                emit_second <= 1'b1;
                dac1_data <= ch1_fifo[rd_ptr_bin][0 +: DAC_BITS];
                dac2_data <= ch2_fifo[rd_ptr_bin][0 +: DAC_BITS];
                ch1_lane1_hold <= ch1_fifo[rd_ptr_bin][DAC_BITS +: DAC_BITS];
                ch2_lane1_hold <= ch2_fifo[rd_ptr_bin][DAC_BITS +: DAC_BITS];
            end
        end
    end

endmodule
