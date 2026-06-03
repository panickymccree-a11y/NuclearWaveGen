`timescale 1ns/1ps

// One ICDF amplitude table with two BRAM ports.
// Runtime: port A reads rd_addr_a and port B reads rd_addr_b.
// Configuration: port A writes wr_addr/wr_data while waveform generation is
// stopped; port A read data is held during write cycles.
module amp_lut_dual_read_port #(
    parameter integer ADDR_BITS = 14,
    parameter integer DATA_BITS = 16,
    parameter integer INIT_RAMP = 1,
    parameter         INIT_FILE = "NONE"
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire [ADDR_BITS-1:0]  wr_addr,
    input  wire [DATA_BITS-1:0]  wr_data,
    input  wire [ADDR_BITS-1:0]  rd_addr_a,
    output reg  [DATA_BITS-1:0]  rd_data_a,
    input  wire [ADDR_BITS-1:0]  rd_addr_b,
    output reg  [DATA_BITS-1:0]  rd_data_b
);

    localparam integer DEPTH = (1 << ADDR_BITS);

    (* ram_style = "block" *) reg [DATA_BITS-1:0] mem [0:DEPTH-1];

    integer k;

    initial begin
        for (k = 0; k < DEPTH; k = k + 1) begin
            if (INIT_RAMP != 0)
                mem[k] = (k << (DATA_BITS - ADDR_BITS));
            else
                mem[k] = {DATA_BITS{1'b0}};
        end

        if (INIT_FILE != "NONE") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end else begin
            rd_data_a <= mem[rd_addr_a];
        end

        rd_data_b <= mem[rd_addr_b];
    end

endmodule
