# RFSoC 4x2 (XCZU48DR-FFVG1517-2-E) pins and clocks for the ERNIC design.
# PL DDR4 pins are in 4x2_PL_DDR4.xdc (RFSoC 4x2 board constraints).

set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]

# 100 MHz PL system clock
set_property PACKAGE_PIN AM15 [get_ports clk_p]
set_property PACKAGE_PIN AN15 [get_ports clk_n]
set_property IOSTANDARD LVDS [get_ports {clk_p clk_n}]
create_clock -period 10.000 -name clk_100 [get_ports clk_p]

# reset push button (active low)
set_property -dict {PACKAGE_PIN AN12 IOSTANDARD LVCMOS18} [get_ports reset_n]
set_false_path -from [get_ports reset_n]

# QSFP28 sideband
set_property -dict {PACKAGE_PIN AK22 IOSTANDARD LVCMOS18} [get_ports qsfp0_modsell]
set_property -dict {PACKAGE_PIN AL21 IOSTANDARD LVCMOS18} [get_ports qsfp0_resetl]
set_property -dict {PACKAGE_PIN AL22 IOSTANDARD LVCMOS18} [get_ports qsfp0_modprsl]
set_property -dict {PACKAGE_PIN AM22 IOSTANDARD LVCMOS18} [get_ports qsfp0_intl]
set_property -dict {PACKAGE_PIN AN22 IOSTANDARD LVCMOS18} [get_ports qsfp0_lpmode]
set_false_path -to [get_ports {qsfp0_modsell qsfp0_resetl qsfp0_lpmode}]
set_false_path -from [get_ports {qsfp0_modprsl qsfp0_intl}]

# QSFP28 GT reference clock (156.25 MHz); the CMAC IP places the four GT channels (X0Y4..X0Y7)
set_property PACKAGE_PIN AA33 [get_ports qsfp0_mgt_refclk_0_p]

# ERNIC: its AXI (200 MHz) and AXI4-Lite (100 MHz) clocks come from the same MMCM and are
# treated as synchronous inside the core; the interconnect crosses to the DDR4 ui_clk itself.
# status bits (DDR4 calibrated, MMCM locked, ERNIC interrupt) re-timed into the CMAC clock for
# the VIO: only the first synchronizer stage is cut
set_false_path -to [get_cells -hier -filter {NAME =~ *status_cdc_sr_reg[0]*}]
