`timescale 1ns/1ps

module tb_nuc_event_gen_10mcps;

    localparam integer SAMPLES_PER_CLK = 2;
    localparam integer DAC_BITS        = 16;
    localparam integer PULSE_BITS      = 32;
    localparam integer ICDF_ADDR_BITS  = 14;
    localparam integer AMP_BITS        = 16;
    localparam integer IMP_BITS        = 24;
    localparam integer K_BITS          = 3;
    localparam integer NOISE_BITS      = 16;
    localparam integer RUN_CYCLES      = 1000000;

    reg clk;
    reg rst_n;

    reg        cfg_valid;
    reg        cfg_write;
    reg [7:0]  cfg_addr;
    reg [31:0] cfg_wdata;
    wire [31:0] cfg_rdata;
    wire        cfg_ready;

    reg                         amp_lut_we;
    reg [ICDF_ADDR_BITS-1:0]    amp_lut_addr;
    reg [AMP_BITS-1:0]          amp_lut_wdata;

    wire [SAMPLES_PER_CLK*DAC_BITS-1:0] dac_sample_vec;
    wire                                dac_sample_valid;
    wire [SAMPLES_PER_CLK-1:0]          event_valid_vec;
    wire [SAMPLES_PER_CLK-1:0]          impulse_valid_vec;
    wire [SAMPLES_PER_CLK-1:0]          saturation_vec;
    wire [31:0]                         status_word;

    reg [31:0] sample_lo;
    reg [31:0] sample_hi;
    reg [31:0] cand_lo;
    reg [31:0] cand_hi;
    reg [31:0] emit_lo;
    reg [31:0] emit_hi;
    reg [31:0] sat_lo;
    reg [31:0] sat_hi;
    reg [31:0] observed_occupied_lanes;
    reg [31:0] observed_multi_event_lanes;
    reg [31:0] observed_event_total;
    reg [31:0] occupied_inc;
    reg [31:0] multi_event_inc;
    reg [31:0] event_total_inc;

    wire [31:0] sample_lo_live = dut.sample_count[31:0];
    wire [31:0] sample_hi_live = dut.sample_count[63:32];
    wire [31:0] cand_lo_live   = dut.candidate_count[31:0];
    wire [31:0] cand_hi_live   = dut.candidate_count[63:32];
    wire [31:0] emit_lo_live   = dut.emitted_count[31:0];
    wire [31:0] emit_hi_live   = dut.emitted_count[63:32];
    wire [31:0] sat_lo_live    = dut.saturation_count[31:0];
    wire [31:0] sat_hi_live    = dut.saturation_count[63:32];

    wire [DAC_BITS-1:0] dac_lane0 = dac_sample_vec[0*DAC_BITS +: DAC_BITS];
    wire [DAC_BITS-1:0] dac_lane1 = dac_sample_vec[1*DAC_BITS +: DAC_BITS];
    wire [PULSE_BITS-1:0] pulse_lane0 = dut.pulse_vec[0*PULSE_BITS +: PULSE_BITS];
    wire [PULSE_BITS-1:0] pulse_lane1 = dut.pulse_vec[1*PULSE_BITS +: PULSE_BITS];
    wire [K_BITS-1:0] event_count_lane0 = dut.event_count_vec[0*K_BITS +: K_BITS];
    wire [K_BITS-1:0] event_count_lane1 = dut.event_count_vec[1*K_BITS +: K_BITS];
    wire [K_BITS-1:0] impulse_count_lane0 = dut.impulse_count_vec[0*K_BITS +: K_BITS];
    wire [K_BITS-1:0] impulse_count_lane1 = dut.impulse_count_vec[1*K_BITS +: K_BITS];
    wire [IMP_BITS-1:0] impulse_sum_lane0 = dut.impulse_sum_vec[0*IMP_BITS +: IMP_BITS];
    wire [IMP_BITS-1:0] impulse_sum_lane1 = dut.impulse_sum_vec[1*IMP_BITS +: IMP_BITS];
    wire signed [NOISE_BITS-1:0] noise_lane0 = dut.noise_vec[0*NOISE_BITS +: NOISE_BITS];
    wire signed [NOISE_BITS-1:0] noise_lane1 = dut.noise_vec[1*NOISE_BITS +: NOISE_BITS];

    reg [DAC_BITS-1:0]   dac_sample_analog;
    reg [PULSE_BITS-1:0] pulse_sample_analog;
    integer obs_i;

    // ── Poisson verification event log ────────────────────────────
    integer        fd_event_log;
    reg [63:0]     log_cycle;

    nuc_event_gen_10mcps_top #(
        .SAMPLES_PER_CLK(SAMPLES_PER_CLK),
        .DAC_BITS(DAC_BITS),
        .ICDF_ADDR_BITS(ICDF_ADDR_BITS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(cfg_valid),
        .cfg_write(cfg_write),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata),
        .cfg_ready(cfg_ready),
        .amp_lut_we(amp_lut_we),
        .amp_lut_addr(amp_lut_addr),
        .amp_lut_wdata(amp_lut_wdata),
        .dac_sample_vec(dac_sample_vec),
        .dac_sample_valid(dac_sample_valid),
        .event_valid_vec(event_valid_vec),
        .impulse_valid_vec(impulse_valid_vec),
        .saturation_vec(saturation_vec),
        .status_word(status_word)
    );

    initial begin
        clk = 1'b0;
        forever #2 clk = ~clk; // 250 MHz
    end

    initial begin
        dac_sample_analog   = {DAC_BITS{1'b0}};
        pulse_sample_analog = {PULSE_BITS{1'b0}};

        forever begin
            @(posedge clk);
            #1;
            if (dac_sample_valid) begin
                dac_sample_analog   = dac_lane0;
                pulse_sample_analog = pulse_lane0;
            end else begin
                dac_sample_analog   = {DAC_BITS{1'b0}};
                pulse_sample_analog = {PULSE_BITS{1'b0}};
            end

            #2;
            if (dac_sample_valid) begin
                dac_sample_analog   = dac_lane1;
                pulse_sample_analog = pulse_lane1;
            end else begin
                dac_sample_analog   = {DAC_BITS{1'b0}};
                pulse_sample_analog = {PULSE_BITS{1'b0}};
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            observed_occupied_lanes    <= 32'd0;
            observed_multi_event_lanes <= 32'd0;
            observed_event_total       <= 32'd0;
        end else if (dut.run_enable) begin
            occupied_inc    = 32'd0;
            multi_event_inc = 32'd0;
            event_total_inc = 32'd0;

            for (obs_i = 0; obs_i < SAMPLES_PER_CLK; obs_i = obs_i + 1) begin
                if (dut.event_count_vec[obs_i*K_BITS +: K_BITS] != 0)
                    occupied_inc = occupied_inc + 1;
                if (dut.event_count_vec[obs_i*K_BITS +: K_BITS] > 1)
                    multi_event_inc = multi_event_inc + 1;
                event_total_inc = event_total_inc +
                    dut.event_count_vec[obs_i*K_BITS +: K_BITS];
            end

            observed_occupied_lanes    <= observed_occupied_lanes + occupied_inc;
            observed_multi_event_lanes <= observed_multi_event_lanes + multi_event_inc;
            observed_event_total       <= observed_event_total + event_total_inc;
        end
    end

    // ── Event log writer: one CSV row per clock when run_enable=1 ──
    // Format: cycle,lane0_event_count,lane1_event_count
    always @(posedge clk) begin
        if (rst_n && dut.run_enable) begin
            $fwrite(fd_event_log, "%0d,%0d,%0d\n",
                    log_cycle,
                    event_count_lane0,
                    event_count_lane1);
            log_cycle <= log_cycle + 64'd1;
        end
    end

    task cfg_write32;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge clk);
            cfg_valid <= 1'b1;
            cfg_write <= 1'b1;
            cfg_addr  <= addr;
            cfg_wdata <= data;
            @(posedge clk);
            cfg_valid <= 1'b0;
            cfg_write <= 1'b0;
            cfg_wdata <= 32'd0;
        end
    endtask

    task cfg_read32;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            data = 32'd0;
            @(posedge clk);
            cfg_valid <= 1'b1;
            cfg_write <= 1'b0;
            cfg_addr  <= addr;
            @(posedge clk);
            cfg_valid <= 1'b0;
            @(posedge clk);   // +1 cycle for cfg_rdata pipeline register
            #1;
            data = cfg_rdata;
            cfg_addr  <= 8'd0;
        end
    endtask

    initial begin
        rst_n         = 1'b0;
        cfg_valid     = 1'b0;
        cfg_write     = 1'b0;
        cfg_addr      = 8'd0;
        cfg_wdata     = 32'd0;
        amp_lut_we    = 1'b0;
        amp_lut_addr  = {ICDF_ADDR_BITS{1'b0}};
        amp_lut_wdata = {AMP_BITS{1'b0}};
        sample_lo     = 32'd0;
        sample_hi     = 32'd0;
        cand_lo       = 32'd0;
        cand_hi       = 32'd0;
        emit_lo       = 32'd0;
        emit_hi       = 32'd0;
        sat_lo        = 32'd0;
        sat_hi        = 32'd0;
        observed_occupied_lanes    = 32'd0;
        observed_multi_event_lanes = 32'd0;
        observed_event_total       = 32'd0;
        occupied_inc               = 32'd0;
        multi_event_inc            = 32'd0;
        event_total_inc            = 32'd0;

        // Open event log for Poisson verification.
        // File is created in the simulator's working directory.
        fd_event_log = $fopen("event_log.csv", "w");
        if (fd_event_log == 0) begin
            $display("ERROR: Cannot open event_log.csv for writing");
            $finish;
        end
        $display("Poisson event log: event_log.csv");
        $fwrite(fd_event_log, "cycle,lane0_event_count,lane1_event_count\n");
        log_cycle = 64'd0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // Default threshold is 10 Mcps at 500 MS/s equivalent:
        // round(10e6 / 500e6 * 2^32) = 85,899,346 = 0x051EB852.
        cfg_write32(8'h04, 32'h051E_B852);

        // Use ICDF LUT mode. The built-in default LUT is a monotonic ramp.
        cfg_write32(8'h08, 32'h0001_2000);

        // Exponential decay tau is approximately 2^8 samples = 512 ns
        // at the default 500 MS/s equivalent sample rate. The output shift is
        // set to 15 in this waveform test to keep the 10 Mcps ramp-amplitude
        // pile-up below DAC saturation so the exponential tail remains visible.
        cfg_write32(8'h0C, 32'd4);
        cfg_write32(8'h10, 32'd15);

        // Enable signed white noise. noise_shift=6 gives roughly +/-512 LSB
        // uniform noise before DAC clipping.
        cfg_write32(8'h18, 32'h0000_0601);

        // Enable run.
        cfg_write32(8'h00, 32'h0000_0001);

        repeat (RUN_CYCLES) @(posedge clk);

        cfg_write32(8'h00, 32'h0000_0000);

        cfg_read32(8'h40, sample_lo);
        cfg_read32(8'h44, sample_hi);
        cfg_read32(8'h48, cand_lo);
        cfg_read32(8'h4C, cand_hi);
        cfg_read32(8'h50, emit_lo);
        cfg_read32(8'h54, emit_hi);
        cfg_read32(8'h58, sat_lo);
        cfg_read32(8'h5C, sat_hi);

        $display("sample_count     = 0x%08x%08x", sample_hi, sample_lo);
        $display("candidate_count  = 0x%08x%08x", cand_hi, cand_lo);
        $display("emitted_count    = 0x%08x%08x", emit_hi, emit_lo);
        $display("saturation_count = 0x%08x%08x", sat_hi, sat_lo);
        $display("observed_occupied_lanes    = %0d", observed_occupied_lanes);
        $display("observed_multi_event_lanes = %0d", observed_multi_event_lanes);
        $display("observed_event_total       = %0d", observed_event_total);
        $display("status_word      = 0x%08x", status_word);

        $fclose(fd_event_log);
        $display("event_log written: event_log.csv  (%0d cycles)", log_cycle);

        #100;
        $finish;
    end

endmodule
