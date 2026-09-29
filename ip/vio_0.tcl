# Per-second counters at the CMAC: in0 RX frames, in1 RoCE v2 frames to ERNIC, in2 other frames
# (dropped), in3 RX frames with a bad FCS, in4 TX frames, in5 RoCE RX bytes, in6 TX bytes (40 bit),
# in7 {rnic_intr, MMCM locked, DDR4 calibrated}, in8 RoCE frames dropped before ERNIC (FIFO full)
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {9} CONFIG.C_NUM_PROBE_OUT {0} \
    CONFIG.C_PROBE_IN0_WIDTH {32} CONFIG.C_PROBE_IN1_WIDTH {32} CONFIG.C_PROBE_IN2_WIDTH {32} \
    CONFIG.C_PROBE_IN3_WIDTH {32} CONFIG.C_PROBE_IN4_WIDTH {32} CONFIG.C_PROBE_IN5_WIDTH {40} \
    CONFIG.C_PROBE_IN6_WIDTH {40} CONFIG.C_PROBE_IN7_WIDTH {8} CONFIG.C_PROBE_IN8_WIDTH {32} CONFIG.C_EN_PROBE_IN_ACTIVITY {0} \
] [get_ips vio_0]

# Echo engine (clk_200): in0 {RQ doorbells, CQ doorbells, SQ PI accepted, RQ CI accepted} (16 bit
# each, free-running), in1 doorbells for other QPs, in2/in3 last RQ / CQ doorbell {addr, value};
# out0 resets the engine
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_1
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {4} CONFIG.C_NUM_PROBE_OUT {1} \
    CONFIG.C_PROBE_IN0_WIDTH {64} CONFIG.C_PROBE_IN1_WIDTH {16} CONFIG.C_PROBE_IN2_WIDTH {32} \
    CONFIG.C_PROBE_IN3_WIDTH {32} CONFIG.C_EN_PROBE_IN_ACTIVITY {0} \
] [get_ips vio_1]
