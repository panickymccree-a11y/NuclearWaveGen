$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
}

function Assert-Match($Text, $Pattern, $Message) {
    if ($Text -notmatch $Pattern) {
        Fail $Message
    }
}

function Assert-NoMatch($Text, $Pattern, $Message) {
    if ($Text -match $Pattern) {
        Fail $Message
    }
}

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$topPath = Join-Path $repo "rtl\nuc_event_gen_10mcps_io_top.v"
$filelistPath = Join-Path $repo "rtl\filelist.f"
$ampMultiportPath = Join-Path $repo "rtl\amp_lut_multiport.v"
$xdcPath = Join-Path $repo "prj\nuc_event_gen_10mcps_io.xdc"

$top = Get-Content -Raw $topPath
$filelist = Get-Content -Raw $filelistPath
$ampMultiport = Get-Content -Raw $ampMultiportPath
$xdc = Get-Content -Raw $xdcPath

Assert-Match $top "module\s+nuc_event_gen_10mcps_io_top\b" "physical top module is missing"
Assert-Match $top "\binput\s+wire\s+clk_50m\b" "top must expose clk_50m input"
Assert-Match $top "\binput\s+wire\s+rst_n\b" "top must expose rst_n input"
Assert-Match $top "\boutput\s+wire\s+dac_clk_p\b" "top must expose dac_clk_p output"
Assert-Match $top "\boutput\s+wire\s+dac_clk_n\b" "top must expose dac_clk_n output"
Assert-Match $top "\boutput\s+wire\s+\[15:0\]\s+dac1_data\b" "top must expose dac1_data[15:0]"
Assert-Match $top "\boutput\s+wire\s+\[15:0\]\s+dac2_data\b" "top must expose dac2_data[15:0]"

Assert-NoMatch $top "\b(cfg_valid|cfg_write|cfg_addr|cfg_wdata|cfg_rdata|cfg_ready)\b" "physical top must not expose cfg bus"
Assert-NoMatch $top "\b(amp_lut_we|amp_lut_addr|amp_lut_wdata)\b" "physical top must not expose amp LUT write bus"
Assert-NoMatch $top "\bdac_sample_vec\b" "physical top must not expose internal dac_sample_vec"

Assert-Match $top "\bclk_wiz_0\s+\w+" "top must instantiate clk_wiz_0"
Assert-Match $top "\bnuc_event_gen_dac_channel\s+#?\s*\(" "top must instantiate nuc_event_gen_dac_channel"
if (([regex]::Matches($top, "\bnuc_event_gen_dac_channel\s+#?\s*\(")).Count -lt 2) {
    Fail "top must instantiate two nuc_event_gen_dac_channel modules"
}
Assert-Match $top "\bdac_2x_output_serializer\s+#?\s*\(" "top must instantiate dac_2x_output_serializer"
Assert-Match $top "\bOBUFDS\b" "top must drive DAC clock through OBUFDS for synthesis"

Assert-Match $filelist "(?m)^nuc_event_gen_dac_channel\.v\s*$" "filelist must include nuc_event_gen_dac_channel.v"
Assert-Match $filelist "(?m)^dac_2x_output_serializer\.v\s*$" "filelist must include dac_2x_output_serializer.v"
Assert-Match $filelist "(?m)^amp_lut_dual_read_port\.v\s*$" "filelist must include amp_lut_dual_read_port.v"
Assert-Match $ampMultiport "\bREADS_PER_REPLICA\s*=\s*2\b" "amp_lut_multiport must pair read ports per LUT replica"
Assert-Match $ampMultiport "\bamp_lut_dual_read_port\s+#?\s*\(" "amp_lut_multiport must instantiate amp_lut_dual_read_port"

Assert-Match $xdc "create_clock\s+-name\s+clk_50m\s+-period\s+20\.000\s+\[get_ports\s+clk_50m\]" "XDC must constrain clk_50m as 50 MHz"
Assert-Match $xdc "PACKAGE_PIN\s+R4\s+\[get_ports\s+clk_50m\]" "XDC must assign R4 to clk_50m"
Assert-Match $xdc "PACKAGE_PIN\s+R18\s+\[get_ports\s+rst_n\]" "XDC must assign R18 to rst_n"
Assert-Match $xdc "PACKAGE_PIN\s+K18\s+\[get_ports\s+dac_clk_p\]" "XDC must assign K18 to dac_clk_p"
Assert-Match $xdc "PACKAGE_PIN\s+K19\s+\[get_ports\s+dac_clk_n\]" "XDC must assign K19 to dac_clk_n"
Assert-Match $xdc "IOSTANDARD\s+LVCMOS33\s+\[get_ports\s+\{clk_50m\s+rst_n\}\]" "XDC must set clk_50m/rst_n to LVCMOS33"
Assert-Match $xdc "IOSTANDARD\s+LVDS_25\s+\[get_ports\s+\{dac_clk_p\s+dac_clk_n\}\]" "XDC must set DAC clock to LVDS_25"
Assert-Match $xdc "IOSTANDARD\s+LVCMOS25\s+\[get_ports\s+\{dac1_data\[\*\]\s+dac2_data\[\*\]\}\]" "XDC must set DAC data buses to LVCMOS25"

foreach ($bit in 0..15) {
    Assert-Match $xdc "PACKAGE_PIN\s+\S+\s+\[get_ports\s+\{dac1_data\[$bit\]\}\]" "XDC missing pin for dac1_data[$bit]"
    Assert-Match $xdc "PACKAGE_PIN\s+\S+\s+\[get_ports\s+\{dac2_data\[$bit\]\}\]" "XDC missing pin for dac2_data[$bit]"
}

Write-Output "AD9747 top static checks passed."
