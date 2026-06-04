// Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
// Date        : Wed Jun  3 10:56:20 2026
// Host        : WIN-WPOUICNVOQZ running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               d:/Project/NuclearWaveGen/prj/NuclearWaveGen.gen/sources_1/ip/multi_threshold/multi_threshold_stub.v
// Design      : multi_threshold
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a100tfgg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* x_core_info = "mult_gen_v12_0_16,Vivado 2020.2" *)
module multi_threshold(CLK, A, B, P)
/* synthesis syn_black_box black_box_pad_pin="CLK,A[63:0],B[63:0],P[127:0]" */;
  input CLK;
  input [63:0]A;
  input [63:0]B;
  output [127:0]P;
endmodule
