`timescale 1ns/1ps

// Minimal single-clock register file.
// Addresses are byte addresses and all registers are 32-bit.
module cfg_regfile_10mcps #(
    parameter [31:0] MAX_RATE_THRESHOLD_Q32 = 32'd85899346,
    parameter [4:0]  DEFAULT_DECAY_SHIFT    = 5'd8,
    parameter [4:0]  DEFAULT_OUTPUT_SHIFT   = 5'd12,
    parameter [4:0]  DEFAULT_NOISE_SHIFT    = 5'd8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cfg_valid,
    input  wire        cfg_write,
    input  wire [7:0]  cfg_addr,
    input  wire [31:0] cfg_wdata,
    output reg  [31:0] cfg_rdata,
    output wire        cfg_ready,

    output reg         run_enable,
    output reg         soft_reset_pulse,
    output reg  [31:0] rate_threshold_q32,
    output reg         amp_lut_en,
    output reg  [15:0] fixed_amp,
    output reg  [4:0]  decay_shift,
    output reg  [4:0]  output_shift,
    output reg  signed [31:0] baseline_offset,
    output reg         noise_enable,
    output reg  [4:0]  noise_shift,
    output reg         seed_load,
    output reg  [7:0]  seed_sel,
    output reg         seed_zero,
    output reg  [63:0] seed_data,

    input  wire [63:0] sample_count,
    input  wire [63:0] candidate_count,
    input  wire [63:0] emitted_count,
    input  wire [63:0] saturation_count,
    input  wire [31:0] status_word
);

    localparam [7:0] ADDR_CTRL          = 8'h00;
    localparam [7:0] ADDR_RATE_Q32      = 8'h04;
    localparam [7:0] ADDR_AMP_CTRL      = 8'h08;
    localparam [7:0] ADDR_DECAY_SHIFT   = 8'h0C;
    localparam [7:0] ADDR_OUTPUT_SHIFT  = 8'h10;
    localparam [7:0] ADDR_BASELINE      = 8'h14;
    localparam [7:0] ADDR_NOISE_CTRL    = 8'h18;
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

    reg [31:0] seed_lo;
    reg [31:0] seed_hi;
    reg [7:0]  seed_sel_cfg;
    reg        seed_zero_cfg;
    reg        seed_load_pending;

    assign cfg_ready = 1'b1;

    // ── Output pipeline register to break long mux-to-pad timing path ──
    reg [31:0] cfg_rdata_pre;

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
                default:           read_mux = 32'd0;
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
            seed_load          <= 1'b0;
            seed_sel           <= 8'd0;
            seed_zero          <= 1'b1;
            seed_data          <= 64'd0;
            seed_lo            <= 32'd0;
            seed_hi            <= 32'd0;
            seed_sel_cfg       <= 8'd0;
            seed_zero_cfg      <= 1'b1;
            seed_load_pending  <= 1'b0;
            cfg_rdata_pre     <= 32'd0;
            cfg_rdata          <= 32'd0;
        end else begin
            soft_reset_pulse <= 1'b0;
            seed_load        <= seed_load_pending;
            seed_load_pending <= 1'b0;
            cfg_rdata_pre    <= read_mux(cfg_addr);
            cfg_rdata        <= cfg_rdata_pre;

            if (cfg_valid && cfg_write) begin
                case (cfg_addr)
                    ADDR_CTRL: begin
                        run_enable <= cfg_wdata[0];
                        if (cfg_wdata[1])
                            soft_reset_pulse <= 1'b1;
                    end

                    ADDR_RATE_Q32: begin
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

                    ADDR_SEED_SEL: begin
                        seed_sel_cfg <= cfg_wdata[7:0];
                    end

                    ADDR_SEED_LO: begin
                        seed_lo       <= cfg_wdata;
                        seed_zero_cfg <= (cfg_wdata == 32'd0) && (seed_hi == 32'd0);
                    end

                    ADDR_SEED_HI: begin
                        seed_hi       <= cfg_wdata;
                        seed_zero_cfg <= (seed_lo == 32'd0) && (cfg_wdata == 32'd0);
                    end

                    ADDR_SEED_COMMIT: begin
                        seed_sel           <= seed_sel_cfg;
                        seed_data          <= {seed_hi, seed_lo};
                        seed_zero          <= seed_zero_cfg;
                        seed_load_pending  <= 1'b1;
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule
