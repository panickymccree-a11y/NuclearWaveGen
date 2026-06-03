`timescale 1ns/1ps

// Physical top for AD9747 dual-port operation.
// R4 provides a 50 MHz reference clock. clk_wiz_0 generates 125 MHz for
// waveform generation and 250 MHz for the AD9747 data/clock output stage.
module nuc_event_gen_10mcps_io_top (
    input  wire                  clk_50m,
    input  wire                  rst_n,
    output wire                  dac_clk_p,
    output wire                  dac_clk_n,
    output wire [15:0]           dac1_data,
    output wire [15:0]           dac2_data
);

    localparam integer DAC_BITS = 16;

    wire clk_125m;
    wire clk_250m;
    wire clk_locked;

    reg [2:0] rst_125_sync;
    reg [2:0] rst_250_sync;

    wire rst_mmcm = ~rst_n;
    wire rst_125_n = rst_125_sync[2];
    wire rst_250_n = rst_250_sync[2];

    wire [2*DAC_BITS-1:0] ch1_sample_pair;
    wire [2*DAC_BITS-1:0] ch2_sample_pair;
    wire ch1_sample_valid;
    wire ch2_sample_valid;
    wire ch1_sample_toggle;
    wire ch2_sample_toggle;
    wire sample_valid = ch1_sample_valid & ch2_sample_valid;
    wire channels_enabled = rst_125_n;

    clk_wiz_0 u_clk_wiz (
        .clk_125M(clk_125m),
        .clk_250M(clk_250m),
        .reset(rst_mmcm),
        .locked(clk_locked),
        .clk_in1(clk_50m)
    );

    always @(posedge clk_125m or negedge rst_n) begin
        if (!rst_n) begin
            rst_125_sync <= 3'b000;
        end else if (!clk_locked) begin
            rst_125_sync <= 3'b000;
        end else begin
            rst_125_sync <= {rst_125_sync[1:0], 1'b1};
        end
    end

    always @(posedge clk_250m or negedge rst_n) begin
        if (!rst_n) begin
            rst_250_sync <= 3'b000;
        end else if (!clk_locked) begin
            rst_250_sync <= 3'b000;
        end else begin
            rst_250_sync <= {rst_250_sync[1:0], 1'b1};
        end
    end

    nuc_event_gen_dac_channel #(
        .RNG_SEED_SALT(64'h0000_0000_0000_0001)
    ) u_dac1_channel (
        .clk_125m(clk_125m),
        .rst_n(rst_125_n),
        .enable(channels_enabled),
        .sample_pair(ch1_sample_pair),
        .sample_valid(ch1_sample_valid),
        .sample_toggle(ch1_sample_toggle)
    );

    nuc_event_gen_dac_channel #(
        .RNG_SEED_SALT(64'h0000_0000_0000_1001)
    ) u_dac2_channel (
        .clk_125m(clk_125m),
        .rst_n(rst_125_n),
        .enable(channels_enabled),
        .sample_pair(ch2_sample_pair),
        .sample_valid(ch2_sample_valid),
        .sample_toggle(ch2_sample_toggle)
    );

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
