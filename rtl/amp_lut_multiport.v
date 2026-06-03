`timescale 1ns/1ps

// Replicated ICDF LUT with two read ports per table replica.
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

    localparam integer READS_PER_REPLICA = 2;
    localparam integer REPLICAS = (PORTS + READS_PER_REPLICA - 1) / READS_PER_REPLICA;

    genvar i;

    generate
        for (i = 0; i < REPLICAS; i = i + 1) begin : g_amp_lut
            localparam integer PORT_A = i * READS_PER_REPLICA;
            localparam integer PORT_B = PORT_A + 1;

            wire [DATA_BITS-1:0] rd_data_a;
            wire [DATA_BITS-1:0] rd_data_b;
            wire [ADDR_BITS-1:0] rd_addr_b;

            assign rd_addr_b = (PORT_B < PORTS) ?
                               rd_addr_vec[(PORT_B+1)*ADDR_BITS-1:PORT_B*ADDR_BITS] :
                               {ADDR_BITS{1'b0}};

            amp_lut_dual_read_port #(
                .ADDR_BITS(ADDR_BITS),
                .DATA_BITS(DATA_BITS),
                .INIT_RAMP(INIT_RAMP),
                .INIT_FILE(INIT_FILE)
            ) u_lut (
                .clk(clk),
                .wr_en(wr_en),
                .wr_addr(wr_addr),
                .wr_data(wr_data),
                .rd_addr_a(rd_addr_vec[(PORT_A+1)*ADDR_BITS-1:PORT_A*ADDR_BITS]),
                .rd_data_a(rd_data_a),
                .rd_addr_b(rd_addr_b),
                .rd_data_b(rd_data_b)
            );

            assign rd_data_vec[(PORT_A+1)*DATA_BITS-1:PORT_A*DATA_BITS] = rd_data_a;

            if (PORT_B < PORTS) begin : g_port_b
                assign rd_data_vec[(PORT_B+1)*DATA_BITS-1:PORT_B*DATA_BITS] = rd_data_b;
            end
        end
    endgenerate

endmodule
