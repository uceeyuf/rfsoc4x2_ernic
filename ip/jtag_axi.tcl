# JTAG-to-AXI masters driven from Vivado Tcl: AXI4-Lite into the ERNIC registers (100 MHz),
# AXI4 into PL DDR4 (through the interconnect) to set up and inspect queues and buffers.
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_lite
set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_AXI_ADDR_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {32}] [get_ips jtag_axi_lite]
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_mem
set_property -dict [list CONFIG.PROTOCOL {0} CONFIG.M_AXI_ADDR_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {32} CONFIG.M_AXI_ID_WIDTH {1}] [get_ips jtag_axi_mem]
