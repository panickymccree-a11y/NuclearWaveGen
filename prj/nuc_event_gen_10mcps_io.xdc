# XC7A100T-FGG484 physical IO constraints for AD9747 dual-port output.
# AD9747 data ports use LVCMOS25. DAC clock uses the fixed K18/K19 MRCC pair.

create_clock -name clk_50m -period 20.000 [get_ports clk_50m]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Board reference clock and reset.
set_property PACKAGE_PIN R4  [get_ports clk_50m]
set_property PACKAGE_PIN R18 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports {clk_50m rst_n}]
set_property PULLUP true [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# AD9747 DAC clock, fixed MRCC pair in Bank15.
set_property PACKAGE_PIN K18 [get_ports dac_clk_p]
set_property PACKAGE_PIN K19 [get_ports dac_clk_n]
set_property IOSTANDARD LVDS_25 [get_ports {dac_clk_p dac_clk_n}]

# DAC1 data, Bank15, LVCMOS25.
set_property PACKAGE_PIN G13 [get_ports {dac1_data[0]}]
set_property PACKAGE_PIN G15 [get_ports {dac1_data[1]}]
set_property PACKAGE_PIN G16 [get_ports {dac1_data[2]}]
set_property PACKAGE_PIN G17 [get_ports {dac1_data[3]}]
set_property PACKAGE_PIN G18 [get_ports {dac1_data[4]}]
set_property PACKAGE_PIN G20 [get_ports {dac1_data[5]}]
set_property PACKAGE_PIN H13 [get_ports {dac1_data[6]}]
set_property PACKAGE_PIN H14 [get_ports {dac1_data[7]}]
set_property PACKAGE_PIN H15 [get_ports {dac1_data[8]}]
set_property PACKAGE_PIN H17 [get_ports {dac1_data[9]}]
set_property PACKAGE_PIN H18 [get_ports {dac1_data[10]}]
set_property PACKAGE_PIN H19 [get_ports {dac1_data[11]}]
set_property PACKAGE_PIN H20 [get_ports {dac1_data[12]}]
set_property PACKAGE_PIN H22 [get_ports {dac1_data[13]}]
set_property PACKAGE_PIN J14 [get_ports {dac1_data[14]}]
set_property PACKAGE_PIN J15 [get_ports {dac1_data[15]}]

# DAC2 data, Bank16, LVCMOS25.
set_property PACKAGE_PIN A13 [get_ports {dac2_data[0]}]
set_property PACKAGE_PIN A14 [get_ports {dac2_data[1]}]
set_property PACKAGE_PIN A15 [get_ports {dac2_data[2]}]
set_property PACKAGE_PIN A16 [get_ports {dac2_data[3]}]
set_property PACKAGE_PIN A18 [get_ports {dac2_data[4]}]
set_property PACKAGE_PIN A19 [get_ports {dac2_data[5]}]
set_property PACKAGE_PIN A20 [get_ports {dac2_data[6]}]
set_property PACKAGE_PIN A21 [get_ports {dac2_data[7]}]
set_property PACKAGE_PIN B13 [get_ports {dac2_data[8]}]
set_property PACKAGE_PIN B15 [get_ports {dac2_data[9]}]
set_property PACKAGE_PIN B16 [get_ports {dac2_data[10]}]
set_property PACKAGE_PIN B17 [get_ports {dac2_data[11]}]
set_property PACKAGE_PIN B18 [get_ports {dac2_data[12]}]
set_property PACKAGE_PIN B20 [get_ports {dac2_data[13]}]
set_property PACKAGE_PIN B21 [get_ports {dac2_data[14]}]
set_property PACKAGE_PIN B22 [get_ports {dac2_data[15]}]

set_property IOSTANDARD LVCMOS25 [get_ports {dac1_data[*] dac2_data[*]}]
