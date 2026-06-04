`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 物理 IO 顶层 — AD9747 双端口 DAC 输出
//
// 整个 FPGA 设计的顶层模块。提供以下功能：
//   1. 时钟生成：板载 50 MHz → MMCM → 125 MHz（波形生成）+ 250 MHz（DAC输出）
//   2. 双独立 DAC 通道：每个通道有完整的核事件生成引擎
//   3. 并串转换 + 跨时钟域桥接：125 MHz×2样/周期 → 250 MHz×1样/周期
//   4. LVDS 差分时钟输出给 AD9747 DAC
//
// 所有 DAC 通道参数在顶层显式定义，两个通道可以独立配置不同的
// 脉冲形状（单指数/双指数）、衰减时间常数、输出幅度等参数。
//
// 时钟域：
//   - 125 MHz 域：波形生成核心、DAC 通道（120 MHz 是 DAC 的典型数据时钟）
//   - 250 MHz 域：DAC 逐采样输出、LVDS 时钟（DDR 模式下数据率即为时钟率）
//   - CDC 桥接：dac_2x_output_serializer 内部处理，无需额外同步
//
// ═══════════════════════════════════════════════════════════════════════════
module nuc_event_gen_10mcps_io_top (
    input  wire                  clk_50m,                      // 板载 50 MHz 参考时钟
    input  wire                  rst_n,                        // 全局复位（低有效）
    output wire                  dac_clk_p,                    // DAC 差分时钟 P（250 MHz）
    output wire                  dac_clk_n,                    // DAC 差分时钟 N
    output wire [15:0]           dac1_data,                    // DAC 通道1 数据（16位）
    output wire [15:0]           dac2_data                     // DAC 通道2 数据（16位）
);

    localparam integer DAC_BITS = 16;

    // ══════════════════════════════════════════════════════════════════════
    // 共享参数（两通道相同）
    // ══════════════════════════════════════════════════════════════════════
    localparam integer CORE_CLK_HZ           = 125000000;
    localparam integer MAX_RATE_CPS          = 10000000;
    localparam integer RNG_BITS              = 64;
    localparam integer AMP_BITS              = 16;
    localparam integer IMP_BITS              = 24;
    localparam integer ACC_BITS              = 48;
    localparam integer PULSE_BITS            = 32;
    localparam integer ICDF_ADDR_BITS        = 14;
    localparam integer K_BITS                = 3;
    localparam integer MAX_EVENTS_PER_SAMPLE = 3;
    localparam integer NOISE_BITS            = 16;
    localparam integer FRAC_BITS             = 12;
    localparam integer AMP_LUT_EN            = 1;
    localparam [15:0] FIXED_AMP              = 16'd8192;
    localparam signed [31:0] BASELINE_OFFSET = 32'sd0;
    localparam integer NOISE_ENABLE          = 0;
    localparam [4:0]  NOISE_SHIFT            = 5'd8;

    // ══════════════════════════════════════════════════════════════════════
    // 通道1 参数 — 单指数衰减脉冲
    //
    //   decay_shift=4 → τ≈16采样≈64ns（250MSPS下）
    //   产生快速尖脉冲，类似 NaI 闪烁体探测器的快成分
    // ══════════════════════════════════════════════════════════════════════
    localparam integer CH1_DECAY_MODE   = 0;                   // 单指数模式
    localparam [4:0]  CH1_DECAY_SHIFT   = 5'd4;               // 衰减速度
    localparam [4:0]  CH1_OUTPUT_SHIFT  = 5'd14;              // 输出幅度缩放

    // ══════════════════════════════════════════════════════════════════════
    // 通道2 参数 — 双指数衰减脉冲
    //
    //   rise_shift=2 → τ_rise≈4采样≈8ns（快速上升）
    //   fall_shift=4 → τ_fall≈16采样≈32ns（较慢下降）
    //   产生快上升-慢下降的经典核脉冲形状
    // ══════════════════════════════════════════════════════════════════════
    localparam integer CH2_DECAY_MODE   = 1;                   // 双指数模式
    localparam [4:0]  CH2_RISE_SHIFT    = 5'd2;               // 快时间常数（上升）
    localparam [4:0]  CH2_FALL_SHIFT    = 5'd4;               // 慢时间常数（下降）
    localparam [4:0]  CH2_OUTPUT_SHIFT  = 5'd14;              // 输出幅度缩放

    // ══════════════════════════════════════════════════════════════════════
    // 时钟和复位
    // ══════════════════════════════════════════════════════════════════════
    wire clk_125m;
    wire clk_250m;
    wire clk_locked;

    reg [2:0] rst_125_sync;                                    // 125MHz域复位同步链
    reg [2:0] rst_250_sync;                                    // 250MHz域复位同步链

    wire rst_mmcm = ~rst_n;                                    // MMCM 复位（高有效）
    wire rst_125_n = rst_125_sync[2];                          // 125MHz域同步后复位
    wire rst_250_n = rst_250_sync[2];                          // 250MHz域同步后复位

    wire [2*DAC_BITS-1:0] ch1_sample_pair;                    // 通道1采样对
    wire [2*DAC_BITS-1:0] ch2_sample_pair;                    // 通道2采样对
    wire ch1_sample_valid;
    wire ch2_sample_valid;
    wire ch1_sample_toggle;
    wire ch2_sample_toggle;
    wire sample_valid = ch1_sample_valid & ch2_sample_valid;   // 两通道均有效才算数据有效
    wire channels_enabled = rst_125_n;

    // ── MMCM 时钟生成 IP ──
    clk_wiz_0 u_clk_wiz (
        .clk_125M(clk_125m),
        .clk_250M(clk_250m),
        .reset(rst_mmcm),
        .locked(clk_locked),
        .clk_in1(clk_50m)
    );

    // ── 125 MHz 域复位同步（三级寄存器链消除亚稳态） ──
    always @(posedge clk_125m or negedge rst_n) begin
        if (!rst_n) begin
            rst_125_sync <= 3'b000;
        end else if (!clk_locked) begin
            rst_125_sync <= 3'b000;                            // MMCM未锁定时保持复位
        end else begin
            rst_125_sync <= {rst_125_sync[1:0], 1'b1};
        end
    end

    // ── 250 MHz 域复位同步 ──
    always @(posedge clk_250m or negedge rst_n) begin
        if (!rst_n) begin
            rst_250_sync <= 3'b000;
        end else if (!clk_locked) begin
            rst_250_sync <= 3'b000;
        end else begin
            rst_250_sync <= {rst_250_sync[1:0], 1'b1};
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    // DAC 通道1 — 单指数衰减
    //
    // 所有参数显式传递，便于独立配置。
    // 种子盐值 0x0001 与通道2区别，确保两通道随机数独立。
    // ══════════════════════════════════════════════════════════════════════
    nuc_event_gen_dac_channel #(
        .CORE_CLK_HZ(CORE_CLK_HZ),
        .MAX_RATE_CPS(MAX_RATE_CPS),
        .RNG_BITS(RNG_BITS),
        .DAC_BITS(DAC_BITS),
        .AMP_BITS(AMP_BITS),
        .IMP_BITS(IMP_BITS),
        .ACC_BITS(ACC_BITS),
        .PULSE_BITS(PULSE_BITS),
        .ICDF_ADDR_BITS(ICDF_ADDR_BITS),
        .K_BITS(K_BITS),
        .MAX_EVENTS_PER_SAMPLE(MAX_EVENTS_PER_SAMPLE),
        .NOISE_BITS(NOISE_BITS),
        .FRAC_BITS(FRAC_BITS),
        .DECAY_SHIFT(CH1_DECAY_SHIFT),
        .OUTPUT_SHIFT(CH1_OUTPUT_SHIFT),
        .AMP_LUT_EN(AMP_LUT_EN),
        .FIXED_AMP(FIXED_AMP),
        .BASELINE_OFFSET(BASELINE_OFFSET),
        .NOISE_ENABLE(NOISE_ENABLE),
        .NOISE_SHIFT(NOISE_SHIFT),
        .DECAY_MODE(CH1_DECAY_MODE),
        .RISE_SHIFT(5'd0),                                     // 单指数模式不使用
        .FALL_SHIFT(5'd0),
        .RNG_SEED_SALT(64'h0000_0000_0000_0001)
    ) u_dac1_channel (
        .clk_125m(clk_125m),
        .rst_n(rst_125_n),
        .enable(channels_enabled),
        .sample_pair(ch1_sample_pair),
        .sample_valid(ch1_sample_valid),
        .sample_toggle(ch1_sample_toggle)
    );

    // ══════════════════════════════════════════════════════════════════════
    // DAC 通道2 — 双指数衰减
    //
    // 与通道1共享相同的幅度/噪声/基线参数，区别在于：
    //   - DECAY_MODE=1（双指数）
    //   - RISE_SHIFT=2, FALL_SHIFT=4（控制脉冲上升下降速度）
    //   - 种子盐值 0x1001（与通道1不同，保证独立性）
    // ══════════════════════════════════════════════════════════════════════
    nuc_event_gen_dac_channel #(
        .CORE_CLK_HZ(CORE_CLK_HZ),
        .MAX_RATE_CPS(MAX_RATE_CPS),
        .RNG_BITS(RNG_BITS),
        .DAC_BITS(DAC_BITS),
        .AMP_BITS(AMP_BITS),
        .IMP_BITS(IMP_BITS),
        .ACC_BITS(ACC_BITS),
        .PULSE_BITS(PULSE_BITS),
        .ICDF_ADDR_BITS(ICDF_ADDR_BITS),
        .K_BITS(K_BITS),
        .MAX_EVENTS_PER_SAMPLE(MAX_EVENTS_PER_SAMPLE),
        .NOISE_BITS(NOISE_BITS),
        .FRAC_BITS(FRAC_BITS),
        .DECAY_SHIFT(CH2_FALL_SHIFT),                          // 单指数备选 = 慢时间常数
        .OUTPUT_SHIFT(CH2_OUTPUT_SHIFT),
        .AMP_LUT_EN(AMP_LUT_EN),
        .FIXED_AMP(FIXED_AMP),
        .BASELINE_OFFSET(BASELINE_OFFSET),
        .NOISE_ENABLE(NOISE_ENABLE),
        .NOISE_SHIFT(NOISE_SHIFT),
        .DECAY_MODE(CH2_DECAY_MODE),
        .RISE_SHIFT(CH2_RISE_SHIFT),
        .FALL_SHIFT(CH2_FALL_SHIFT),
        .RNG_SEED_SALT(64'h0000_0000_0000_1001)
    ) u_dac2_channel (
        .clk_125m(clk_125m),
        .rst_n(rst_125_n),
        .enable(channels_enabled),
        .sample_pair(ch2_sample_pair),
        .sample_valid(ch2_sample_valid),
        .sample_toggle(ch2_sample_toggle)
    );

    // ══════════════════════════════════════════════════════════════════════
    // 输出串行化器
    //
    // 将两个125MHz通道的并行采样对转为250MHz逐采样流。
    // 每通道内部有两个lane（lane0和lane1），串行化后顺序为：
    //   lane0 → lane1 → 下一pair的lane0 → ...
    // ══════════════════════════════════════════════════════════════════════
    dac_2x_output_serializer #(
        .DAC_BITS(DAC_BITS)
    ) u_output_serializer (
        .clk_125m(clk_125m),
        .rst_125_n(rst_125_n),
        .clk_250m(clk_250m),
        .rst_250_n(rst_250_n),
        .ch1_sample_pair(ch1_sample_pair),
        .ch2_sample_pair(ch2_sample_pair),
        .sample_valid(sample_valid),
        .dac1_data(dac1_data),
        .dac2_data(dac2_data)
    );

    // ══════════════════════════════════════════════════════════════════════
    // LVDS 差分时钟输出
    //
    // 仿真模式：简单互补赋值
    // 实际硬件：用 Xilinx OBUFDS 原语驱动差分对
    // ══════════════════════════════════════════════════════════════════════
`ifdef SIMULATION
    assign dac_clk_p = clk_250m;
    assign dac_clk_n = ~clk_250m;
`else
    OBUFDS #(
        .IOSTANDARD("LVDS_25")
    ) u_dac_clk_obufds (
        .I(clk_250m),
        .O(dac_clk_p),
        .OB(dac_clk_n)
    );
`endif

endmodule
