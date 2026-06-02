`timescale 1ns/1ps

// One-pole exponential decay shaper.
// Lanes are time-interleaved samples inside one core clock. The state is
// updated lane by lane, so lane0 and lane1 form one continuous exponential
// sample stream when viewed in sequence.
// For every sample lane:
//   state = state + (impulse << FRAC_BITS)
//   pulse = state >> output_shift
//   state = state - (state >> decay_shift)
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

    integer i;

    assign decay_shift_eff = (FIXED_DECAY_SHIFT != 5'd0) ?
                             FIXED_DECAY_SHIFT : decay_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decay_state    <= {ACC_BITS{1'b0}};
            pulse_vec      <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d <= 5'd0;
            state_overflow <= 1'b0;
        end else if (clear) begin
            decay_state    <= {ACC_BITS{1'b0}};
            pulse_vec      <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            output_shift_d <= 5'd0;
            state_overflow <= 1'b0;
        end else if (enable) begin
            work_state = decay_state;
            overflow_next = 1'b0;
            pulse_overflow_next = 1'b0;

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

            for (i = 0; i < SAMPLES_PER_CLK; i = i + 1) begin
                scaled_state = pulse_state_vec_d[i*ACC_BITS +: ACC_BITS] >> output_shift_d;
                if (|scaled_state[ACC_BITS-1:PULSE_BITS]) begin
                    pulse_vec[i*PULSE_BITS +: PULSE_BITS] <= {PULSE_BITS{1'b1}};
                    pulse_overflow_next = 1'b1;
                end else begin
                    pulse_vec[i*PULSE_BITS +: PULSE_BITS] <= scaled_state[PULSE_BITS-1:0];
                end
            end

            decay_state <= work_state;
            output_shift_d <= output_shift;
            state_overflow <= overflow_next | pulse_overflow_next;
        end else begin
            pulse_vec <= {(SAMPLES_PER_CLK*PULSE_BITS){1'b0}};
            impulse_ext_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
            pulse_state_vec_d <= {(SAMPLES_PER_CLK*ACC_BITS){1'b0}};
        end
    end

endmodule
