# 100GbE CMAC on the RFSoC 4x2 QSFP28 cage: CAUI-4 (4x25G), RS-FEC, AXI4-Stream user interface.
create_ip -name cmac_usplus -vendor xilinx.com -library ip -module_name cmac_usplus_0
set_property -dict [list \
    CONFIG.CMAC_CAUI4_MODE {1} \
    CONFIG.NUM_LANES {4x25} \
    CONFIG.GT_REF_CLK_FREQ {156.25} \
    CONFIG.GT_DRP_CLK {125} \
    CONFIG.USER_INTERFACE {AXIS} \
    CONFIG.INCLUDE_RS_FEC {1} \
    CONFIG.TX_FLOW_CONTROL {0} \
    CONFIG.RX_FLOW_CONTROL {0} \
    CONFIG.INCLUDE_AUTO_NEG_LT_LOGIC {0} \
    CONFIG.CMAC_CORE_SELECT {CMACE4_X0Y0} \
    CONFIG.GT_GROUP_SELECT {X0Y4~X0Y7} \
] [get_ips cmac_usplus_0]
