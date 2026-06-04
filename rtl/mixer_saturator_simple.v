`timescale 1ns/1ps

// ═══════════════════════════════════════════════════════════════════════════
// 信号混合器 + 饱和限幅器
//
// 将三个信号分量相加后钳位到无符号 DAC 输出范围 [0, 2^DAC_BITS-1]：
//
//   mix_value = pulse + baseline_offset + noise
//   dac_sample = clamp(mix_value, 0, 65535)  （16位DAC）
//
// 三个信号分量：
//   1. pulse_vec：  指数衰减核脉冲信号（无符号，来自 exp_decay_core）
//   2. baseline_offset：直流基线偏移（有符号，来自配置寄存器）
//   3. noise_vec：  加性白噪声（有符号，来自 noise_baseline_core）
//
// 饱和处理规则：
//   mix_value ≤ 0         → 输出 0x0000，标记负向饱和
//   mix_value ≥ DAC_MAX   → 输出 0xFFFF，标记正向饱和
//   其他                  → 直接截取低 DAC_BITS 位
//
// 流水线结构：
//   当前周期：计算 mix_value_d（组合逻辑），寄存到 mix_value_d
//   下一周期：用 mix_value_d 做饱和判断并输出 dac_sample_vec
//   这拆分了长的加法-比较路径，利于时序收敛。
// ═══════════════════════════════════════════════════════════════════════════
module mixer_saturator_simple #(
    parameter integer SAMPLES_PER_CLK = 2,               // 每时钟周期并行采样通道数
    parameter integer PULSE_BITS      = 32,              // 脉冲信号位宽
    parameter integer NOISE_BITS      = 16,              // 噪声信号位宽
    parameter integer DAC_BITS        = 16               // DAC 输出位宽
) (
    input  wire                                             clk,
    input  wire                                             rst_n,
    input  wire                                             enable,           // 全局使能
    input  wire signed [31:0]                               baseline_offset,  // 直流基线偏移（有符号32位）
    input  wire [SAMPLES_PER_CLK*PULSE_BITS-1:0]            pulse_vec,        // 脉冲信号向量
    input  wire signed [SAMPLES_PER_CLK*NOISE_BITS-1:0]     noise_vec,        // 噪声信号向量（有符号）
    output reg  [SAMPLES_PER_CLK*DAC_BITS-1:0]              dac_sample_vec,   // DAC 采样输出向量
    output reg  [SAMPLES_PER_CLK-1:0]                       saturation_vec    // 饱和标志：bit[i]=1表示lane i饱和
);

    // 内部混合位宽：取脉冲扩展和34位中的较大者，确保不溢出
    localparam integer PULSE_MIX_BITS = PULSE_BITS + 3;     // 脉冲加3位扩展（防止多通道累加溢出）
    localparam integer MIX_BITS = (PULSE_MIX_BITS > 34) ? PULSE_MIX_BITS : 34;

    reg [PULSE_BITS-1:0]              pulse_i;              // 当前通道脉冲值
    reg signed [NOISE_BITS-1:0]       noise_i;              // 当前通道噪声值
    reg signed [MIX_BITS-1:0]         mix_value;            // 混合值（用于饱和判断）
    reg signed [MIX_BITS-1:0]         baseline_ext;         // 基线偏移符号扩展到MIX_BITS位
    reg signed [MIX_BITS-1:0]         noise_ext;            // 噪声值符号扩展到MIX_BITS位
    reg signed [MIX_BITS-1:0]         dac_max_ext;          // DAC最大值扩展到MIX_BITS位
    reg signed [SAMPLES_PER_CLK*MIX_BITS-1:0] mix_value_d;  // 流水线寄存器：保存上一周期的混合值

    integer i;

    // ── 组合逻辑：预计算扩展后的常数值 ──
    always @(*) begin
        baseline_ext = {{(MIX_BITS-32){baseline_offset[31]}}, baseline_offset};
        dac_max_ext  = {{(MIX_BITS-DAC_BITS){1'b0}}, {DAC_BITS{1'b1}}};  // = 65535
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac_sample_vec <= {(SAMPLES_PER_CLK*DAC_BITS){1'b0}};
            saturation_vec <= {SAMPLES_PER_CLK{1'b0}};
            mix_value_d    <= {(SAMPLES_PER_CLK*MIX_BITS){1'b0}};
        end else if (enable) begin
            // ── 当前周期：用上一周期的 mix_value_d 做饱和判断 ──
            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                mix_value = mix_value_d[i*MIX_BITS +: MIX_BITS];

                if (mix_value <= 0) begin
                    dac_sample_vec[i*DAC_BITS +: DAC_BITS] <= {DAC_BITS{1'b0}};   // 负向饱和 → 输出0
                    saturation_vec[i] <= (mix_value < 0);
                end else if (mix_value >= dac_max_ext) begin
                    dac_sample_vec[i*DAC_BITS +: DAC_BITS] <= {DAC_BITS{1'b1}};   // 正向饱和 → 输出全1
                    saturation_vec[i] <= 1'b1;
                end else begin
                    dac_sample_vec[i*DAC_BITS +: DAC_BITS] <= mix_value[DAC_BITS-1:0]; // 正常范围
                    saturation_vec[i] <= 1'b0;
                end

                // ── 同时计算下一周期的混合值 ──
                pulse_i  = pulse_vec[i*PULSE_BITS +: PULSE_BITS];
                noise_i  = noise_vec[i*NOISE_BITS +: NOISE_BITS];
                noise_ext = {{(MIX_BITS-NOISE_BITS){noise_i[NOISE_BITS-1]}}, noise_i};
                mix_value_d[i*MIX_BITS +: MIX_BITS] <=
                    $signed({{(MIX_BITS-PULSE_BITS){1'b0}}, pulse_i}) +
                    baseline_ext + noise_ext;
            end
        end else begin
            dac_sample_vec <= {(SAMPLES_PER_CLK*DAC_BITS){1'b0}};
            saturation_vec <= {SAMPLES_PER_CLK{1'b0}};
            mix_value_d    <= {(SAMPLES_PER_CLK*MIX_BITS){1'b0}};
        end
    end

endmodule
