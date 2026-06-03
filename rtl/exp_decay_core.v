`timescale 1ns/1ps

// One-pole exponential decay shaper.
// Lanes are time-interleaved samples inside one core clock. The state is
// updated lane by lane, so lane0 and lane1 form one continuous exponential
// sample stream when viewed in sequence.
// For every sample lane:
//   state = state + (impulse << FRAC_BITS)
//   pulse = state >> output_shift
//   state = state - (state >> decay_shift)
//
// PIPELINE: 2-stage architecture to meet 250 MHz timing on Artix-7.
//   Stage 1: decay + accumulate per lane → pulse_state_vec_d, decay_state
//   Stage 2: saturation check on registered pulse_state_pipe → pulse_vec
// The extra pipeline register breaks the 48-bit carry chain between
// the accumulate loop and the saturation reduction-OR.
module exp_decay_core #(
    parameter integer SAMPLES_PER_CLK = 2,
    parameter integer IMP_BITS        = 24,
    parameter integer ACC_BITS        = 48,
    parameter integer PULSE_BITS      = 32,
    parameter integer FRAC_BITS       = 12,
    parameter integer DECAY_BEFORE_ACCUMULATE = 0,
    parameter [4:0]  FIXED_DECAY_SHIFT = 5'd0,
    parameter integer ENABLE_STATE_OVERFLOW = 1
) (
    input  wire                                clk,
    input  wire                                rst_n,
    input  wire                                enable,
    input  wire                                clear,
    input  wire [4:0]                          decay_shift,
    input  wire [4:0]                          output_shift,
    input  wire [SAMPLES_PER_CLK-1:0]          impulse_valid_vec,
    input  wire [SAMPLES_PER_CLK*IMP_BITS-1:0] impulse_sum_vec,
    output reg  [SAMPLES_PER_CLK*PULSE_BITS-1:0] pulse_vec,
    output reg                                 state_overflow
);

    reg [ACC_BITS-1:0] decay_state;
    reg [ACC_BITS-1:0] work_state;
    reg [ACC_BITS-1:0] next_state;
    reg [ACC_BITS-1:0] decayed_state;
    reg [ACC_BITS-1:0] impulse_ext;
    reg [ACC_BITS-1:0] scaled_state;
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] impulse_ext_vec_d;
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] pulse_state_vec_d;
    reg [4:0]           output_shift_d;
    reg                 overflow_next;
    reg                 pulse_overflow_next;
    wire [4:0]          decay_shift_eff;

    // Pipeline registers: break carry chain between accumulate and saturation
    reg [SAMPLES_PER_CLK*ACC_BITS-1:0] pulse_state_pipe;
    reg [4:0]                          output_shift_pipe;
    reg                                enable_pipe;
    reg                                overflow_pipe;

    integer i;

    assign decay_shift_eff = (FIXED_DECAY_SHIFT != 5'd0) ?
                             FIXED_DECAY_SHIFT : decay_shift;

    // ── Stage 1: Decay + accumulate ──
    // Computes per-lane next_state and updates decay_state.
    // Results are registered in pulse_state_vec_d (for debug visibility)
    // and fed to Stage 2 via pulse_state_pipe.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decay_state    <= {ACC_BITS{1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d <= 5'd0;
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_pipe <= 5'd0;
            enable_pipe <= 1'b0;
            overflow_pipe <= 1'b0;
        end else if (clear) begin
            decay_state    <= {ACC_BITS{1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d <= 5'd0;
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_pipe <= 5'd0;
            enable_pipe <= 1'b0;
            overflow_pipe <= 1'b0;
        end else if (enable) begin
            work_state = decay_state;
            overflow_next = 1'b0;

            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                if (impulse_valid_vec[i]) begin
                    impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS] <=
                        {{(ACC_BITS-IMP_BITS-FRAC_BITS){1'b0}},
                         impulse_sum_vec[i*IMP_BITS +: IMP_BITS],
                         {FRAC_BITS{1'b0}}};
                end else begin
                    impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS] <= {ACC_BITS{1'b0}};
                end

                impulse_ext = impulse_ext_vec_d[i*ACC_BITS +: ACC_BITS];
                if (DECAY_BEFORE_ACCUMULATE != 0) begin
                    decayed_state = work_state - (work_state >> decay_shift_eff);
                    next_state = decayed_state + impulse_ext;

                    if ((ENABLE_STATE_OVERFLOW != 0) &&
                        (next_state < decayed_state)) begin
                        overflow_next = 1'b1;
                    end

                    pulse_state_vec_d[i*ACC_BITS +: ACC_BITS] <= next_state;
                    work_state = next_state;
                end else begin
                    next_state = work_state + impulse_ext;

                    if ((ENABLE_STATE_OVERFLOW != 0) &&
                        (next_state < work_state)) begin
                        overflow_next = 1'b1;
                    end

                    pulse_state_vec_d[i*ACC_BITS +: ACC_BITS] <= next_state;

                    decayed_state = next_state - (next_state >> decay_shift_eff);
                    work_state = decayed_state;
                end
            end

            decay_state <= work_state;
            output_shift_d <= output_shift;

            // Pipeline register: capture stage-1 results for stage-2
            pulse_state_pipe <= pulse_state_vec_d;
            output_shift_pipe <= output_shift_d;
            enable_pipe <= 1'b1;
            overflow_pipe <= overflow_next;
        end else begin
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_pipe <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            enable_pipe <= 1'b0;
            overflow_pipe <= 1'b0;
        end
    end

    // ── Stage 2: Saturation check and pulse output ──
    // Uses registered pulse_state_pipe to break the carry chain
    // from the accumulate loop. This isolates the 48-bit reduction-OR
    // from the decay_state → decay_state feedback path.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulse_vec      <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
            state_overflow <= 1'b0;
        end else if (clear) begin
            pulse_vec      <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
            state_overflow <= 1'b0;
        end else if (enable_pipe) begin
            pulse_overflow_next = 1'b0;

            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                scaled_state = pulse_state_pipe[i*ACC_BITS +: ACC_BITS] >> output_shift_pipe;
                if (|scaled_state[ACC_BITS-1:PULSE_BITS]) begin
                    pulse_vec[i*PULSE_BITS +: PULSE_BITS] <= {PULSE_BITS{1'b1}};
                    pulse_overflow_next = 1'b1;
                end else begin
                    pulse_vec[i*PULSE_BITS +: PULSE_BITS] <= scaled_state[PULSE_BITS-1:0];
                end
            end

            state_overflow <= overflow_pipe | pulse_overflow_next;
        end else begin
            pulse_vec <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
        end
    end

endmodule
