#!/bin/bash
# Bring-up without sudo: small buffers (within the memlock limit), ERNIC configured over JTAG,
# traffic counters and the ERNIC state printed while the host retries.
R=/home/yijie/fpga/rfsoc4x2_ernic
P=$R/build/dbg_params.txt
source /tools/Xilinx/Vivado/2023.2/settings64.sh >/dev/null 2>&1
cd $R
rm -f $P $P.ready
timeout 60 stdbuf -oL host/rdma_loopback --size ${SIZE_MB:-2} --iters ${ITERS:-1} --chunk ${CHUNK_KB:-64} --params $P &
HP=$!
for i in $(seq 1 50); do [ -f $P ] && break; sleep 0.1; done
vivado -mode batch -nojournal -nolog -source tests/ernic_config.tcl -tclargs $P 2>&1 | grep -E "^AXI|^host:|^  |^ERNIC|ERROR"
wait $HP
echo "host exit $?"
