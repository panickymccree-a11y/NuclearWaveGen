`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 双读端口 ICDF 幅度查找表
//
// 利用 Block RAM 的双端口特性（Port A + Port B），实现一个写端口 +
// 两个独立读端口。在对波形生成时序要求高的场景下，一个 BRAM 即可
// 同时为两个不同的采样通道提供幅度数据。
//
// 端口分配：
//   Port A：写端口 + 读端口A 分时复用
//           wr_en=1 → 执行写入 wr_addr
//           wr_en=0 → 执行读取 rd_addr_a，数据在 rd_data_a 上输出
//   Port B：纯读端口，始终读取 rd_addr_b，数据在 rd_data_b 上输出
//
// 时序：
//   - 写操作和 Port A 读取不能同时进行（共享地址/数据线）
//   - Port B 读取始终独立，不受写操作影响
//   - 读取延迟：1个时钟周期（BRAM输出寄存器）
//
// 初始化行为与 amp_lut_single_port 完全一致。
// ═══════════════════════════════════════════════════════════════════════════
module amp_lut_dual_read_port #(
    parameter integer ADDR_BITS = 14,                    // 地址位宽
    parameter integer DATA_BITS = 16,                    // 数据位宽
    parameter integer INIT_RAMP = 1,                     // 是否初始化为斜坡
    parameter         INIT_FILE = "NONE"                 // 自定义初始化hex文件
) (
    input  wire                      clk,
    input  wire                      wr_en,             // 写使能
    input  wire [ADDR_BITS-1:0]      wr_addr,           // 写地址
    input  wire [DATA_BITS-1:0]      wr_data,           // 写数据
    input  wire [ADDR_BITS-1:0]      rd_addr_a,         // Port A 读地址
    output reg  [DATA_BITS-1:0]      rd_data_a,         // Port A 读数据
    input  wire [ADDR_BITS-1:0]      rd_addr_b,         // Port B 读地址
    output reg  [DATA_BITS-1:0]      rd_data_b          // Port B 读数据
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
            mem[wr_addr] <= wr_data;                     // Port A 写模式
        end else begin
            rd_data_a <= mem[rd_addr_a];                 // Port A 读模式
        end

        rd_data_b <= mem[rd_addr_b];                     // Port B 始终读取
    end

endmodule
