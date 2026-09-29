#!/bin/bash
# ERNIC memory loopback bring-up: host network setup, host program, FPGA configuration over JTAG.
R=/home/yijie/fpga/rfsoc4x2_ernic
IF=enp2s0np0
P=$R/host/rdma_host_params.txt
source /tools/Xilinx/Vivado/2023.2/settings64.sh >/dev/null 2>&1
cd $R
sudo -v || exit 1
sudo ethtool -s $IF speed 100000 autoneg off
sudo ethtool --set-fec $IF encoding rs
ip -4 addr show dev $IF | grep -q "192.168.100.2/24" || sudo ip addr add 192.168.100.2/24 dev $IF
sudo ip link set $IF up mtu 9000
sleep 2
# the FPGA answers ARP for 192.168.100.1 (arp_responder): resolve it once
sudo ip neigh del 192.168.100.1 dev $IF 2>/dev/null
ping -c 1 -W 1 192.168.100.1 > /dev/null
ip neigh show 192.168.100.1
rdma link show | head -2
rm -f $P $P.ready
sudo host/rdma_loopback --size ${SIZE_MB:-64} --iters 3 --params $P &
HP=$!
for i in $(seq 1 50); do [ -f $P ] && break; sleep 0.2; done
cat $P
vivado -mode batch -nojournal -nolog -source tests/ernic_config.tcl -tclargs $P ${PROGRAM:-0} 2>&1 | grep -E "^AXI|^host:|^  |^ERNIC|ERROR"
wait $HP
echo "exit $?"
vivado -mode batch -nojournal -nolog -source tests/ernic_config.tcl -tclargs status 2>&1 | grep -E "^  |ERROR"
echo ERNIC_RUN_DONE
