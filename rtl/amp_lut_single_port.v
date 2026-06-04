`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 单端口同步读 ICDF 幅度查找表
//
// 一片 Block RAM（BRAM），提供一个写端口和一个读端口。
// 写操作优先于读操作：wr_en=1 时写入数据，否则读出 rd_addr 处的数据。
//
// ICDF（Inverse Cumulative Distribution Function，逆累积分布函数）：
//   通过查表法将均匀分布的随机数映射为目标幅度分布。
//   查找表的第k个条目存储的是目标分布的第(k/2^ADDR_BITS)分位数。
//   用均匀随机数作为地址查表，即可得到服从目标分布的随机幅度值。
//
// 存储格式：
//   - 深度 2^ADDR_BITS（默认16K）
//   - 宽度 DATA_BITS（默认16位）
//   - 使用 ram_style = "block" 约束综合器强制映射到 BRAM
//
// 初始化：
//   - INIT_RAMP=1：填充线性斜坡 mem[k] = k << (DATA_BITS-ADDR_BITS)
//     （斜坡表将均匀随机数线性映射为幅度，适用于调试/默认场景）
//   - INIT_FILE!="NONE"：从 hex 文件加载自定义分布数据，覆盖斜坡
// ═══════════════════════════════════════════════════════════════════════════
module amp_lut_single_port #(
    parameter integer ADDR_BITS = 14,                    // 地址位宽（深度=2^ADDR_BITS=16K）
    parameter integer DATA_BITS = 16,                    // 数据位宽
    parameter integer INIT_RAMP = 1,                     // 是否初始化为斜坡
    parameter         INIT_FILE = "NONE"                 // 自定义初始化 hex 文件路径
) (
    input  wire                      clk,
    input  wire                      wr_en,             // 写使能（高有效）
    input  wire [ADDR_BITS-1:0]      wr_addr,           // 写地址
    input  wire [DATA_BITS-1:0]      wr_data,           // 写数据
    input  wire [ADDR_BITS-1:0]      rd_addr,           // 读地址
    output reg  [DATA_BITS-1:0]      rd_data            // 读数据（同步读出，延迟1个时钟周期）
);

    localparam integer DEPTH = (1 << ADDR_BITS);         // 表深度

    (* ram_style = "block" *) reg [DATA_BITS-1:0] mem [0:DEPTH-1];
    integer k;

    // ── 初始化：先填充斜坡（可选），再覆盖自定义文件数据 ──
    initial begin
        for (k = 0; k < DEPTH; k = k + 1) begin
            if (INIT_RAMP != 0)
                mem[k] = (k << (DATA_BITS - ADDR_BITS)); // 将地址k线性映射为数据
            else
                mem[k] = {DATA_BITS{1'b0}};
        end

        if (INIT_FILE != "NONE") begin
            $readmemh(INIT_FILE, mem);                   // 覆盖加载自定义分布
        end
    end

    // ── BRAM 同步读写 ──
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;                     // 写优先
        end
        rd_data <= mem[rd_addr];                         // 同步读（BRAM输出寄存器）
    end

endmodule
