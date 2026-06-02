`timescale 1ns/1ps

// Replicated ICDF LUT with one read port per sample lane.
// All replicas share the same write port.
module amp_lut_multiport #(
    parameter integer PORTS     = 2,
    parameter integer ADDR_BITS = 14,
    parameter integer DATA_BITS = 16,
    parameter integer INIT_RAMP = 1,
    parameter         INIT_FILE = "NONE"
) (
    input  wire                         clk,
    input  wire                         wr_en,
    input  wire [ADDR_BITS-1:0]         wr_addr,
    input  wire [DATA_BITS-1:0]         wr_data,
    input  wire [PORTS*ADDR_BITS-1:0]   rd_addr_vec,
    output wire [PORTS*DATA_BITS-1:0]   rd_data_vec
);

    genvar i;

    generate
        for (i = 0; i < PORTS; i = i + 1) begin : g_amp_lut
            amp_lut_single_port #(
                .ADDR_BITS(ADDR_BITS),
                .DATA_BITS(DATA_BITS),
                .INIT_RAMP(INIT_RAMP),
                .INIT_FILE(INIT_FILE)
            ) u_lut (
                .clk(clk),
                .wr_en(wr_en),
                .wr_addr(wr_addr),
                .wr_data(wr_data),
                .rd_addr(rd_addr_vec[(i+1)*ADDR_BITS-1:i*ADDR_BITS]),
                .rd_data(rd_data_vec[(i+1)*DATA_BITS-1:i*DATA_BITS])
            );
        end
    endgenerate

endmodule
