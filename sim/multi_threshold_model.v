`timescale 1ns/1ps

module multi_threshold (
    input  wire         CLK,
    input  wire [63:0]  A,
    input  wire [63:0]  B,
    output reg  [127:0] P
);

    integer i;
    reg [127:0] pipe [0:17];

    always @(posedge CLK) begin
        pipe[0] <= A * B;
        for (i = 1; i < 18; i = i + 1) begin
            pipe[i] <= pipe[i-1];
        end
        P <= pipe[17];
    end

endmodule
