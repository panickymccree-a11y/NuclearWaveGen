`timescale 1ns/1ps

// One synchronous-read ICDF amplitude table.
// Vivado 2020.2 infers Block RAM from this module.
module amp_lut_single_port #(
    parameter integer ADDR_BITS = 14,
    parameter integer DATA_BITS = 16,
    parameter integer INIT_RAMP = 1,
    parameter         INIT_FILE = "NONE"
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire [ADDR_BITS-1:0]  wr_addr,
    input  wire [DATA_BITS-1:0]  wr_data,
    input  wire [ADDR_BITS-1:0]  rd_addr,
    output reg  [DATA_BITS-1:0]  rd_data
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
        end
        rd_data <= mem[rd_addr];
    end

endmodule
