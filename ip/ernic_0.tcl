# ERNIC (RoCE v2 RDMA NIC, evaluation license): 8 queue pairs (QP1 for CM, QP2.. for RC),
# 32-bit AXI addresses into PL DDR4, 200 MHz AXI clock.
create_ip -name ernic -vendor xilinx.com -library ip -version 4.0 -module_name ernic_0
set_property -dict [list \
    CONFIG.C_NUM_QP {8} \
    CONFIG.C_M_AXI_ADDR_WIDTH {32} \
    CONFIG.C_ADDR_WIDTH {32} \
    CONFIG.M_AXI_ACLK.FREQ_HZ {200000000} \
    CONFIG.S_AXI_LITE_ACLK.FREQ_HZ {100000000} \
] [get_ips ernic_0]
