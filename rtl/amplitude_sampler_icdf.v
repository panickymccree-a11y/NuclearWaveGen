`timescale 1ns/1ps

// Random amplitude sampler.
// amp_lut_en=0: all events use fixed_amp.
// amp_lut_en=1: events use ICDF LUT addressed by independent amplitude RNG.
module amplitude_sampler_icdf #(
    parameter integer SAMPLES_PER_CLK = 2,
    parameter integer RNG_BITS        = 64,
    parameter integer ICDF_ADDR_BITS  = 14,
    parameter integer AMP_BITS        = 16,
    parameter integer IMP_BITS        = 24,
    parameter integer K_BITS          = 3,
    parameter integer MAX_EVENTS_PER_SAMPLE = 4,
    parameter integer AMP_READ_PORTS  = SAMPLES_PER_CLK * MAX_EVENTS_PER_SAMPLE
) (
    input  wire                                clk,
    input  wire                                rst_n,
    input  wire                                enable,
    input  wire                                amp_lut_en,
    input  wire [AMP_BITS-1:0]                 fixed_amp,
    input  wire [SAMPLES_PER_CLK-1:0]          event_valid_vec,
    input  wire [SAMPLES_PER_CLK*K_BITS-1:0]   event_count_vec,
    input  wire [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_vec,
    output wire [AMP_READ_PORTS*ICDF_ADDR_BITS-1:0]  icdf_rd_addr_vec,
    input  wire [AMP_READ_PORTS*AMP_BITS-1:0]        icdf_rd_data_vec,
    output reg  [SAMPLES_PER_CLK-1:0]          impulse_valid_vec,
    output reg  [SAMPLES_PER_CLK*K_BITS-1:0]   impulse_count_vec,
    output reg  [SAMPLES_PER_CLK*IMP_BITS-1:0] impulse_sum_vec
);

    reg [SAMPLES_PER_CLK-1:0] event_valid_d;
    reg [SAMPLES_PER_CLK*K_BITS-1:0] event_count_d;
    reg                       amp_lut_en_d;
    reg [AMP_BITS-1:0]        fixed_amp_d;

    // Pipeline register for rng_amp to align with delayed event signals
    // (event_valid_vec/event_count_vec are now registered in poisson_time_multievent)
    reg [SAMPLES_PER_CLK*RNG_BITS-1:0] rng_amp_d;

    localparam integer ACC_WIDTH  = IMP_BITS + 8;
    localparam integer PAIR_COUNT = (MAX_EVENTS_PER_SAMPLE + 1) / 2;

    reg [SAMPLES_PER_CLK-1:0] impulse_valid_pipe;
    reg [SAMPLES_PER_CLK-1:0] impulse_valid_pipe2;
    reg [SAMPLES_PER_CLK*K_BITS-1:0] impulse_count_pipe;
    reg [SAMPLES_PER_CLK*K_BITS-1:0] impulse_count_pipe2;
    reg [SAMPLES_PER_CLK*PAIR_COUNT*ACC_WIDTH-1:0] amp_pair_sum_d;

    genvar gi;
    genvar gj;

    generate
        for (gi = 0; gi < SAMPLES_PER_CLK; gi = gi + 1) begin : g_addr
            wire [RNG_BITS-1:0] rng_i;
            wire [K_BITS-1:0]   event_count_i;

            assign rng_i = rng_amp_d[(gi+1)*RNG_BITS-1:gi*RNG_BITS];
            assign event_count_i = event_count_vec[(gi+1)*K_BITS-1:gi*K_BITS];

            for (gj = 0; gj < MAX_EVENTS_PER_SAMPLE; gj = gj + 1) begin : g_slot
                localparam integer PORT_INDEX = gi * MAX_EVENTS_PER_SAMPLE + gj;

                assign icdf_rd_addr_vec[(PORT_INDEX+1)*ICDF_ADDR_BITS-1:PORT_INDEX*ICDF_ADDR_BITS] =
                    (amp_lut_en && event_valid_vec[gi] && (event_count_i > gj)) ?
                    rng_i[RNG_BITS-1-(gj*ICDF_ADDR_BITS) -: ICDF_ADDR_BITS] :
                    {ICDF_ADDR_BITS{1'b0}};
            end
        end
    endgenerate

    integer i;
    integer j;
    integer pair_idx;
    integer slot_idx;
    reg [K_BITS-1:0] event_count_i;
    reg [ACC_WIDTH-1:0] amp_pair_acc;
    reg [ACC_WIDTH-1:0] amp_total_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_valid_d     <= {SAMPLES_PER_CLK{1'b0}};
            event_count_d     <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            amp_lut_en_d      <= 1'b0;
            fixed_amp_d       <= {AMP_BITS{1'b0}};
            rng_amp_d         <= {(SAMPLES_PER_CLK*RNG_BITS){1'b0}};
            impulse_valid_pipe <= {SAMPLES_PER_CLK{1'b0}};
            impulse_valid_pipe2 <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_pipe <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_count_pipe2 <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            amp_pair_sum_d     <= {(SAMPLES_PER_CLK*PAIR_COUNT*ACC_WIDTH){1'b0}};
            impulse_valid_vec <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_vec <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_sum_vec   <= {(SAMPLES_PER_CLK*IMP_BITS){1'b0}};
        end else if (enable) begin
            rng_amp_d        <= rng_amp_vec;
            event_valid_d <= event_valid_vec;
            event_count_d <= event_count_vec;
            amp_lut_en_d  <= amp_lut_en;
            fixed_amp_d   <= fixed_amp;

            // ── Stage N: Pair accumulation ──
            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                event_count_i = event_count_d[i*K_BITS +: K_BITS];
                impulse_valid_pipe[i] <= event_valid_d[i];
                impulse_count_pipe[i*K_BITS +: K_BITS] <= event_count_i;

                for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
                    amp_pair_acc = {ACC_WIDTH{1'b0}};

                    for (j = 0; j < 2; j = j + 1) begin
                        slot_idx = pair_idx * 2 + j;
                        if ((slot_idx < MAX_EVENTS_PER_SAMPLE) &&
                            event_valid_d[i] && (slot_idx < event_count_i)) begin
                            if (amp_lut_en_d) begin
                                amp_pair_acc = amp_pair_acc +
                                    {{(ACC_WIDTH-AMP_BITS){1'b0}},
                                     icdf_rd_data_vec[(i*MAX_EVENTS_PER_SAMPLE+slot_idx)*AMP_BITS +: AMP_BITS]};
                            end else begin
                                amp_pair_acc = amp_pair_acc +
                                    {{(ACC_WIDTH-AMP_BITS){1'b0}}, fixed_amp_d};
                            end
                        end
                    end

                    amp_pair_sum_d[(i*PAIR_COUNT+pair_idx)*ACC_WIDTH +: ACC_WIDTH] <= amp_pair_acc;
                end
            end

            // ── Stage N+1: Total accumulation (reads registered pair sums) ──
            impulse_valid_pipe2 <= impulse_valid_pipe;
            impulse_count_pipe2 <= impulse_count_pipe;
            impulse_valid_vec <= impulse_valid_pipe2;
            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                event_count_i = impulse_count_pipe2[i*K_BITS +: K_BITS];
                impulse_count_vec[i*K_BITS +: K_BITS] <= event_count_i;
                amp_total_acc = {ACC_WIDTH{1'b0}};

                for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
                    amp_total_acc = amp_total_acc +
                        amp_pair_sum_d[(i*PAIR_COUNT+pair_idx)*ACC_WIDTH +: ACC_WIDTH];
                end

                if (impulse_valid_pipe2[i] && (event_count_i != {K_BITS{1'b0}})) begin
                    if (|amp_total_acc[ACC_WIDTH-1:IMP_BITS]) begin
                        impulse_sum_vec[i*IMP_BITS +: IMP_BITS] <= {IMP_BITS{1'b1}};
                    end else begin
                        impulse_sum_vec[i*IMP_BITS +: IMP_BITS] <= amp_total_acc[IMP_BITS-1:0];
                    end
                end else begin
                    impulse_sum_vec[i*IMP_BITS +: IMP_BITS] <= {IMP_BITS{1'b0}};
                end
            end
        end else begin
            event_valid_d     <= {SAMPLES_PER_CLK{1'b0}};
            event_count_d     <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_valid_pipe <= {SAMPLES_PER_CLK{1'b0}};
            impulse_valid_pipe2 <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_pipe <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_count_pipe2 <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            amp_pair_sum_d     <= {(SAMPLES_PER_CLK*PAIR_COUNT*ACC_WIDTH){1'b0}};
            impulse_valid_vec <= {SAMPLES_PER_CLK{1'b0}};
            impulse_count_vec <= {(SAMPLES_PER_CLK*K_BITS){1'b0}};
            impulse_sum_vec   <= {(SAMPLES_PER_CLK*IMP_BITS){1'b0}};
        end
    end

endmodule
