// Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
// Date        : Wed Jun  3 10:15:36 2026
// Host        : WIN-WPOUICNVOQZ running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               d:/Project/NuclearWaveGen/prj/NuclearWaveGen.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_stub.v
// Design      : clk_wiz_0
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a100tfgg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module clk_wiz_0(clk_125M, clk_250M, reset, locked, clk_in1)
/* synthesis syn_black_box black_box_pad_pin="clk_125M,clk_250M,reset,locked,clk_in1" */;
  output clk_125M;
  output clk_250M;
  input reset;
  output locked;
  input clk_in1;
endmodule
