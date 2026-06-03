`timescale 1ns/1ps

module clk_wiz_0 (
    output reg clk_125M,
    output reg clk_250M,
    input  wire reset,
    output reg locked,
    input  wire clk_in1
);

    initial begin
        clk_125M = 1'b0;
        forever #4 clk_125M = ~clk_125M;
    end

    initial begin
        clk_250M = 1'b0;
        forever #2 clk_250M = ~clk_250M;
    end

    initial begin
        locked = 1'b0;
        forever begin
            @(negedge reset);
            #100 locked = 1'b1;
            @(posedge reset);
            locked = 1'b0;
        end
    end

endmodule
