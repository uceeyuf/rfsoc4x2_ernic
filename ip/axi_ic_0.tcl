# ERNIC's five AXI4 masters (200 MHz) and a JTAG-to-AXI master -> PL DDR4 (MIG, DDR4-2400, ui_clk 300 MHz).
# Interconnect runs on ui_clk; each ERNIC port crosses clocks and has a 512-entry packet FIFO.
create_ip -name axi_interconnect -vendor xilinx.com -library ip -version 1.7 -module_name axi_ic_0
set cfg [list CONFIG.NUM_SLAVE_PORTS {6} CONFIG.AXI_ADDR_WIDTH {32} CONFIG.INTERCONNECT_DATA_WIDTH {512} \
    CONFIG.THREAD_ID_WIDTH {1} CONFIG.M00_AXI_DATA_WIDTH {512} CONFIG.M00_AXI_IS_ACLK_ASYNC {0} \
    CONFIG.M00_AXI_READ_ISSUING {32} CONFIG.M00_AXI_WRITE_ISSUING {32} \
    CONFIG.M00_AXI_READ_FIFO_DEPTH {512} CONFIG.M00_AXI_WRITE_FIFO_DEPTH {512}]
foreach s {S00 S01 S02 S03 S04} {
    lappend cfg CONFIG.${s}_AXI_DATA_WIDTH {512} CONFIG.${s}_AXI_IS_ACLK_ASYNC {1} \
        CONFIG.${s}_AXI_READ_ACCEPTANCE {16} CONFIG.${s}_AXI_WRITE_ACCEPTANCE {16} \
        CONFIG.${s}_AXI_READ_FIFO_DEPTH {512} CONFIG.${s}_AXI_WRITE_FIFO_DEPTH {512}
}
lappend cfg CONFIG.S05_AXI_DATA_WIDTH {32} CONFIG.S05_AXI_IS_ACLK_ASYNC {1}
set_property -dict $cfg [get_ips axi_ic_0]
