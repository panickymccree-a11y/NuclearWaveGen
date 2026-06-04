`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// DAC 输出串行化器（跨时钟域桥接）
//
// 将两个独立的125 MHz 波形生成通道的并行采样对（每周期2个采样）
// 转换为250 MHz 逐采样串行输出，直接驱动 AD9747 双端口 DAC。
//
// 数据流：
//   125 MHz 域：每个有效周期写入 chX_sample_pair（{lane1, lane0}，共32位）
//             到4深度的写入FIFO
//   250 MHz 域：从FIFO读出，第1拍发lane0，第2拍发lane1
//              → 等效 500 MSa/s 的单采样流
//
// 跨时钟域（CDC）技术：
//   - 写指针用格雷码编码后经两级同步寄存器传递到读时钟域
//   - 格雷码每次只变化1位，避免亚稳态导致的多位采样错误
//   - FIFO深度为4，确保两个时钟域的吞吐量匹配（125M×2 = 250M×1）
//
// FIFO空/满判断：
//   - 有数据：写指针格雷码 ≠ 读指针格雷码
//   - 空：读写指针相等（读端追上写端）
//   - 因吞吐量匹配，正常情况下FIFO不会溢出
//
// 双通道独立处理：
//   ch1_fifo 和 ch2_fifo 独立存储，但共享读写指针和状态机
//   dac1_data 和 dac2_data 同时输出，确保两个DAC端口同步
// ═══════════════════════════════════════════════════════════════════════════
module dac_2x_output_serializer #(
    parameter integer DAC_BITS = 16                        // DAC 数据位宽
) (
    input  wire                      clk_125m,             // 125 MHz 波形生成时钟
    input  wire                      rst_125_n,            // 125 MHz 域复位（低有效）
    input  wire                      clk_250m,             // 250 MHz DAC 输出时钟
    input  wire                      rst_250_n,            // 250 MHz 域复位（低有效）
    input  wire [2*DAC_BITS-1:0]     ch1_sample_pair,      // 通道1采样对 {lane1, lane0}
    input  wire [2*DAC_BITS-1:0]     ch2_sample_pair,      // 通道2采样对 {lane1, lane0}
    input  wire                      sample_valid,         // 采样对有效标志
    output reg  [DAC_BITS-1:0]       dac1_data,            // DAC1 数据输出（250 MHz逐采样）
    output reg  [DAC_BITS-1:0]       dac2_data             // DAC2 数据输出（250 MHz逐采样）
);

    // ── 格雷码转换函数：二进制 → 格雷码 ──
    function [1:0] bin_to_gray;
        input [1:0] bin;
        begin
            bin_to_gray = {bin[1], bin[1] ^ bin[0]};       // Gray[1]=B[1], Gray[0]=B[1]^B[0]
        end
    endfunction

    // ── 双通道 FIFO 存储（深度4，足以处理两个时钟域的吞吐匹配） ──
    reg [2*DAC_BITS-1:0] ch1_fifo [0:3];
    reg [2*DAC_BITS-1:0] ch2_fifo [0:3];

    // ── 125 MHz 写端信号 ──
    reg [1:0] wr_ptr_bin;                                   // 写指针（二进制）
    reg [1:0] wr_ptr_gray;                                  // 写指针（格雷码，用于CDC传递）
    wire [1:0] wr_ptr_bin_next = wr_ptr_bin + 2'd1;

    // ── 250 MHz 读端信号 ──
    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_gray_sync_0;     // CDC同步寄存器第1级
    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_gray_sync_1;     // CDC同步寄存器第2级
    reg [1:0] rd_ptr_bin;                                   // 读指针（二进制）
    reg [1:0] rd_ptr_gray;                                  // 读指针（格雷码）
    reg       emit_second;                                  // 状态机：0=发lane0, 1=发lane1
    reg [DAC_BITS-1:0] ch1_lane1_hold;                     // 暂存通道1的lane1
    reg [DAC_BITS-1:0] ch2_lane1_hold;                     // 暂存通道2的lane1

    wire fifo_has_data = (wr_gray_sync_1 != rd_ptr_gray);   // 格雷码不等 → FIFO非空
    wire [1:0] rd_ptr_bin_next = rd_ptr_bin + 2'd1;

    integer i;

    // ══════════════════════════════════════════════════════════════════════
    // 125 MHz 写时钟域
    //
    // 每个有效周期将 sample_pair 写入当前写指针位置，并更新格雷码写指针。
    // 写指针直接递增，不检查 FIFO 满（因为吞吐量匹配保证不会溢出）。
    // ══════════════════════════════════════════════════════════════════════
    always @(posedge clk_125m or negedge rst_125_n) begin
        if (!rst_125_n) begin
            wr_ptr_bin <= 2'd0;
            wr_ptr_gray <= 2'd0;
            for (i = 0; i < 4; i = i + 1) begin
                ch1_fifo[i] <= {(2*DAC_BITS){1'b0}};
                ch2_fifo[i] <= {(2*DAC_BITS){1'b0}};
            end
        end else if (sample_valid) begin
            ch1_fifo[wr_ptr_bin] <= ch1_sample_pair;        // 写入通道1采样对
            ch2_fifo[wr_ptr_bin] <= ch2_sample_pair;        // 写入通道2采样对
            wr_ptr_bin <= wr_ptr_bin_next;                   // 二进制指针+1
            wr_ptr_gray <= bin_to_gray(wr_ptr_bin_next);     // 转换为格雷码
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    // 250 MHz 读时钟域
    //
    // 状态机两拍循环：
    //   第1拍（emit_second=0）：从FIFO读lane0 → 输出到DAC → 暂存lane1
    //   第2拍（emit_second=1）：输出暂存的lane1 → 读指针推进 → 取下一对
    //
    // 写指针格雷码经两级同步寄存器传递到本时钟域做FIFO非空判断。
    // ══════════════════════════════════════════════════════════════════════
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
            // ── 两级同步：将写指针从125MHz域同步到250MHz域 ──
            wr_gray_sync_0 <= wr_ptr_gray;
            wr_gray_sync_1 <= wr_gray_sync_0;

            if (emit_second) begin
                // 第2拍：发送暂存的lane1
                emit_second <= 1'b0;
                dac1_data <= ch1_lane1_hold;
                dac2_data <= ch2_lane1_hold;
                rd_ptr_bin <= rd_ptr_bin_next;
                rd_ptr_gray <= bin_to_gray(rd_ptr_bin_next);
            end else if (fifo_has_data) begin
                // 第1拍：从FIFO读lane0并暂存lane1
                emit_second <= 1'b1;
                dac1_data <= ch1_fifo[rd_ptr_bin][0 +: DAC_BITS];       // lane0 在低位
                dac2_data <= ch2_fifo[rd_ptr_bin][0 +: DAC_BITS];
                ch1_lane1_hold <= ch1_fifo[rd_ptr_bin][DAC_BITS +: DAC_BITS]; // lane1 在高位
                ch2_lane1_hold <= ch2_fifo[rd_ptr_bin][DAC_BITS +: DAC_BITS];
            end
        end
    end

endmodule
