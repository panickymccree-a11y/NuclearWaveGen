`timescale 1ns/1ps

module tb_nuc_event_gen_10mcps;

    localparam integer RUN_DAC_CLK_CYCLES = 200000;

    reg clk_50m;
    reg rst_n;

    wire        dac_clk_p;
    wire        dac_clk_n;
    wire [15:0] dac1_data;
    wire [15:0] dac2_data;

    reg [15:0] prev_dac1_data;
    reg [15:0] prev_dac2_data;
    integer dac1_change_count;
    integer dac2_change_count;
    integer dac1_nonzero_count;
    integer dac2_nonzero_count;
    integer dac1_fullscale_count;
    integer dac2_fullscale_count;
    integer cycle_count;

    nuc_event_gen_10mcps_io_top dut (
        .clk_50m(clk_50m),
        .rst_n(rst_n),
        .dac_clk_p(dac_clk_p),
        .dac_clk_n(dac_clk_n),
        .dac1_data(dac1_data),
        .dac2_data(dac2_data)
    );

    initial begin
        clk_50m = 1'b0;
        forever #10 clk_50m = ~clk_50m;
    end

    always @(posedge dac_clk_p or negedge rst_n) begin
        if (!rst_n) begin
            prev_dac1_data <= 16'd0;
            prev_dac2_data <= 16'd0;
            dac1_change_count <= 0;
            dac2_change_count <= 0;
            dac1_nonzero_count <= 0;
            dac2_nonzero_count <= 0;
            dac1_fullscale_count <= 0;
            dac2_fullscale_count <= 0;
        end else begin
            if (dac1_data != prev_dac1_data)
                dac1_change_count <= dac1_change_count + 1;
            if (dac2_data != prev_dac2_data)
                dac2_change_count <= dac2_change_count + 1;
            if (dac1_data != 16'd0)
                dac1_nonzero_count <= dac1_nonzero_count + 1;
            if (dac2_data != 16'd0)
                dac2_nonzero_count <= dac2_nonzero_count + 1;
            if (dac1_data == 16'hffff)
                dac1_fullscale_count <= dac1_fullscale_count + 1;
            if (dac2_data == 16'hffff)
                dac2_fullscale_count <= dac2_fullscale_count + 1;
            prev_dac1_data <= dac1_data;
            prev_dac2_data <= dac2_data;
        end
    end

    initial begin
        rst_n = 1'b0;
        cycle_count = 0;

        repeat (20) @(posedge clk_50m);
        rst_n = 1'b1;

        repeat (RUN_DAC_CLK_CYCLES) begin
            @(posedge dac_clk_p);
            cycle_count = cycle_count + 1;
        end

        $display("dac cycles observed = %0d", cycle_count);
        $display("dac1_change_count  = %0d", dac1_change_count);
        $display("dac2_change_count  = %0d", dac2_change_count);
        $display("dac1_nonzero_count = %0d", dac1_nonzero_count);
        $display("dac2_nonzero_count = %0d", dac2_nonzero_count);
        $display("dac1_fullscale_count = %0d", dac1_fullscale_count);
        $display("dac2_fullscale_count = %0d", dac2_fullscale_count);
        $display("dac1_last          = 0x%04x", dac1_data);
        $display("dac2_last          = 0x%04x", dac2_data);

        if (dac_clk_n !== ~dac_clk_p)
            $fatal(1, "dac_clk_n is not the complement of dac_clk_p");
        if (dac1_change_count < 10)
            $fatal(1, "dac1_data did not show enough activity");
        if (dac2_change_count < 10)
            $fatal(1, "dac2_data did not show enough activity");
        if (dac1_nonzero_count < 10)
            $fatal(1, "dac1_data stayed near zero");
        if (dac2_nonzero_count < 10)
            $fatal(1, "dac2_data stayed near zero");
        if ((dac1_fullscale_count * 10) > (cycle_count * 9))
            $fatal(1, "dac1_data is dominated by full-scale samples");
        if ((dac2_fullscale_count * 10) > (cycle_count * 9))
            $fatal(1, "dac2_data is dominated by full-scale samples");

        #100;
        $finish;
    end

endmodule
