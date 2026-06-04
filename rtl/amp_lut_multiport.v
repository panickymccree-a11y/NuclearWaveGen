`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 多读端口 ICDF 幅度查找表（BRAM 复制方案）
//
// 当需要超过2个并行读端口时，用多片双端口 BRAM 复制同一份数据。
// 每片 BRAM（amp_lut_dual_read_port）提供2个读口，
// 共需 REPLICAS = ceil(PORTS/2) 片 BRAM 复制。
//
// 所有复制片共享同一个写端口（同时写入相同数据），保证数据一致性。
// 读取时各端口独立访问各自的 BRAM 复制。
//
// 例如：PORTS=8 → REPLICAS=4 片 BRAM，每片2个读口 → 总共8个读口
//
// 资源代价：
//   - 存储：PORTS × 2^(ADDR_BITS-1) × DATA_BITS bits
//     （例如8口×8K×16bit = 1 Mbit = 8 片 RAMB36E1）
//   - 这是用面积换带宽的典型设计取舍
// ═══════════════════════════════════════════════════════════════════════════
module amp_lut_multiport #(
    parameter integer PORTS     = 2,                     // 需要的读端口总数
    parameter integer ADDR_BITS = 14,                    // 地址位宽
    parameter integer DATA_BITS = 16,                    // 数据位宽
    parameter integer INIT_RAMP = 1,                     // 是否初始化为斜坡
    parameter         INIT_FILE = "NONE"                 // 自定义初始化hex文件
) (
    input  wire                                    clk,
    input  wire                                    wr_en,        // 全局写使能（所有复制片同步写入）
    input  wire [ADDR_BITS-1:0]                    wr_addr,      // 全局写地址
    input  wire [DATA_BITS-1:0]                    wr_data,      // 全局写数据
    input  wire [PORTS*ADDR_BITS-1:0]              rd_addr_vec,  // 读地址向量（PORTS个地址拼接）
    output wire [PORTS*DATA_BITS-1:0]              rd_data_vec   // 读数据向量（PORTS个数据拼接）
);

    localparam integer READS_PER_REPLICA = 2;              // 每片BRAM提供2个读口
    localparam integer REPLICAS = (PORTS + READS_PER_REPLICA - 1) / READS_PER_REPLICA;

    genvar i;

    generate
        for (i = 0; i < REPLICAS; i = i + 1) begin : g_amp_lut
            localparam integer PORT_A = i * READS_PER_REPLICA;       // 当前复制片的Port A索引
            localparam integer PORT_B = PORT_A + 1;                  // 当前复制片的Port B索引

            wire [DATA_BITS-1:0] rd_data_a;
            wire [DATA_BITS-1:0] rd_data_b;
            wire [ADDR_BITS-1:0] rd_addr_b;

            // 当 PORT_B 超出总端口数时，给一个无效地址（综合器会优化掉）
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
