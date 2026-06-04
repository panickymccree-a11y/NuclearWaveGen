`timescale 1ns/1ps

// ===========================================================================
// 小lambda泊松多事件生成器
//
// 在每个采样通道内，用一个均匀随机数映射为 k=0..MAX_EVENTS_PER_SAMPLE
// 个泊松事件，支持每个采样点同时发生多达4个事件。
//
// 泊松分布的小lambda近似：
//   对于 lambda ~ 0.02（10Mcps/500MSa/s），k>=2 的尾部概率虽小但可测量。
//   本模块通过累积概率阈值近似实现多事件判定：
//
//     P(k>=1) ~ lambda          -> threshold_ge1（至少1个事件）
//     P(k>=2) ~ lambda^2 / 2    -> threshold_ge2（至少2个事件）
//     P(k>=3) ~ lambda^3 / 6    -> threshold_ge3（至少3个事件）
//     P(k>=4) ~ lambda^4 / 24   -> threshold_ge4（至少4个事件）
//
//   所有阈值为 Q0.32 格式的32位无符号数。
//   均匀随机数先后与各级阈值比较，确定事件数k。
//
// 阈值计算流水线（仅在 MAX_EVENTS_PER_SAMPLE > 1 时启用）：
//   Stage s1：用 DSP 乘法器计算 lambda^2
//   Stage s2：乘以 lambda -> lambda^3
//   Stage s3：乘以 lambda -> lambda^4，同时启动 lambda^3/6 和 lambda^4/24 除法
//   Stage s4：等待除法完成
//   -> 每当 lambda 变化时重新计算，否则缓存结果
//
// 事件判定流水线（4级，独立于阈值计算）：
//   Stage 1：寄存输入RNG和4个阈值快照
//   Stage 2：4个32位比较器并行独立运行 -> 寄存比较结果
//   Stage 3：优先级编码器（从高位开始判定k值）-> 寄存
//   Stage 4：最终输出寄存器
//
// 为何用4级并行比较而非串行优先级链？
//   传统串行方案需要先判断k>=4 -> 未命中再判k>=3 -> ...，
//   每个32位比较器有~8级CARRY4进位链，4个串行就是32级。
//   并行方案4个比较器同时运行（深度相同），然后用2级LUT
//   做mux选择，时序路径缩短约60%。
//
// 除法器说明：
//   用顺序除法器 const_div_u32_seq（32个周期完成），
//   两个除法并行运行（/6 和 /24 各自用独立除法器实例）。
// ===========================================================================

// ===========================================================================
// 顺序常数除法器（32位 / 小常数）
//
// 用移位-减法的经典除法算法实现32位无符号除以常数。
// 每个时钟周期处理1位，32个周期完成一次除法。
//
// 参数化设计：DIVISOR 是编译期常量，综合器会针对特定除数做优化。
// ===========================================================================
module const_div_u32_seq #(
    parameter integer DIVISOR = 6                            // 常数除数
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,                                // 启动信号（单周期脉冲）
    input  wire [31:0] dividend,                             // 被除数
    output reg         busy,                                 // 忙标志（除法进行中）
    output reg         done,                                 // 完成脉冲
    output reg  [31:0] quotient                              // 商
);

    localparam integer REM_BITS = 6;                         // 余数位宽
    localparam [REM_BITS-1:0] DIVISOR_CONST = DIVISOR[REM_BITS-1:0];

    reg [31:0]           dividend_shift;                     // 移位中的被除数
    reg [31:0]           quotient_work;                      // 构建中的商
    reg [REM_BITS-1:0]   remainder;                          // 当前余数
    reg [5:0]            bit_index;                          // 当前处理的bit位置（31->0）
    reg [REM_BITS-1:0]   remainder_shift;                    // 余数左移一位+新bit
    reg [31:0]           quotient_next;                      // 商的下一值

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            quotient       <= 32'd0;
            dividend_shift <= 32'd0;
            quotient_work  <= 32'd0;
            remainder      <= {REM_BITS{1'b0}};
            bit_index      <= 6'd0;
        end else begin
            done <= 1'b0;                                    // 单周期脉冲

            if (start && !busy) begin
                busy           <= 1'b1;
                dividend_shift <= dividend;
                quotient_work  <= 32'd0;
                remainder      <= {REM_BITS{1'b0}};
                bit_index      <= 6'd31;                     // 从MSB开始
            end else if (busy) begin
                // ---- 标准移位-减法除法迭代 ----
                // 余数左移1位，从被除数移入最高位
                remainder_shift = {remainder[REM_BITS-2:0], dividend_shift[31]};
                quotient_next = quotient_work;

                if (remainder_shift >= DIVISOR_CONST) begin
                    remainder = remainder_shift - DIVISOR_CONST;
                    quotient_next[bit_index] = 1'b1;         // 够减则商位=1
                end else begin
                    remainder = remainder_shift;
                    quotient_next[bit_index] = 1'b0;         // 不够减则商位=0
                end

                quotient_work  <= quotient_next;
                dividend_shift <= {dividend_shift[30:0], 1'b0};

                if (bit_index == 6'd0) begin
                    busy     <= 1'b0;                        // 处理完所有32位
                    done     <= 1'b1;
                    quotient <= quotient_next;
                end else begin
                    bit_index <= bit_index - 6'd1;           // 移向下一位
                end
            end
        end
    end

endmodule


module poisson_time_multievent #(
    parameter integer SAMPLES_PER_CLK       = 2,             // 每时钟周期并行采样通道数
    parameter integer RNG_BITS              = 64,            // 随机数位宽
    parameter integer K_BITS                = 3,             // 事件计数位宽（最大7）
    parameter integer MAX_EVENTS_PER_SAMPLE = 4,             // 每采样点最大事件数
    parameter integer RATE_THRESHOLD_BITS   = 32             // 速率阈值位宽
) (
    input  wire                                                 clk,
    input  wire                                                 rst_n,
    input  wire                                                 enable,             // 全局使能
    input  wire [31:0]                                          rate_threshold_q32, // 速率阈值 lambda（Q0.32）
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0]                  rng_time_vec,       // 时间判定随机数向量
    output wire [SAMPLES_PER_CLK-1:0]                           event_valid_vec,    // 事件有效标志
    output wire [SAMPLES_PER_CLK*K_BITS-1:0]                    event_count_vec     // 事件计数
);

    // ---- 多级阈值信号 ----
    wire [31:0] threshold_ge1_q32;                             // k>=1 阈值
    wire [31:0] threshold_ge2_q32;                             // k>=2 阈值
    wire [31:0] threshold_ge3_q32;                             // k>=3 阈值
    wire [31:0] threshold_ge4_q32;                             // k>=4 阈值

    // ===========================================================================
    // 阈值计算：分为单事件模式和多事件模式
    // ===========================================================================
    generate
        if (MAX_EVENTS_PER_SAMPLE <= 1) begin : g_single_event_thresholds
            // ---- 单事件模式：仅需 lambda 阈值，直接寄存 ----
            reg [31:0] threshold_ge1_q32_r;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    threshold_ge1_q32_r <= 32'd0;
                end else begin
                    threshold_ge1_q32_r <= rate_threshold_q32;
                end
            end

            assign threshold_ge1_q32 = threshold_ge1_q32_r;
            assign threshold_ge2_q32 = 32'd0;
            assign threshold_ge3_q32 = 32'd0;
            assign threshold_ge4_q32 = 32'd0;
        end else begin : g_multi_event_thresholds
            // ===================================================================
            // 多事件模式：用DSP乘法器+顺序除法器计算 lambda^2, lambda^3, lambda^4 阈值
            // ===================================================================

            // ---- DSP乘法器流水线参数 ----
            localparam integer RATE_BITS_CLAMPED = (RATE_THRESHOLD_BITS < 1) ? 1 :
                                                    (RATE_THRESHOLD_BITS > 32) ? 32 :
                                                    RATE_THRESHOLD_BITS;
            localparam integer MULT_LATENCY      = 18;          // 乘法器IP的流水线延迟
            localparam integer MULT_WAIT_CYCLES  = MULT_LATENCY + 1;

            // ---- 状态机状态定义 ----
            localparam [2:0] THRESH_IDLE        = 3'd0;       // 空闲/缓存有效
            localparam [2:0] THRESH_WAIT_SQ     = 3'd1;       // 等待 lambda^2 计算完成
            localparam [2:0] THRESH_WAIT_CUBE   = 3'd2;       // 等待 lambda^3 计算完成
            localparam [2:0] THRESH_WAIT_FOURTH = 3'd3;       // 等待 lambda^4 计算完成
            localparam [2:0] THRESH_DIV         = 3'd4;       // 启动除法
            localparam [2:0] THRESH_WAIT_DIV    = 3'd5;       // 等待除法完成

            reg [2:0] thresh_state;
            reg       threshold_valid;                         // 阈值缓存有效标志

            wire [RATE_BITS_CLAMPED-1:0] rate_threshold_limited;
            wire [31:0] rate_threshold_limited_q32;
            assign rate_threshold_limited = rate_threshold_q32[RATE_BITS_CLAMPED-1:0];
            assign rate_threshold_limited_q32 =
                {{(32-RATE_BITS_CLAMPED){1'b0}}, rate_threshold_limited};

            // ---- 乘法器接口 ----
            reg [5:0]   mult_wait_count;                       // 乘法等待计数器
            reg [63:0]  mult_a;                                // 乘法器输入A
            reg [63:0]  mult_b;                                // 乘法器输入B
            wire [127:0] mult_p;                               // 乘法器输出P
            reg [31:0]  calc_rate_threshold_q32;               // 正在计算中的 lambda 值
            reg [31:0]  active_rate_threshold_q32;             // 当前缓存的 lambda 值

            // ---- DSP乘法器IP实例 ----
            multi_threshold u_threshold_mult (
                .CLK(clk),
                .A(mult_a),
                .B(mult_b),
                .P(mult_p)
            );

            // KEEP约束防止阈值寄存器被合并优化
            (* keep = "true" *) reg [31:0] threshold_ge1_q32_r;
            (* keep = "true" *) reg [31:0] threshold_ge2_q32_r;
            (* keep = "true" *) reg [31:0] threshold_ge3_q32_r;
            (* keep = "true" *) reg [31:0] threshold_ge4_q32_r;

            // ---- 除法器接口 ----
            reg        div_start;
            wire       div6_busy;
            wire       div6_done;
            wire [31:0] div6_quotient;                         // lambda^3 / 6
            wire       div24_busy;
            wire       div24_done;
            wire [31:0] div24_quotient;                        // lambda^4 / 24
            (* keep = "true" *) reg [31:0] pending_threshold_ge1_q32;
            (* keep = "true" *) reg [31:0] pending_threshold_ge2_q32;
            reg [31:0] pending_div6_dividend;
            reg [31:0] pending_div24_dividend;

            // 除法器 /6 实例
            const_div_u32_seq #(
                .DIVISOR(6)
            ) u_div6 (
                .clk(clk),
                .rst_n(rst_n),
                .start(div_start),
                .dividend(pending_div6_dividend),
                .busy(div6_busy),
                .done(div6_done),
                .quotient(div6_quotient)
            );

            // 除法器 /24 实例
            const_div_u32_seq #(
                .DIVISOR(24)
            ) u_div24 (
                .clk(clk),
                .rst_n(rst_n),
                .start(div_start),
                .dividend(pending_div24_dividend),
                .busy(div24_busy),
                .done(div24_done),
                .quotient(div24_quotient)
            );

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    thresh_state <= THRESH_IDLE;
                    threshold_valid <= 1'b0;
                    mult_wait_count <= 6'd0;
                    mult_a <= 64'd0;
                    mult_b <= 64'd0;
                    calc_rate_threshold_q32 <= 32'd0;
                    active_rate_threshold_q32 <= 32'd0;
                    threshold_ge1_q32_r <= 32'd0;
                    threshold_ge2_q32_r <= 32'd0;
                    threshold_ge3_q32_r <= 32'd0;
                    threshold_ge4_q32_r <= 32'd0;
                    pending_threshold_ge1_q32 <= 32'd0;
                    pending_threshold_ge2_q32 <= 32'd0;
                    pending_div6_dividend <= 32'd0;
                    pending_div24_dividend <= 32'd0;
                    div_start <= 1'b0;
                end else begin
                    div_start <= 1'b0;                         // 单周期脉冲

                    // ---- 4级乘法器流水线 ----
                    case (thresh_state)
                        THRESH_IDLE: begin
                            // 当 lambda 变化时触发重新计算，否则保持缓存
                            if (!threshold_valid ||
                                (rate_threshold_limited_q32 != active_rate_threshold_q32)) begin
                                calc_rate_threshold_q32 <= rate_threshold_limited_q32;
                                pending_threshold_ge1_q32 <= rate_threshold_limited_q32; // = lambda
                                mult_a <= {32'd0, rate_threshold_limited_q32};   // A = lambda
                                mult_b <= {32'd0, rate_threshold_limited_q32};   // B = lambda
                                mult_wait_count <= MULT_WAIT_CYCLES[5:0];
                                thresh_state <= THRESH_WAIT_SQ;
                            end
                        end

                        // 等待 lambda^2 = lambda * lambda 计算完成
                        THRESH_WAIT_SQ: begin
                            if (mult_wait_count != 6'd0) begin
                                mult_wait_count <= mult_wait_count - 6'd1;
                            end else begin
                                pending_threshold_ge2_q32 <= mult_p[64:33];     // lambda^2（Q32.64 -> Q0.32）
                                mult_a <= mult_p[63:0];                          // A = lambda^2
                                mult_b <= {32'd0, calc_rate_threshold_q32};      // B = lambda
                                mult_wait_count <= MULT_WAIT_CYCLES[5:0];
                                thresh_state <= THRESH_WAIT_CUBE;
                            end
                        end

                        // 等待 lambda^3 = lambda^2 * lambda 计算完成
                        THRESH_WAIT_CUBE: begin
                            if (mult_wait_count != 6'd0) begin
                                mult_wait_count <= mult_wait_count - 6'd1;
                            end else begin
                                pending_div6_dividend <= mult_p[95:64];          // lambda^3 -> 待除6
                                mult_a <= {32'd0, mult_p[95:64]};                // A = lambda^3
                                mult_b <= {32'd0, calc_rate_threshold_q32};      // B = lambda
                                mult_wait_count <= MULT_WAIT_CYCLES[5:0];
                                thresh_state <= THRESH_WAIT_FOURTH;
                            end
                        end

                        // 等待 lambda^4 = lambda^3 * lambda 计算完成
                        THRESH_WAIT_FOURTH: begin
                            if (mult_wait_count != 6'd0) begin
                                mult_wait_count <= mult_wait_count - 6'd1;
                            end else begin
                                pending_div24_dividend <= mult_p[63:32];         // lambda^4 -> 待除24
                                thresh_state <= THRESH_DIV;
                            end
                        end

                        // 启动两个并行除法器
                        THRESH_DIV: begin
                            if (!div6_busy && !div24_busy) begin
                                div_start                 <= 1'b1;
                                thresh_state              <= THRESH_WAIT_DIV;
                            end
                        end

                        // 等待除法完成 -> 更新所有4个阈值
                        THRESH_WAIT_DIV: begin
                            if (div6_done && div24_done) begin
                                threshold_ge1_q32_r <= pending_threshold_ge1_q32; // = lambda
                                threshold_ge2_q32_r <= pending_threshold_ge2_q32; // = lambda^2
                                threshold_ge3_q32_r <= div6_quotient;             // = lambda^3/6
                                threshold_ge4_q32_r <= div24_quotient;            // = lambda^4/24
                                active_rate_threshold_q32 <= pending_threshold_ge1_q32;
                                threshold_valid <= 1'b1;
                                thresh_state <= THRESH_IDLE;
                            end
                        end

                        default: begin
                            thresh_state <= THRESH_IDLE;
                        end
                    endcase
                end
            end

            assign threshold_ge1_q32 = threshold_ge1_q32_r;
            assign threshold_ge2_q32 = threshold_ge2_q32_r;
            assign threshold_ge3_q32 = threshold_ge3_q32_r;
            assign threshold_ge4_q32 = threshold_ge4_q32_r;
        end
    endgenerate

    // ===========================================================================
    // 事件判定流水线（4级）
    //
    // 将传统的串行优先级比较器链拆分为4个独立并行比较器，
    // 用流水线寄存器断开长进位链。
    // ===========================================================================

    genvar i;

    // ---- Stage 1：输入寄存 + 阈值快照 ----
    (* max_fanout = 50 *) reg [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_time_vec_s1;
    reg [31:0] thresh_ge1_s1;
    reg [31:0] thresh_ge2_s1;
    reg [31:0] thresh_ge3_s1;
    reg [31:0] thresh_ge4_s1;
    reg        enable_s1;

    // ---- Stage 2：并行比较结果寄存器 ----
    reg [SAMPLES_PER_CLK-1:0] cmp_ge1_s2;                    // k>=1 比较结果
    reg [SAMPLES_PER_CLK-1:0] cmp_ge2_s2;                    // k>=2 比较结果
    reg [SAMPLES_PER_CLK-1:0] cmp_ge3_s2;                    // k>=3 比较结果
    reg [SAMPLES_PER_CLK-1:0] cmp_ge4_s2;                    // k>=4 比较结果
    reg                       enable_s2;

    // ---- Stage 3：优先级编码输出寄存器 ----
    reg [SAMPLES_PER_CLK*K_BITS-1:0] event_count_s3;
    reg [SAMPLES_PER_CLK-1:0]        event_valid_s3;

    // ---- Stage 4：最终输出寄存器 ----
    reg [SAMPLES_PER_CLK-1:0]        event_valid_vec_r;
    reg [SAMPLES_PER_CLK*K_BITS-1:0] event_count_vec_r;

    // ---- Stage 1：寄存输入 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rng_time_vec_s1 <= {(SAMPLES_PER_CLK*RNG_BITS){1'b0}};
            thresh_ge1_s1   <= 32'd0;
            thresh_ge2_s1   <= 32'd0;
            thresh_ge3_s1   <= 32'd0;
            thresh_ge4_s1   <= 32'd0;
            enable_s1       <= 1'b0;
        end else begin
            rng_time_vec_s1 <= rng_time_vec;
            thresh_ge1_s1   <= threshold_ge1_q32;
            thresh_ge2_s1   <= threshold_ge2_q32;
            thresh_ge3_s1   <= threshold_ge3_q32;
            thresh_ge4_s1   <= threshold_ge4_q32;
            enable_s1       <= enable;
        end
    end

    // ---- Stage 2：并行独立比较（每个比较器深度最大8级CARRY4） ----
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_lane_s2
            wire [RNG_BITS-1:0] rng_s1_i;
            assign rng_s1_i = rng_time_vec_s1[(i+1)*RNG_BITS-1:i*RNG_BITS];

            // 4个比较器同时运行：每个都是 rng[31:0] < threshold_X
            wire cmp_ge1_w = (rng_s1_i[31:0] < thresh_ge1_s1);
            wire cmp_ge2_w = (rng_s1_i[31:0] < thresh_ge2_s1);
            wire cmp_ge3_w = (rng_s1_i[31:0] < thresh_ge3_s1);
            wire cmp_ge4_w = (rng_s1_i[31:0] < thresh_ge4_s1);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    cmp_ge1_s2[i] <= 1'b0;
                    cmp_ge2_s2[i] <= 1'b0;
                    cmp_ge3_s2[i] <= 1'b0;
                    cmp_ge4_s2[i] <= 1'b0;
                end else begin
                    cmp_ge1_s2[i] <= cmp_ge1_w;
                    cmp_ge2_s2[i] <= cmp_ge2_w;
                    cmp_ge3_s2[i] <= cmp_ge3_w;
                    cmp_ge4_s2[i] <= cmp_ge4_w;
                end
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_s2 <= 1'b0;
        end else begin
            enable_s2 <= enable_s1;
        end
    end

    // ---- Stage 3：优先级编码 ----
    // 从高阈值开始判定：k>=4 -> k=3 -> k=2 -> k=1 -> k=0
    generate
        for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin : g_lane_s3
            reg [K_BITS-1:0] event_count_comb;

            always @(*) begin
                event_count_comb = {K_BITS{1'b0}};
                if (enable_s2) begin
                    // 注：优先级从上到下递减
                    if ((MAX_EVENTS_PER_SAMPLE >= 4) && cmp_ge4_s2[i]) begin
                        event_count_comb = 4;                // k>=4
                    end else if ((MAX_EVENTS_PER_SAMPLE >= 3) && cmp_ge3_s2[i]) begin
                        event_count_comb = 3;                // k=3
                    end else if ((MAX_EVENTS_PER_SAMPLE >= 2) && cmp_ge2_s2[i]) begin
                        event_count_comb = 2;                // k=2
                    end else if (cmp_ge1_s2[i]) begin
                        event_count_comb = 1;                // k=1
                    end
                    // else k=0（默认）
                end
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    event_count_s3[(i+1)*K_BITS-1:i*K_BITS] <= {K_BITS{1'b0}};
                    event_valid_s3[i] <= 1'b0;
                end else begin
                    event_count_s3[(i+1)*K_BITS-1:i*K_BITS] <= event_count_comb;
                    event_valid_s3[i] <= |event_count_comb;  // 任意非零即有效
                end
            end
        end
    endgenerate

    // ---- Stage 4：最终输出寄存器 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_valid_vec_r <= {SAMPLES_PER_CLK{1'b0}};
            event_count_vec_r <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
        end else begin
            event_valid_vec_r <= event_valid_s3;
            event_count_vec_r <= event_count_s3;
        end
    end

    assign event_valid_vec = event_valid_vec_r;
    assign event_count_vec = event_count_vec_r;

endmodule
