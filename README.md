![语言](https://img.shields.io/badge/语言-verilog_(IEEE1364_2001)-9A90FD.svg) ![RDMA](https://img.shields.io/badge/RDMA-RoCE_v2_(ERNIC)-orange.svg) ![部署](https://img.shields.io/badge/部署-vivado_2023.2-FF1010.svg) ![板卡](https://img.shields.io/badge/板卡-RFSoC_4x2-blue.svg) ![主机](https://img.shields.io/badge/主机-Linux_rdma--core-green.svg)

[English](#en) | [中文](#cn)

　

<span id="en">RFSoC 4x2 100G RDMA with ERNIC</span>
===========================

RoCE v2 on the RFSoC 4x2 (XCZU48DR-FFVG1517-2-E) QSFP28 port with the AMD ERNIC v4.0 IP, PL only. A Linux host with a Mellanox ConnectX-4 connects an RC queue pair to the FPGA and RDMA WRITEs into, and RDMA READs from, a memory region in the PL DDR4: **256 MB WRITE at 97.98 Gbit/s and READ at 98.02 Gbit/s, byte-exact, the RDMA line rate of 100GbE at a 4096-byte path MTU.** The fabric also echoes RDMA SENDs by itself: **every 4 KB message the host SENDs is sent back by ERNIC under the control of a small doorbell engine, no CPU involved, at 87.9 Gbit/s each way with the receive buffers in on-chip URAM (46.5 Gbit/s with them in PL DDR4), byte-exact.**

Phase 2 of three: memory loopback (`v0.1-memory-loopback`) and hardware SEND echo (`v0.2-hw-send-echo`, receive buffers on chip in `v0.3-onchip-echo`); next an RF data path.

　

| ![arch](./docs/img/arch_ernic.svg) |
| :--------------------------------: |
| **Figure1** : data path            |

　

## Technical Features

* **ERNIC v4.0** at 512 bit × 200 MHz with 8 queue pairs; the CMAC side at 322 MHz. RoCE v2 frames (UDP 4791) are filtered from the CMAC receive stream and cross to ERNIC's clock through an asynchronous frame FIFO; ERNIC transmits on the CMAC clock through a store-and-forward frame FIFO.
* **PL DDR4** (MIG, 4 GB, 512 bit × 250 MHz) behind a 6 → 1 AXI interconnect holds the queues, doorbells, error buffers and a 256 MB memory region (R_Key 0x12, VA 0x1000_0000).
* **Hardware SEND echo** (`rtl/send_echo.v`): QP 2 uses ERNIC's doorbell handshake ports. Its send queue holds 64 SEND WQEs written once at configuration, WQE *k* sending receive buffer *k*. The engine only forwards doorbells: a message arriving in buffer *k* (RQ producer index) posts WQE *k* (SQ producer index), and the completion of WQE *k* frees buffer *k* (RQ consumer index).
* **On-chip receive buffers** (`rtl/echo_mem.v`): the 64 × 4 KB buffers sit in URAM at ERNIC address `0x8000_0000`. A zero-latency address split (`rtl/axi_split2.v`) on ERNIC's receive writer and WQE processor sends that range to `echo_mem` and everything else to DDR4, so an echoed message is written and read on chip.
* **ARP responder** in the fabric: the host resolves the ERNIC address like any other neighbour.
* **No processor**: ERNIC registers and DDR4 are programmed over JTAG (JTAG-to-AXI); the host QP is connected by hand (no connection manager) with `tests/ernic_config.tcl`, which also dumps ERNIC's counters and its error buffer.

　

## Performance Test Results

Host: Core Ultra 7 265K, Mellanox ConnectX-4 (PCIe 3.0 x16), Ubuntu 24.04, rdma-core 50, IOMMU on. `host/rdma_loopback`: one RC QP, 1 MB RDMA operations, 32 in flight, 256 MB per direction, data compared word by word after every READ.

| Run | RDMA WRITE (host → FPGA DDR4) | RDMA READ (FPGA DDR4 → host) | Compare |
| :-: | :---------------------------: | :--------------------------: | :-----: |
| 1 | 97.96 Gbit/s | 98.02 Gbit/s | identical |
| 2 | 97.99 Gbit/s | 98.01 Gbit/s | identical |
| 3 | 97.97 Gbit/s | 98.02 Gbit/s | identical |
| 4 | 97.97 Gbit/s | 98.02 Gbit/s | identical |
| 5 | 98.00 Gbit/s | 98.02 Gbit/s | identical |

With a 4096-byte path MTU every packet carries 82 bytes of Ethernet/IPv4/UDP/BTH/ICRC/FCS headers, preamble and gap, so the RDMA payload limit of 100GbE is 4096 / 4178 = **98.04 Gbit/s**; measured 97.96–98.02 Gbit/s. No packet was dropped by the host NIC, no retransmission. Raw data: [docs/results](./docs/results).

### Hardware SEND echo

`host/rdma_loopback --mode echo`: 4096-byte SENDs, at most *window* messages not yet echoed, the echoes received in order into a second buffer and compared; 65,536 messages (256 MB) per run, 3 runs each, 64 receive buffers.

| Window | Buffers on chip (each way) | Buffers in PL DDR4 (each way) | Time per message (on chip) |
| :----: | :------------------------: | :---------------------------: | :------------------------: |
| 1 | 6.28 Gbit/s | | 5.22 µs (round trip) |
| 12 | 52.6–52.7 Gbit/s | 46.0–46.1 Gbit/s | 0.62 µs |
| 24 | 77.8–78.0 Gbit/s | | 0.42 µs |
| 32 | 84.7–85.1 Gbit/s | 46.7–46.8 Gbit/s | 0.39 µs |
| 48 | **87.6–87.9 Gbit/s** | | 0.37 µs |

All echoes identical, ERNIC error buffer empty, no host NIC drops. 2048-byte messages at window 48: 73.1–73.2 Gbit/s (0.22 µs per message). Raw data: [docs/results](./docs/results).

With the buffers in PL DDR4 every message is written to DDR4 and read back, and the echo stops at 46–47 Gbit/s each way whatever the window: 93 Gbit/s of mixed traffic, the practical limit of the 64-bit DDR4-2000 interface. On chip it rises to 88 Gbit/s. The remaining gap to 98 is not the FPGA memory path: cutting `echo_mem`'s read latency to one cycle changed nothing. Running RDMA WRITE and READ at the same time (`--mode bidir`, same host load as the echo) makes the host NIC drop packets (`rx_discards_phy`), so receiving and sending at full rate at once on the host (ConnectX-4, PCIe 3.0 x16) is the likely limit.

Timing met: WNS +0.223 ns, WHS +0.010 ns. Resources: 70,035 LUT (16.5 %), 97,638 FF, 248.5 BRAM, 28 URAM.

　

## ERNIC v4.0 Integration Notes

Found on hardware; each one alone keeps every packet from being accepted.

| | |
| :-- | :-- |
| RX clock | `roce_cmac_s_axis` is sampled on ERNIC's AXI clock (200 MHz), not on `cmac_rx_clk`: the CMAC stream needs an asynchronous FIFO (here store-and-forward, so frames reach ERNIC without gaps; 512 bit × 200 MHz drains faster than 100G). |
| RX `tuser` | `roce_cmac_s_axis_tuser` = 1 on the last beat means the frame is good (the example design drives it with `tlast`); 0 gives FCS errors on every packet. |
| QP registers | QP *i* is at `0x18_0000 + i × 0x100` (QP1 at `0x18_0100`, QP2 at `0x18_0200`). |
| Enabled QPs | `XRNIC_CONF_QP_EN` (`0x10_0044`) = highest QP number (7 for 8 QPs), written before the QPs are configured; `XRNICCONF[23:8]` is the UDP source port. |
| Addresses | MAC: `MSB` register = bytes 0–1, `LSB` = bytes 2–5 (`02:00:00:00:00:01` → `0x0200`, `0x00000001`); IPv4 as a number (`192.168.100.1` → `0xC0A86401`); R_Key = MR index << 8 \| 8-bit key. |
| Debug | Rejected packets go to the error buffer in DDR (syndrome word + header) although `ERRBUFWPTR` stays 0; counters at `0x10_0100`–`0x10_0138` (`0x118` invalid, `0x130` dropped). |
| Host READ path | With the IOMMU on, READ responses at line rate into 4 KB pages were dropped by the host NIC (`rx_discards_phy`, READ 26–76 Gbit/s with retransmissions); buffers on 2 MB transparent huge pages reach 98 Gbit/s with no drop. |

For the doorbell handshake ports (QPCONF*i*[4] = 0), also found on hardware:

| | |
| :-- | :-- |
| Doorbell address | `rx_pkt_hndler_o_rq_db_addr` / `resp_hndler_o_send_cq_db_addr` carry the low 13 bits of the QP's `RQWPTRDBADD` / `CQDBADD` register, not a QP index; `tests/ernic_config.tcl` sets both to end in `0x004`. |
| Doorbell values | The RQ doorbell carries the producer index (cumulative); the CQ doorbell carries the number of new completions (1 per doorbell), so the RQ consumer index has to be accumulated. The SQ PI / RQ CI handshake inputs take 1..depth and the register addresses `0x5018_0038 + QP × 0x100` / `0x501C_0034 + QP × 0x100`, as in the example design. |
| RNR timer | A SEND that finds the receive queue full gets an RNR NAK with the QP's RNR timer (`TIMEOUT`[20:16], IB encoding): `0x1F` = 491 ms stalls the echo; `1` = 10 µs recovers. |
| Recovery | A QP that stalled keeps internal state that reconfiguring over AXI-Lite does not clear; reload the bitstream. |
| WQE fetch | ERNIC fetches WQEs through another AXI master than `wqe_proc_top`, which reads the message data; with the split only on the data masters, the WQEs stay in DDR4 (one 64-byte read per message). |
| Window | A receive buffer is freed only when the host's acknowledgement of its echo reaches ERNIC, and the host NIC coalesces acknowledgements, so more buffers are in use than messages in the window: with 64 buffers, window 48 is safe; 1 KB messages at window 60 fill the queue (RNR NAK, then PSN sequence NAKs). |

　

## Build and Run

Vivado 2023.2 with licenses for the CMAC and ERNIC (an ERNIC hardware evaluation license works; evaluation IP stops after some hours in hardware):

```
git clone --recursive https://github.com/uceeyuf/rfsoc4x2_ernic.git
cd rfsoc4x2_ernic
vivado -mode batch -source scripts/build.tcl -tclargs 12                     # build/ernic.bit, build/ernic.ltx
vivado -mode batch -source tests/ernic_config.tcl -tclargs status 1           # program over JTAG, dump ERNIC
```

Host (Linux, rdma-core / libibverbs; ConnectX-4 at 100G without auto-negotiation, RS-FEC):

```
sudo ethtool -s enp2s0np0 speed 100000 autoneg off
sudo ethtool --set-fec enp2s0np0 encoding rs
sudo ip addr add 192.168.100.2/24 dev enp2s0np0
sudo ip link set enp2s0np0 up mtu 9000
host/build.sh
ITERS=5 SIZE_MB=256 CHUNK_KB=1024 tests/debug_loopback.sh                    # RDMA WRITE / READ / compare
MODE=echo ITERS=3 SIZE_MB=256 WINDOW=48 tests/debug_loopback.sh              # hardware SEND echo (ECHO_MEM=ddr: buffers in DDR4)
```

`tests/debug_loopback.sh` starts `host/rdma_loopback` (it creates the QP and writes its QP number, MAC and PSN to a file), configures ERNIC with them over JTAG, prints the per-second frame counters (and in echo mode the doorbell counters of `send_echo`), ERNIC's state and error buffer, and the host results. The FPGA is `02:00:00:00:00:01` / `192.168.100.1`, QP 2.

　

## License

The files of this design are BSD 3-Clause, Copyright (c) 2026, Yijie Yu. ERNIC, CMAC, MIG and the other AMD IP are generated from their configuration scripts and are not included; they need their own licenses. verilog-ethernet (submodule, `274831c`) is MIT.

　

　

<span id="cn">基于 ERNIC 的 RFSoC 4x2 100G RDMA</span>
===========================

在 RFSoC 4x2（XCZU48DR-FFVG1517-2-E）QSFP28 口上用 AMD ERNIC v4.0 IP 实现 RoCE v2，纯 PL 设计。Linux 主机（Mellanox ConnectX-4）与 FPGA 建立 RC 队列对，对 PL DDR4 中的内存区域做 RDMA WRITE 和 RDMA READ：**256 MB 写 97.98 Gbit/s、读 98.02 Gbit/s，逐字节一致，即 4096 字节路径 MTU 下 100GbE 的 RDMA 线速。** 逻辑还能自行回发 RDMA SEND：**主机 SEND 的每条 4 KB 消息都由一个小的门铃引擎控制 ERNIC 发回，不经过 CPU；接收缓冲放在片上 URAM 时每方向 87.9 Gbit/s（放在 PL DDR4 时 46.5 Gbit/s），逐字节一致。**

三个阶段中的第二阶段：内存回环（`v0.1-memory-loopback`）和硬件 SEND 回环（`v0.2-hw-send-echo`，`v0.3-onchip-echo` 起接收缓冲放在片上）；之后是射频数据通路。

　

| ![arch](./docs/img/arch_ernic.svg) |
| :--------------------------------: |
| **图1** : 数据通路                  |

　

## 技术特点

* **ERNIC v4.0**，512 bit × 200 MHz，8 个队列对；CMAC 一侧 322 MHz。RoCE v2 帧（UDP 4791）从 CMAC 接收流中过滤出来，经异步帧 FIFO 跨到 ERNIC 时钟；ERNIC 在 CMAC 时钟上发送，经存储转发帧 FIFO 送入 CMAC。
* **PL DDR4**（MIG，4 GB，512 bit × 250 MHz）经 6 → 1 AXI 互联，存放队列、门铃、错误缓冲和 256 MB 内存区域（R_Key 0x12，VA 0x1000_0000）。
* **硬件 SEND 回环**（`rtl/send_echo.v`）：QP 2 使用 ERNIC 的门铃握手端口。其发送队列在配置时一次性写入 64 个 SEND WQE，WQE *k* 发送接收缓冲 *k*。引擎只转发门铃：消息到达缓冲 *k*（RQ 生产者指针）即提交 WQE *k*（SQ 生产者指针），WQE *k* 完成后释放缓冲 *k*（RQ 消费者指针）。
* **片上接收缓冲**（`rtl/echo_mem.v`）：64 × 4 KB 缓冲放在 URAM 中，ERNIC 地址 `0x8000_0000`。ERNIC 的接收写入口和 WQE 处理口各接一个零延迟地址分流（`rtl/axi_split2.v`），这一地址段送往 `echo_mem`，其余送往 DDR4，回环的消息在片上写入和读出。
* **ARP 应答**在逻辑中实现：主机像解析其他邻居一样解析 ERNIC 的地址。
* **无处理器**：ERNIC 寄存器和 DDR4 通过 JTAG（JTAG-to-AXI）配置；主机 QP 手动连接（不用连接管理器），由 `tests/ernic_config.tcl` 完成，并可读出 ERNIC 的计数器和错误缓冲。

　

## 性能测试结果

主机：Core Ultra 7 265K，Mellanox ConnectX-4（PCIe 3.0 x16），Ubuntu 24.04，rdma-core 50，IOMMU 开启。`host/rdma_loopback`：一个 RC QP，每次 RDMA 操作 1 MB，同时 32 个在途，每个方向 256 MB，每次 READ 后逐字比较数据。

| 次 | RDMA WRITE（主机 → FPGA DDR4） | RDMA READ（FPGA DDR4 → 主机） | 比较 |
| :-: | :---------------------------: | :--------------------------: | :--: |
| 1 | 97.96 Gbit/s | 98.02 Gbit/s | 一致 |
| 2 | 97.99 Gbit/s | 98.01 Gbit/s | 一致 |
| 3 | 97.97 Gbit/s | 98.02 Gbit/s | 一致 |
| 4 | 97.97 Gbit/s | 98.02 Gbit/s | 一致 |
| 5 | 98.00 Gbit/s | 98.02 Gbit/s | 一致 |

4096 字节路径 MTU 下每个包另有 82 字节的 Ethernet/IPv4/UDP/BTH/ICRC/FCS 头、前导码和帧间隙，100GbE 的 RDMA 负载上限为 4096 / 4178 = **98.04 Gbit/s**；实测 97.96–98.02 Gbit/s。主机网卡没有丢包，没有重传。原始数据：[docs/results](./docs/results)。

### 硬件 SEND 回环

`host/rdma_loopback --mode echo`：4096 字节的 SEND，最多 *window* 条消息尚未回来，回来的消息按顺序收到另一块缓冲中逐字比较；每次 65,536 条消息（256 MB），每种设置 3 次，64 个接收缓冲。

| Window | 缓冲在片上（每方向） | 缓冲在 PL DDR4（每方向） | 每条消息耗时（片上） |
| :----: | :-----------------: | :---------------------: | :-----------------: |
| 1 | 6.28 Gbit/s | | 5.22 µs（往返） |
| 12 | 52.6–52.7 Gbit/s | 46.0–46.1 Gbit/s | 0.62 µs |
| 24 | 77.8–78.0 Gbit/s | | 0.42 µs |
| 32 | 84.7–85.1 Gbit/s | 46.7–46.8 Gbit/s | 0.39 µs |
| 48 | **87.6–87.9 Gbit/s** | | 0.37 µs |

所有回发消息一致，ERNIC 错误缓冲为空，主机网卡无丢包。2048 字节消息、window 48：73.1–73.2 Gbit/s（每条 0.22 µs）。原始数据：[docs/results](./docs/results)。

缓冲在 PL DDR4 时每条消息都要写入 DDR4 再读出，无论 window 多大，回环都停在每方向 46–47 Gbit/s：即 93 Gbit/s 的读写混合流量，是 64 位 DDR4-2000 接口的实际上限。放到片上后升到 88 Gbit/s。离 98 的差距不在 FPGA 存储通路：把 `echo_mem` 的读延迟降到一个周期没有任何变化。同时做 RDMA WRITE 和 READ（`--mode bidir`，主机负载与回环相同）时主机网卡会丢包（`rx_discards_phy`），所以主机（ConnectX-4，PCIe 3.0 x16）同时满速收发很可能是剩下的瓶颈。

时序收敛：WNS +0.223 ns，WHS +0.010 ns。资源：70,035 LUT（16.5 %），97,638 FF，248.5 BRAM，28 URAM。

　

## ERNIC v4.0 集成要点

均在硬件上确认；任何一条不满足，所有包都不会被接收。

| | |
| :-- | :-- |
| 接收时钟 | `roce_cmac_s_axis` 在 ERNIC 的 AXI 时钟（200 MHz）上采样，而不是 `cmac_rx_clk`：CMAC 数据流需要经过异步 FIFO（此处为存储转发，帧无间隙地进入 ERNIC；512 bit × 200 MHz 快于 100G）。 |
| 接收 `tuser` | `roce_cmac_s_axis_tuser` 在最后一拍为 1 表示帧正确（官方例程用 `tlast` 驱动）；置 0 会使每个包都报 FCS 错误。 |
| QP 寄存器 | QP *i* 位于 `0x18_0000 + i × 0x100`（QP1 在 `0x18_0100`，QP2 在 `0x18_0200`）。 |
| 使能的 QP | `XRNIC_CONF_QP_EN`（`0x10_0044`）= 最大 QP 号（8 个 QP 写 7），须在配置 QP 之前写入；`XRNICCONF[23:8]` 是 UDP 源端口。 |
| 地址格式 | MAC：`MSB` 寄存器 = 第 0–1 字节，`LSB` = 第 2–5 字节（`02:00:00:00:00:01` → `0x0200`、`0x00000001`）；IPv4 按数值写（`192.168.100.1` → `0xC0A86401`）；R_Key = MR 序号 << 8 \| 8 位 key。 |
| 调试 | 被拒绝的包写入 DDR 中的错误缓冲（错误码 + 包头），但 `ERRBUFWPTR` 保持为 0；计数器在 `0x10_0100`–`0x10_0138`（`0x118` 无效包，`0x130` 丢弃）。 |
| 主机 READ 路径 | IOMMU 开启时，线速 READ 响应写入 4 KB 页会被主机网卡丢弃（`rx_discards_phy`，READ 只有 26–76 Gbit/s 并伴随重传）；缓冲改用 2 MB 透明大页后达到 98 Gbit/s 且无丢包。 |

门铃握手端口（QPCONF*i*[4] = 0）同样在硬件上确认：

| | |
| :-- | :-- |
| 门铃地址 | `rx_pkt_hndler_o_rq_db_addr` / `resp_hndler_o_send_cq_db_addr` 给出的是该 QP 的 `RQWPTRDBADD` / `CQDBADD` 寄存器的低 13 位，而不是 QP 序号；`tests/ernic_config.tcl` 把两者都设成以 `0x004` 结尾。 |
| 门铃数值 | RQ 门铃给出生产者指针（累计值）；CQ 门铃给出新完成的个数（每次 1），所以 RQ 消费者指针需要自己累加。SQ PI / RQ CI 握手输入取值 1..深度，寄存器地址为 `0x5018_0038 + QP × 0x100` / `0x501C_0034 + QP × 0x100`，与官方例程相同。 |
| RNR 定时器 | 接收队列满时 SEND 会收到 RNR NAK，等待时间取该 QP 的 RNR 定时器（`TIMEOUT`[20:16]，IB 编码）：`0x1F` = 491 ms 会让回环停顿；`1` = 10 µs 可以恢复。 |
| 恢复 | 停顿过的 QP 会残留内部状态，经 AXI-Lite 重新配置清除不了；需要重新下载 bitstream。 |
| WQE 读取 | ERNIC 通过 `wqe_proc_top` 以外的另一个 AXI 主口读取 WQE，`wqe_proc_top` 读取消息数据；地址分流只接在数据主口上，WQE 仍放在 DDR4（每条消息一次 64 字节读）。 |
| Window | 接收缓冲要等主机对回发消息的确认到达 ERNIC 才释放，而主机网卡会合并确认，所以占用的缓冲比 window 中的消息多：64 个缓冲时 window 48 是安全的；1 KB 消息、window 60 会把队列占满（RNR NAK，随后是 PSN 序号 NAK）。 |

　

## 编译与运行

Vivado 2023.2，需要 CMAC 和 ERNIC 的许可证（ERNIC 硬件评估许可证可用；评估版 IP 在硬件上运行若干小时后会停止工作）：

```
git clone --recursive https://github.com/uceeyuf/rfsoc4x2_ernic.git
cd rfsoc4x2_ernic
vivado -mode batch -source scripts/build.tcl -tclargs 12                     # build/ernic.bit、build/ernic.ltx
vivado -mode batch -source tests/ernic_config.tcl -tclargs status 1           # JTAG 下载并读出 ERNIC 状态
```

主机（Linux，rdma-core / libibverbs；ConnectX-4 设为 100G、关闭自协商、RS-FEC）：

```
sudo ethtool -s enp2s0np0 speed 100000 autoneg off
sudo ethtool --set-fec enp2s0np0 encoding rs
sudo ip addr add 192.168.100.2/24 dev enp2s0np0
sudo ip link set enp2s0np0 up mtu 9000
host/build.sh
ITERS=5 SIZE_MB=256 CHUNK_KB=1024 tests/debug_loopback.sh                    # RDMA WRITE / READ / 比较
MODE=echo ITERS=3 SIZE_MB=256 WINDOW=48 tests/debug_loopback.sh              # 硬件 SEND 回环（ECHO_MEM=ddr：缓冲放在 DDR4）
```

`tests/debug_loopback.sh` 启动 `host/rdma_loopback`（创建 QP，并把 QP 号、MAC 和 PSN 写入文件），通过 JTAG 用这些参数配置 ERNIC，打印每秒帧计数（回环模式下还有 `send_echo` 的门铃计数）、ERNIC 状态和错误缓冲，以及主机的测试结果。FPGA 为 `02:00:00:00:00:01` / `192.168.100.1`，QP 2。

　

## 许可证

本设计的文件采用 BSD 3-Clause，版权所有 (c) 2026 Yijie Yu。ERNIC、CMAC、MIG 等 AMD IP 由配置脚本生成，不包含在仓库中，需要各自的许可证。verilog-ethernet（子模块，`274831c`）为 MIT。
