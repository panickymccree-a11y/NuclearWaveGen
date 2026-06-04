`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 配置寄存器文件（单时钟周期访问）
//
// 通过字节地址的32位总线接口管理所有运行参数和状态计数器。
// 所有寄存器为32位宽，地址按4字节对齐。
//
// 寄存器地址映射：
//   ┌────────┬──────────────┬──────────────────────────────────┐
//   │ 地址    │ 名称          │ 说明                              │
//   ├────────┼──────────────┼──────────────────────────────────┤
//   │ 0x00   │ CTRL          │ bit[0]=运行使能, bit[1]=软件复位   │
//   │ 0x04   │ RATE_Q32      │ 事件速率阈值（Q0.32格式）          │
//   │ 0x08   │ AMP_CTRL      │ bit[15:0]=固定幅度, bit[16]=LUT使能│
//   │ 0x0C   │ DECAY_SHIFT   │ 衰减速度控制（右移量，最小为1）    │
//   │ 0x10   │ OUTPUT_SHIFT  │ 输出幅度缩放（右移量）             │
//   │ 0x14   │ BASELINE      │ 基线偏移（有符号32位）             │
//   │ 0x18   │ NOISE_CTRL    │ bit[0]=使能, bit[12:8]=噪声幅度   │
//   │ 0x1C   │ RISE_SHIFT    │ 双指数快时间常数（右移量，最小为1）│
//   │ 0x1D   │ FALL_SHIFT    │ 双指数慢时间常数（右移量，最小为1）│
//   │ 0x20   │ SEED_SEL      │ RNG 种子选择索引                 │
//   │ 0x24   │ SEED_LO       │ 种子低32位                        │
//   │ 0x28   │ SEED_HI       │ 种子高32位                        │
//   │ 0x2C   │ SEED_COMMIT   │ 写入此地址触发种子加载             │
//   │ 0x40   │ SAMPLE_LO/HI  │ 累计采样数（只读64位）             │
//   │ 0x48   │ CAND_LO/HI    │ 累计候选事件数（只读64位）         │
//   │ 0x50   │ EMIT_LO/HI    │ 累计实际事件数（只读64位）         │
//   │ 0x58   │ SAT_LO/HI     │ 累计饱和次数（只读64位）           │
//   │ 0x60   │ STATUS        │ 状态字（只读32位）                 │
//   └────────┴──────────────┴──────────────────────────────────┘
//
// 安全机制：
//   - 写入速率阈值时自动钳位到 MAX_RATE_THRESHOLD_Q32
//   - decay_shift / rise_shift / fall_shift 写入0时自动改为1
//     （避免除零/不衰减的异常行为）
//   - 种子加载通过 SEED_COMMIT 地址触发，防止部分更新
//   - 输出增加一级流水线寄存器以断开长多路选择器到引脚的时序路径
// ═══════════════════════════════════════════════════════════════════════════
module cfg_regfile_10mcps #(
    parameter [31:0] MAX_RATE_THRESHOLD_Q32 = 32'd85899346,    // 速率阈值上限
    parameter [4:0]  DEFAULT_DECAY_SHIFT    = 5'd8,            // 默认衰减速度
    parameter [4:0]  DEFAULT_OUTPUT_SHIFT   = 5'd12,           // 默认输出缩放
    parameter [4:0]  DEFAULT_NOISE_SHIFT    = 5'd8,            // 默认噪声缩放
    parameter [4:0]  DEFAULT_RISE_SHIFT     = 5'd5,            // 默认快时间常数
    parameter [4:0]  DEFAULT_FALL_SHIFT     = 5'd9             // 默认慢时间常数
) (
    // ── 总线接口 ──
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cfg_valid,                              // 总线事务有效
    input  wire        cfg_write,                              // 1=写, 0=读
    input  wire [7:0]  cfg_addr,                               // 字节地址
    input  wire [31:0] cfg_wdata,                              // 写数据
    output reg  [31:0] cfg_rdata,                              // 读数据
    output wire        cfg_ready,                              // 始终就绪（单周期响应）

    // ── 控制输出 ──
    output reg         run_enable,                             // 运行使能
    output reg         soft_reset_pulse,                       // 软复位脉冲
    output reg  [31:0] rate_threshold_q32,                     // 速率阈值
    output reg         amp_lut_en,                             // 幅度LUT使能
    output reg  [15:0] fixed_amp,                              // 固定幅度值
    output reg  [4:0]  decay_shift,                            // 单指数衰减速度
    output reg  [4:0]  output_shift,                           // 输出幅度缩放
    output reg  signed [31:0] baseline_offset,                 // 基线偏移
    output reg         noise_enable,                           // 噪声使能
    output reg  [4:0]  noise_shift,                            // 噪声幅度缩放
    output reg  [4:0]  rise_shift,                             // 快时间常数
    output reg  [4:0]  fall_shift,                             // 慢时间常数
    output reg         seed_load,                              // 种子加载脉冲
    output reg  [7:0]  seed_sel,                               // 种子选择
    output reg         seed_zero,                              // 种子归零标志
    output reg  [63:0] seed_data,                              // 种子数据

    // ── 状态计数器输入（只读） ──
    input  wire [63:0] sample_count,
    input  wire [63:0] candidate_count,
    input  wire [63:0] emitted_count,
    input  wire [63:0] saturation_count,
    input  wire [31:0] status_word
);

    // ══════════════════════════════════════════════════════════════════════
    // 寄存器地址定义
    // ══════════════════════════════════════════════════════════════════════
    localparam [7:0] ADDR_CTRL          = 8'h00;
    localparam [7:0] ADDR_RATE_Q32      = 8'h04;
    localparam [7:0] ADDR_AMP_CTRL      = 8'h08;
    localparam [7:0] ADDR_DECAY_SHIFT   = 8'h0C;
    localparam [7:0] ADDR_OUTPUT_SHIFT  = 8'h10;
    localparam [7:0] ADDR_BASELINE      = 8'h14;
    localparam [7:0] ADDR_NOISE_CTRL    = 8'h18;
    localparam [7:0] ADDR_RISE_SHIFT    = 8'h1C;
    localparam [7:0] ADDR_FALL_SHIFT    = 8'h1D;
    localparam [7:0] ADDR_SEED_SEL      = 8'h20;
    localparam [7:0] ADDR_SEED_LO       = 8'h24;
    localparam [7:0] ADDR_SEED_HI       = 8'h28;
    localparam [7:0] ADDR_SEED_COMMIT   = 8'h2C;
    localparam [7:0] ADDR_SAMPLE_LO     = 8'h40;
    localparam [7:0] ADDR_SAMPLE_HI     = 8'h44;
    localparam [7:0] ADDR_CAND_LO       = 8'h48;
    localparam [7:0] ADDR_CAND_HI       = 8'h4C;
    localparam [7:0] ADDR_EMIT_LO       = 8'h50;
    localparam [7:0] ADDR_EMIT_HI       = 8'h54;
    localparam [7:0] ADDR_SAT_LO        = 8'h58;
    localparam [7:0] ADDR_SAT_HI        = 8'h5C;
    localparam [7:0] ADDR_STATUS        = 8'h60;

    // ── 种子加载内部状态 ──
    reg [31:0] seed_lo;
    reg [31:0] seed_hi;
    reg [7:0]  seed_sel_cfg;
    reg        seed_zero_cfg;
    reg        seed_load_pending;

    assign cfg_ready = 1'b1;                                 // 单周期响应，始终就绪

    // ── 读数据流水线寄存器：断开长MUX到输出引脚的时序路径 ──
    reg [31:0] cfg_rdata_pre;

    // ── 读多路选择函数 ──
    function [31:0] read_mux;
        input [7:0] addr;
        begin
            case (addr)
                ADDR_CTRL:         read_mux = {30'd0, 1'b0, run_enable};
                ADDR_RATE_Q32:     read_mux = rate_threshold_q32;
                ADDR_AMP_CTRL:     read_mux = {15'd0, amp_lut_en, fixed_amp};
                ADDR_DECAY_SHIFT:  read_mux = {27'd0, decay_shift};
                ADDR_OUTPUT_SHIFT: read_mux = {27'd0, output_shift};
                ADDR_BASELINE:     read_mux = baseline_offset;
                ADDR_NOISE_CTRL:   read_mux = {19'd0, noise_shift, 7'd0, noise_enable};
                ADDR_RISE_SHIFT:   read_mux = {27'd0, rise_shift};
                ADDR_FALL_SHIFT:   read_mux = {27'd0, fall_shift};
                ADDR_SEED_SEL:     read_mux = {24'd0, seed_sel_cfg};
                ADDR_SEED_LO:      read_mux = seed_lo;
                ADDR_SEED_HI:      read_mux = seed_hi;
                ADDR_SAMPLE_LO:    read_mux = sample_count[31:0];
                ADDR_SAMPLE_HI:    read_mux = sample_count[63:32];
                ADDR_CAND_LO:      read_mux = candidate_count[31:0];
                ADDR_CAND_HI:      read_mux = candidate_count[63:32];
                ADDR_EMIT_LO:      read_mux = emitted_count[31:0];
                ADDR_EMIT_HI:      read_mux = emitted_count[63:32];
                ADDR_SAT_LO:       read_mux = saturation_count[31:0];
                ADDR_SAT_HI:       read_mux = saturation_count[63:32];
                ADDR_STATUS:       read_mux = status_word;
                default:           read_mux = 32'd0;        // 未定义地址返回0
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_enable         <= 1'b0;
            soft_reset_pulse   <= 1'b0;
            rate_threshold_q32 <= MAX_RATE_THRESHOLD_Q32;
            amp_lut_en         <= 1'b1;
            fixed_amp          <= 16'd8192;
            decay_shift        <= DEFAULT_DECAY_SHIFT;
            output_shift       <= DEFAULT_OUTPUT_SHIFT;
            baseline_offset    <= 32'sd0;
            noise_enable       <= 1'b0;
            noise_shift        <= DEFAULT_NOISE_SHIFT;
            rise_shift         <= DEFAULT_RISE_SHIFT;
            fall_shift         <= DEFAULT_FALL_SHIFT;
            seed_load          <= 1'b0;
            seed_sel           <= 8'd0;
            seed_zero          <= 1'b1;
            seed_data          <= 64'd0;
            seed_lo            <= 32'd0;
            seed_hi            <= 32'd0;
            seed_sel_cfg       <= 8'd0;
            seed_zero_cfg      <= 1'b1;
            seed_load_pending  <= 1'b0;
            cfg_rdata_pre      <= 32'd0;
            cfg_rdata          <= 32'd0;
        end else begin
            // ── 单周期脉冲信号清零 ──
            soft_reset_pulse <= 1'b0;
            seed_load        <= seed_load_pending;
            seed_load_pending <= 1'b0;

            // ── 读路径流水线 ──
            cfg_rdata_pre    <= read_mux(cfg_addr);
            cfg_rdata        <= cfg_rdata_pre;

            // ── 写事务处理 ──
            if (cfg_valid && cfg_write) begin
                case (cfg_addr)
                    ADDR_CTRL: begin
                        run_enable <= cfg_wdata[0];
                        if (cfg_wdata[1])
                            soft_reset_pulse <= 1'b1;       // 产生单周期复位脉冲
                    end

                    ADDR_RATE_Q32: begin
                        // 速率阈值钳位：防止超出最大支持速率
                        if (cfg_wdata > MAX_RATE_THRESHOLD_Q32)
                            rate_threshold_q32 <= MAX_RATE_THRESHOLD_Q32;
                        else
                            rate_threshold_q32 <= cfg_wdata;
                    end

                    ADDR_AMP_CTRL: begin
                        fixed_amp  <= cfg_wdata[15:0];
                        amp_lut_en <= cfg_wdata[16];
                    end

                    ADDR_DECAY_SHIFT: begin
                        // 防止衰减量为零（会导致脉冲永不衰减）
                        decay_shift <= (cfg_wdata[4:0] == 5'd0) ? 5'd1 : cfg_wdata[4:0];
                    end

                    ADDR_OUTPUT_SHIFT: begin
                        output_shift <= cfg_wdata[4:0];
                    end

                    ADDR_BASELINE: begin
                        baseline_offset <= cfg_wdata;
                    end

                    ADDR_NOISE_CTRL: begin
                        noise_enable <= cfg_wdata[0];
                        noise_shift  <= cfg_wdata[12:8];
                    end

                    ADDR_RISE_SHIFT: begin
                        // 防止快时间常数为零
                        rise_shift <= (cfg_wdata[4:0] == 5'd0) ? 5'd1 : cfg_wdata[4:0];
                    end

                    ADDR_FALL_SHIFT: begin
                        // 防止慢时间常数为零
                        fall_shift <= (cfg_wdata[4:0] == 5'd0) ? 5'd1 : cfg_wdata[4:0];
                    end

                    ADDR_SEED_SEL: begin
                        seed_sel_cfg <= cfg_wdata[7:0];
                    end

                    ADDR_SEED_LO: begin
                        seed_lo       <= cfg_wdata;
                        // 检测是否为全零种子
                        seed_zero_cfg <= (cfg_wdata == 32'd0) && (seed_hi == 32'd0);
                    end

                    ADDR_SEED_HI: begin
                        seed_hi       <= cfg_wdata;
                        seed_zero_cfg <= (seed_lo == 32'd0) && (cfg_wdata == 32'd0);
                    end

                    ADDR_SEED_COMMIT: begin
                        // 写入此地址触发种子加载：将之前设置的SEED_LO/HI/SEL原子提交
                        seed_sel           <= seed_sel_cfg;
                        seed_data          <= {seed_hi, seed_lo};
                        seed_zero          <= seed_zero_cfg;
                        seed_load_pending  <= 1'b1;          // 下一周期产生加载脉冲
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule
