`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 随机数发生器阵列（RNG Bank）
//
// 将多个 rng_xorshift64 实例组织成三组独立的随机数发生器：
//
//   seed_sel[7:0] 与 RNG 实例的映射关系：
//   ┌──────────────┬─────────────────────────────────┐
//   │ seed_sel 范围 │ 用途                            │
//   ├──────────────┼─────────────────────────────────┤
//   │ 0 ~ SPC-1    │ 时间判定 RNG（决定事件是否发生）  │
//   │ 16 ~ 16+SPC-1│ 幅度采样 RNG（查ICDF表用）       │
//   │ 32 ~ 32+SPC-1│ 噪声生成 RNG（产生白噪声）       │
//   └──────────────┴─────────────────────────────────┘
//
// 共实例化 3 × SAMPLES_PER_CLK 个独立的 rng_xorshift64。
// 每个实例用不同的 SEED 初值（通过 SEED_SALT 和索引偏移区分），
// 确保三组随机数流在统计上完全独立、互不相关。
//
// seed_load/seed_sel/seed_zero/seed_data 信号被寄存一拍后分发，
// 不同组的 RNG 通过 seed_sel 区分，只响应对应范围的加载请求。
// ═══════════════════════════════════════════════════════════════════════════
module rng_bank_10mcps #(
    parameter integer SAMPLES_PER_CLK = 2,               // 每时钟周期并行采样通道数
    parameter integer RNG_BITS        = 64,              // 随机数位宽
    parameter [63:0]  SEED_SALT       = 64'd0            // 种子盐值：不同通道级实例用不同盐值确保独立性
) (
    input  wire                                        clk,
    input  wire                                        rst_n,
    input  wire                                        enable,        // 全局使能
    input  wire                                        seed_load,     // 种子加载脉冲
    input  wire [7:0]                                  seed_sel,      // 种子选择：指定要加载哪个RNG的种子
    input  wire                                        seed_zero,     // 是否恢复默认种子
    input  wire [63:0]                                 seed_data,     // 外部种子数据
    output wire [SAMPLES_PER_CLK*RNG_BITS-1:0]          rng_time_vec,  // 时间判定随机数向量（每lane一个64bit字）
    output wire [SAMPLES_PER_CLK*RNG_BITS-1:0]          rng_amp_vec,   // 幅度采样随机数向量
    output wire [SAMPLES_PER_CLK*RNG_BITS-1:0]          rng_noise_vec  // 噪声生成随机数向量
);

    genvar i;

    // ── 种子控制信号寄存器：对齐时序并维持加载脉冲 ──
    reg        seed_load_r;
    reg [7:0]  seed_sel_r;
    reg        seed_zero_r;
    reg [63:0] seed_data_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_load_r <= 1'b0;
            seed_sel_r  <= 8'd0;
            seed_zero_r <= 1'b1;
            seed_data_r <= 64'd0;
        end else begin
            seed_load_r <= seed_load;
            if (seed_load) begin                          // 只在加载脉冲有效时更新选择信号
                seed_sel_r  <= seed_sel;
                seed_zero_r <= seed_zero;
                seed_data_r <= seed_data;
            end
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    // 第1组：时间判定 RNG（seed_sel = 0 ~ SAMPLES_PER_CLK-1）
    //
    // 每个采样通道一个独立的 RNG。seed_sel == i 时，该通道的 RNG
    // 响应种子加载请求。不同通道用不同的 SEED 基值区分。
    // ══════════════════════════════════════════════════════════════════════
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_time_rng
            wire [63:0] rnd_time;

            rng_xorshift64 #(
                .SEED(64'h9E37_79B9_7F4A_7C15 ^ SEED_SALT ^
                      (64'hBF58_476D_1CE4_E5B9 * (i + 1)))
            ) u_rng_time (
                .clk(clk),
                .rst_n(rst_n),
                .enable(enable),
                .seed_load(seed_load_r && (seed_sel_r == i)),
                .seed_zero(seed_zero_r),
                .seed_data(seed_data_r),
                .random_out(rnd_time)
            );

            assign rng_time_vec[(i+1)*RNG_BITS-1:i*RNG_BITS] = rnd_time[RNG_BITS-1:0];
        end
    endgenerate

    // ══════════════════════════════════════════════════════════════════════
    // 第2组：幅度采样 RNG（seed_sel = 16 ~ 16+SAMPLES_PER_CLK-1）
    //
    // 用于查 ICDF LUT 表时的地址生成。使用不同于 time RNG 的 SEED 基值。
    // seed_sel 偏移 16 是为了与 time RNG 的选择范围区分开。
    // ══════════════════════════════════════════════════════════════════════
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_amp_rng
            wire [63:0] rnd_amp;

            rng_xorshift64 #(
                .SEED(64'hD1B5_4A32_D192_ED03 ^ SEED_SALT ^
                      (64'h94D0_49BB_1331_11EB * (i + 1)))
            ) u_rng_amp (
                .clk(clk),
                .rst_n(rst_n),
                .enable(enable),
                .seed_load(seed_load_r && (seed_sel_r == (8'd16 + i))),
                .seed_zero(seed_zero_r),
                .seed_data(seed_data_r),
                .random_out(rnd_amp)
            );

            assign rng_amp_vec[(i+1)*RNG_BITS-1:i*RNG_BITS] = rnd_amp[RNG_BITS-1:0];
        end
    endgenerate

    // ══════════════════════════════════════════════════════════════════════
    // 第3组：噪声生成 RNG（seed_sel = 32 ~ 32+SAMPLES_PER_CLK-1）
    //
    // 用于产生加性白噪声。再次使用不同的 SEED 基值，确保与前两组
    // 随机数完全独立。
    // ══════════════════════════════════════════════════════════════════════
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_noise_rng
            wire [63:0] rnd_noise;

            rng_xorshift64 #(
                .SEED(64'hA076_1D64_78BD_642F ^ SEED_SALT ^
                      (64'hE703_7ED1_A0B4_28DB * (i + 1)))
            ) u_rng_noise (
                .clk(clk),
                .rst_n(rst_n),
                .enable(enable),
                .seed_load(seed_load_r && (seed_sel_r == (8'd32 + i))),
                .seed_zero(seed_zero_r),
                .seed_data(seed_data_r),
                .random_out(rnd_noise)
            );

            assign rng_noise_vec[(i+1)*RNG_BITS-1:i*RNG_BITS] = rnd_noise[RNG_BITS-1:0];
        end
    endgenerate

endmodule
