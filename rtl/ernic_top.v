// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// ERNIC (RoCE v2 RDMA NIC) on the RFSoC 4x2 QSFP28 port, PL only:
//
//   CMAC RX -> roce_rx_filter (UDP 4791) -> async frame FIFO (322 -> 200 MHz) -> ERNIC
//   ERNIC + ARP replies (arp_responder) -> TX frame FIFO -> CMAC TX
//   ERNIC AXI4 masters (queues, doorbells, RDMA payload) -> AXI interconnect -> PL DDR4
//
// ERNIC runs at 200 MHz (its AXI clock, 512 bit) with a 100 MHz AXI4-Lite clock from the same
// MMCM; the CMAC side is the 322 MHz CMAC clock. For bring-up the ERNIC registers and the DDR
// are driven from Vivado over JTAG (jtag_axi_lite, jtag_axi_mem); a VIO shows per-second
// frame counters.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module ernic_top (
    input  wire clk_p,                   // 100 MHz
    input  wire clk_n,
    input  wire reset_n,

    output wire qsfp0_tx1_p, qsfp0_tx1_n,
    input  wire qsfp0_rx1_p, qsfp0_rx1_n,
    output wire qsfp0_tx2_p, qsfp0_tx2_n,
    input  wire qsfp0_rx2_p, qsfp0_rx2_n,
    output wire qsfp0_tx3_p, qsfp0_tx3_n,
    input  wire qsfp0_rx3_p, qsfp0_rx3_n,
    output wire qsfp0_tx4_p, qsfp0_tx4_n,
    input  wire qsfp0_rx4_p, qsfp0_rx4_n,
    input  wire qsfp0_mgt_refclk_0_p,
    input  wire qsfp0_mgt_refclk_0_n,
    output wire qsfp0_modsell,
    output wire qsfp0_resetl,
    input  wire qsfp0_modprsl,
    input  wire qsfp0_intl,
    output wire qsfp0_lpmode,

    input  wire         c0_sys_clk_p,
    input  wire         c0_sys_clk_n,
    output wire [16:0]  c0_ddr4_adr,
    output wire [1:0]   c0_ddr4_ba,
    output wire [0:0]   c0_ddr4_cke,
    output wire [0:0]   c0_ddr4_cs_n,
    inout  wire [7:0]   c0_ddr4_dm_dbi_n,
    inout  wire [63:0]  c0_ddr4_dq,
    inout  wire [7:0]   c0_ddr4_dqs_c,
    inout  wire [7:0]   c0_ddr4_dqs_t,
    output wire [0:0]   c0_ddr4_odt,
    output wire [0:0]   c0_ddr4_bg,
    output wire         c0_ddr4_reset_n,
    output wire         c0_ddr4_act_n,
    output wire [0:0]   c0_ddr4_ck_c,
    output wire [0:0]   c0_ddr4_ck_t
);

localparam DW = 512, KW = DW / 8;
localparam MAC_HZ = 322265625;
localparam [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;   // must match tests/ernic_config.tcl
localparam [31:0] LOCAL_IP  = {8'd192, 8'd168, 8'd100, 8'd1};

assign qsfp0_modsell = 1'b1;
assign qsfp0_resetl  = 1'b1;
assign qsfp0_lpmode  = 1'b0;

// ---------------------------------------------------------------- clocks
// 100 MHz -> MMCM (VCO 1000 MHz) -> 200 MHz ERNIC AXI, 100 MHz ERNIC AXI4-Lite (same source,
// aligned edges), 125 MHz CMAC init / DRP
wire clk_in, clk_fb, mmcm_locked;
wire clk_200_mmcm, clk_100_mmcm, clk_125_mmcm, clk_200, clk_100, clk_125;
wire rst_200, rst_100, rst_125;

IBUFDS clk_in_ibufds (.I(clk_p), .IB(clk_n), .O(clk_in));

MMCME4_BASE #(
    .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.0),
    .CLKOUT0_DIVIDE_F(5.0), .CLKOUT1_DIVIDE(10), .CLKOUT2_DIVIDE(8),
    .BANDWIDTH("OPTIMIZED"), .STARTUP_WAIT("FALSE")
)
clk_mmcm (
    .CLKIN1(clk_in), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb), .CLKFBOUTB(),
    .RST(~reset_n), .PWRDWN(1'b0),
    .CLKOUT0(clk_200_mmcm), .CLKOUT0B(), .CLKOUT1(clk_100_mmcm), .CLKOUT1B(),
    .CLKOUT2(clk_125_mmcm), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .LOCKED(mmcm_locked)
);

BUFG clk_200_bufg (.I(clk_200_mmcm), .O(clk_200));
BUFG clk_100_bufg (.I(clk_100_mmcm), .O(clk_100));
BUFG clk_125_bufg (.I(clk_125_mmcm), .O(clk_125));
sync_reset #(.N(4)) rst_200_sync (.clk(clk_200), .rst(~mmcm_locked), .out(rst_200));
sync_reset #(.N(4)) rst_100_sync (.clk(clk_100), .rst(~mmcm_locked), .out(rst_100));
sync_reset #(.N(4)) rst_125_sync (.clk(clk_125), .rst(~mmcm_locked), .out(rst_125));

// ---------------------------------------------------------------- CMAC
wire          mac_clk;                   // gt_txusrclk2, 322.265625 MHz; RX runs on it too
wire          mac_tx_rst, mac_rx_rst, mac_rst;
wire [DW-1:0] mac_tx_tdata, mac_rx_tdata;
wire [KW-1:0] mac_tx_tkeep, mac_rx_tkeep;
wire          mac_tx_tvalid, mac_tx_tready, mac_tx_tlast, mac_tx_tuser;
wire          mac_rx_tvalid, mac_rx_tlast, mac_rx_tuser;

cmac_usplus_0 cmac_inst (
    .gt_rxp_in({qsfp0_rx4_p, qsfp0_rx3_p, qsfp0_rx2_p, qsfp0_rx1_p}),
    .gt_rxn_in({qsfp0_rx4_n, qsfp0_rx3_n, qsfp0_rx2_n, qsfp0_rx1_n}),
    .gt_txp_out({qsfp0_tx4_p, qsfp0_tx3_p, qsfp0_tx2_p, qsfp0_tx1_p}),
    .gt_txn_out({qsfp0_tx4_n, qsfp0_tx3_n, qsfp0_tx2_n, qsfp0_tx1_n}),
    .gt_ref_clk_p(qsfp0_mgt_refclk_0_p), .gt_ref_clk_n(qsfp0_mgt_refclk_0_n),
    .gt_txusrclk2(mac_clk), .gt_loopback_in(12'd0),
    .gtwiz_reset_tx_datapath(1'b0), .gtwiz_reset_rx_datapath(1'b0),
    .sys_reset(rst_125), .init_clk(clk_125),
    .ctl_tx_rsfec_enable(1'b1), .ctl_rx_rsfec_enable(1'b1),
    .ctl_rsfec_ieee_error_indication_mode(1'b0),
    .ctl_rx_rsfec_enable_correction(1'b1), .ctl_rx_rsfec_enable_indication(1'b1),
    .rx_clk(mac_clk), .core_rx_reset(1'b0),
    .ctl_rx_enable(1'b1), .ctl_rx_force_resync(1'b0), .ctl_rx_test_pattern(1'b0),
    .usr_rx_reset(mac_rx_rst),
    .rx_axis_tvalid(mac_rx_tvalid), .rx_axis_tdata(mac_rx_tdata), .rx_axis_tlast(mac_rx_tlast),
    .rx_axis_tkeep(mac_rx_tkeep), .rx_axis_tuser(mac_rx_tuser),
    .core_tx_reset(1'b0),
    .ctl_tx_enable(1'b1), .ctl_tx_send_idle(1'b0), .ctl_tx_send_rfi(1'b0), .ctl_tx_send_lfi(1'b0),
    .ctl_tx_test_pattern(1'b0),
    .usr_tx_reset(mac_tx_rst),
    .tx_axis_tvalid(mac_tx_tvalid), .tx_axis_tready(mac_tx_tready), .tx_axis_tdata(mac_tx_tdata),
    .tx_axis_tlast(mac_tx_tlast), .tx_axis_tkeep(mac_tx_tkeep), .tx_axis_tuser(mac_tx_tuser),
    .tx_preamblein(56'd0),
    .core_drp_reset(1'b0), .drp_clk(1'b0), .drp_addr(10'd0), .drp_di(16'd0), .drp_en(1'b0), .drp_we(1'b0)
);

sync_reset #(.N(4)) rst_mac_sync (.clk(mac_clk), .rst(mac_tx_rst || mac_rx_rst), .out(mac_rst));

// ---------------------------------------------------------------- RX: RoCE v2 frames to ERNIC
wire [DW-1:0] roce_tdata;
wire [KW-1:0] roce_tkeep;
wire          roce_tvalid, roce_tlast, roce_tuser, roce_frame, other_frame;

roce_rx_filter #(.DW(DW)) rx_filter (
    .clk(mac_clk), .rst(mac_rst),
    .s_tdata(mac_rx_tdata), .s_tkeep(mac_rx_tkeep), .s_tvalid(mac_rx_tvalid),
    .s_tlast(mac_rx_tlast), .s_tuser(mac_rx_tuser),
    .m_tdata(roce_tdata), .m_tkeep(roce_tkeep), .m_tvalid(roce_tvalid),
    .m_tlast(roce_tlast), .m_tuser(roce_tuser),
    .roce_frame(roce_frame), .other_frame(other_frame)
);

// ERNIC samples roce_cmac_s_axis on its AXI clock: cross whole frames to 200 MHz (store and
// forward, so a frame reaches ERNIC without gaps; 512 bit x 200 MHz drains faster than 100G)
wire [DW-1:0] rq_tdata;
wire [KW-1:0] rq_tkeep;
wire          rq_tvalid, rq_tlast, rxq_overflow, rxq_bad;

axis_async_fifo #(
    .DEPTH(65536), .DATA_WIDTH(DW), .KEEP_ENABLE(1), .KEEP_WIDTH(KW), .LAST_ENABLE(1),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
    .FRAME_FIFO(1), .USER_BAD_FRAME_VALUE(1'b1), .USER_BAD_FRAME_MASK(1'b1),
    .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(1)
)
roce_fifo (
    .s_clk(mac_clk), .s_rst(mac_rst),
    .s_axis_tdata(roce_tdata), .s_axis_tkeep(roce_tkeep), .s_axis_tvalid(roce_tvalid),
    .s_axis_tready(), .s_axis_tlast(roce_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
    .s_axis_tuser(roce_tuser),
    .m_clk(clk_200), .m_rst(rst_200),
    .m_axis_tdata(rq_tdata), .m_axis_tkeep(rq_tkeep), .m_axis_tvalid(rq_tvalid),
    .m_axis_tready(1'b1), .m_axis_tlast(rq_tlast), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
    .s_status_overflow(rxq_overflow), .s_status_bad_frame(rxq_bad), .s_status_good_frame(),
    .m_status_overflow(), .m_status_bad_frame(), .m_status_good_frame()
);

// ---------------------------------------------------------------- ERNIC
wire qp_mgr_awid;
wire [31:0] qp_mgr_awaddr;
wire [7:0] qp_mgr_awlen;
wire [2:0] qp_mgr_awsize;
wire [1:0] qp_mgr_awburst;
wire qp_mgr_awlock;
wire [3:0] qp_mgr_awcache;
wire [2:0] qp_mgr_awprot;
wire qp_mgr_awvalid;
wire qp_mgr_awready;
wire [511:0] qp_mgr_wdata;
wire [63:0] qp_mgr_wstrb;
wire qp_mgr_wlast;
wire qp_mgr_wvalid;
wire qp_mgr_wready;
wire qp_mgr_bid;
wire [1:0] qp_mgr_bresp;
wire qp_mgr_bvalid;
wire qp_mgr_bready;
wire qp_mgr_arid;
wire [31:0] qp_mgr_araddr;
wire [7:0] qp_mgr_arlen;
wire [2:0] qp_mgr_arsize;
wire [1:0] qp_mgr_arburst;
wire qp_mgr_arlock;
wire [3:0] qp_mgr_arcache;
wire [2:0] qp_mgr_arprot;
wire qp_mgr_arvalid;
wire qp_mgr_arready;
wire qp_mgr_rid;
wire [511:0] qp_mgr_rdata;
wire [1:0] qp_mgr_rresp;
wire qp_mgr_rlast;
wire qp_mgr_rvalid;
wire qp_mgr_rready;
wire wqe_proc_top_awid;
wire [31:0] wqe_proc_top_awaddr;
wire [7:0] wqe_proc_top_awlen;
wire [2:0] wqe_proc_top_awsize;
wire [1:0] wqe_proc_top_awburst;
wire wqe_proc_top_awlock;
wire [3:0] wqe_proc_top_awcache;
wire [2:0] wqe_proc_top_awprot;
wire wqe_proc_top_awvalid;
wire wqe_proc_top_awready;
wire [511:0] wqe_proc_top_wdata;
wire [63:0] wqe_proc_top_wstrb;
wire wqe_proc_top_wlast;
wire wqe_proc_top_wvalid;
wire wqe_proc_top_wready;
wire wqe_proc_top_bid;
wire [1:0] wqe_proc_top_bresp;
wire wqe_proc_top_bvalid;
wire wqe_proc_top_bready;
wire wqe_proc_top_arid;
wire [31:0] wqe_proc_top_araddr;
wire [7:0] wqe_proc_top_arlen;
wire [2:0] wqe_proc_top_arsize;
wire [1:0] wqe_proc_top_arburst;
wire wqe_proc_top_arlock;
wire [3:0] wqe_proc_top_arcache;
wire [2:0] wqe_proc_top_arprot;
wire wqe_proc_top_arvalid;
wire wqe_proc_top_arready;
wire wqe_proc_top_rid;
wire [511:0] wqe_proc_top_rdata;
wire [1:0] wqe_proc_top_rresp;
wire wqe_proc_top_rlast;
wire wqe_proc_top_rvalid;
wire wqe_proc_top_rready;
wire rx_pkt_hndler_ddr_awid;
wire [31:0] rx_pkt_hndler_ddr_awaddr;
wire [7:0] rx_pkt_hndler_ddr_awlen;
wire [2:0] rx_pkt_hndler_ddr_awsize;
wire [1:0] rx_pkt_hndler_ddr_awburst;
wire rx_pkt_hndler_ddr_awlock;
wire [3:0] rx_pkt_hndler_ddr_awcache;
wire [2:0] rx_pkt_hndler_ddr_awprot;
wire rx_pkt_hndler_ddr_awvalid;
wire rx_pkt_hndler_ddr_awready;
wire [511:0] rx_pkt_hndler_ddr_wdata;
wire [63:0] rx_pkt_hndler_ddr_wstrb;
wire rx_pkt_hndler_ddr_wlast;
wire rx_pkt_hndler_ddr_wvalid;
wire rx_pkt_hndler_ddr_wready;
wire rx_pkt_hndler_ddr_bid;
wire [1:0] rx_pkt_hndler_ddr_bresp;
wire rx_pkt_hndler_ddr_bvalid;
wire rx_pkt_hndler_ddr_bready;
wire rx_pkt_hndler_ddr_arid;
wire [31:0] rx_pkt_hndler_ddr_araddr;
wire [7:0] rx_pkt_hndler_ddr_arlen;
wire [2:0] rx_pkt_hndler_ddr_arsize;
wire [1:0] rx_pkt_hndler_ddr_arburst;
wire rx_pkt_hndler_ddr_arlock;
wire [3:0] rx_pkt_hndler_ddr_arcache;
wire [2:0] rx_pkt_hndler_ddr_arprot;
wire rx_pkt_hndler_ddr_arvalid;
wire rx_pkt_hndler_ddr_arready;
wire rx_pkt_hndler_ddr_rid;
wire [511:0] rx_pkt_hndler_ddr_rdata;
wire [1:0] rx_pkt_hndler_ddr_rresp;
wire rx_pkt_hndler_ddr_rlast;
wire rx_pkt_hndler_ddr_rvalid;
wire rx_pkt_hndler_ddr_rready;
wire rx_pkt_hndler_rdrsp_awid;
wire [31:0] rx_pkt_hndler_rdrsp_awaddr;
wire [7:0] rx_pkt_hndler_rdrsp_awlen;
wire [2:0] rx_pkt_hndler_rdrsp_awsize;
wire [1:0] rx_pkt_hndler_rdrsp_awburst;
wire rx_pkt_hndler_rdrsp_awlock;
wire [3:0] rx_pkt_hndler_rdrsp_awcache;
wire [2:0] rx_pkt_hndler_rdrsp_awprot;
wire rx_pkt_hndler_rdrsp_awvalid;
wire rx_pkt_hndler_rdrsp_awready;
wire [511:0] rx_pkt_hndler_rdrsp_wdata;
wire [63:0] rx_pkt_hndler_rdrsp_wstrb;
wire rx_pkt_hndler_rdrsp_wlast;
wire rx_pkt_hndler_rdrsp_wvalid;
wire rx_pkt_hndler_rdrsp_wready;
wire rx_pkt_hndler_rdrsp_bid;
wire [1:0] rx_pkt_hndler_rdrsp_bresp;
wire rx_pkt_hndler_rdrsp_bvalid;
wire rx_pkt_hndler_rdrsp_bready;
wire rx_pkt_hndler_rdrsp_arid;
wire [31:0] rx_pkt_hndler_rdrsp_araddr;
wire [7:0] rx_pkt_hndler_rdrsp_arlen;
wire [2:0] rx_pkt_hndler_rdrsp_arsize;
wire [1:0] rx_pkt_hndler_rdrsp_arburst;
wire rx_pkt_hndler_rdrsp_arlock;
wire [3:0] rx_pkt_hndler_rdrsp_arcache;
wire [2:0] rx_pkt_hndler_rdrsp_arprot;
wire rx_pkt_hndler_rdrsp_arvalid;
wire rx_pkt_hndler_rdrsp_arready;
wire rx_pkt_hndler_rdrsp_rid;
wire [511:0] rx_pkt_hndler_rdrsp_rdata;
wire [1:0] rx_pkt_hndler_rdrsp_rresp;
wire rx_pkt_hndler_rdrsp_rlast;
wire rx_pkt_hndler_rdrsp_rvalid;
wire rx_pkt_hndler_rdrsp_rready;
wire resp_hndler_awid;
wire [31:0] resp_hndler_awaddr;
wire [7:0] resp_hndler_awlen;
wire [2:0] resp_hndler_awsize;
wire [1:0] resp_hndler_awburst;
wire resp_hndler_awlock;
wire [3:0] resp_hndler_awcache;
wire [2:0] resp_hndler_awprot;
wire resp_hndler_awvalid;
wire resp_hndler_awready;
wire [511:0] resp_hndler_wdata;
wire [63:0] resp_hndler_wstrb;
wire resp_hndler_wlast;
wire resp_hndler_wvalid;
wire resp_hndler_wready;
wire resp_hndler_bid;
wire [1:0] resp_hndler_bresp;
wire resp_hndler_bvalid;
wire resp_hndler_bready;
wire resp_hndler_arid;
wire [31:0] resp_hndler_araddr;
wire [7:0] resp_hndler_arlen;
wire [2:0] resp_hndler_arsize;
wire [1:0] resp_hndler_arburst;
wire resp_hndler_arlock;
wire [3:0] resp_hndler_arcache;
wire [2:0] resp_hndler_arprot;
wire resp_hndler_arvalid;
wire resp_hndler_arready;
wire resp_hndler_rid;
wire [511:0] resp_hndler_rdata;
wire [1:0] resp_hndler_rresp;
wire resp_hndler_rlast;
wire resp_hndler_rvalid;
wire resp_hndler_rready;
wire jm_awid;
wire [31:0] jm_awaddr;
wire [7:0] jm_awlen;
wire [2:0] jm_awsize;
wire [1:0] jm_awburst;
wire jm_awlock;
wire [3:0] jm_awcache;
wire [2:0] jm_awprot;
wire jm_awvalid;
wire jm_awready;
wire [31:0] jm_wdata;
wire [3:0] jm_wstrb;
wire jm_wlast;
wire jm_wvalid;
wire jm_wready;
wire jm_bid;
wire [1:0] jm_bresp;
wire jm_bvalid;
wire jm_bready;
wire jm_arid;
wire [31:0] jm_araddr;
wire [7:0] jm_arlen;
wire [2:0] jm_arsize;
wire [1:0] jm_arburst;
wire jm_arlock;
wire [3:0] jm_arcache;
wire [2:0] jm_arprot;
wire jm_arvalid;
wire jm_arready;
wire jm_rid;
wire [31:0] jm_rdata;
wire [1:0] jm_rresp;
wire jm_rlast;
wire jm_rvalid;
wire jm_rready;
wire [3:0] jm_awqos, jm_arqos;
wire [3:0] ddr_awid;
wire [31:0] ddr_awaddr;
wire [7:0] ddr_awlen;
wire [2:0] ddr_awsize;
wire [1:0] ddr_awburst;
wire ddr_awlock;
wire [3:0] ddr_awcache;
wire [2:0] ddr_awprot;
wire [3:0] ddr_awvalid;
wire ddr_awready;
wire [511:0] ddr_wdata;
wire [63:0] ddr_wstrb;
wire ddr_wlast;
wire [3:0] ddr_wvalid;
wire ddr_wready;
wire [3:0] ddr_bid;
wire [1:0] ddr_bresp;
wire [3:0] ddr_bvalid;
wire ddr_bready;
wire [3:0] ddr_arid;
wire [31:0] ddr_araddr;
wire [7:0] ddr_arlen;
wire [2:0] ddr_arsize;
wire [1:0] ddr_arburst;
wire ddr_arlock;
wire [3:0] ddr_arcache;
wire [2:0] ddr_arprot;
wire [3:0] ddr_arvalid;
wire ddr_arready;
wire [3:0] ddr_rid;
wire [511:0] ddr_rdata;
wire [1:0] ddr_rresp;
wire ddr_rlast;
wire [3:0] ddr_rvalid;
wire ddr_rready;
wire [3:0] ddr_awqos, ddr_arqos;

wire [DW-1:0] ern_tx_tdata;
wire [KW-1:0] ern_tx_tkeep;
wire          ern_tx_tvalid, ern_tx_tready, ern_tx_tlast;

wire [31:0] lite_awaddr, lite_araddr, lite_wdata, lite_rdata;
wire [3:0]  lite_wstrb;
wire [2:0]  lite_awprot, lite_arprot;
wire [1:0]  lite_bresp, lite_rresp;
wire        lite_awvalid, lite_awready, lite_wvalid, lite_wready, lite_bvalid, lite_bready;
wire        lite_arvalid, lite_arready, lite_rvalid, lite_rready;
wire        rnic_intr;
wire [31:0] rq_db_data, cq_db_cnt, sq_pidb_addr, rq_cidb_addr;
wire [12:0] rq_db_addr, cq_db_addr;
wire [15:0] sq_pidb, rq_cidb;
wire        rq_db_valid, rq_db_rdy, cq_db_valid, cq_db_rdy;
wire        sq_pidb_valid, sq_pidb_rdy, rq_cidb_valid, rq_cidb_rdy;

ernic_0 ernic_inst (
    .m_axi_aclk(clk_200), .m_axi_aresetn(!rst_200),
    .s_axi_lite_aclk(clk_100), .s_axi_lite_aresetn(!rst_100),
    .system_resetn(),
    .cmac_rx_clk(mac_clk), .cmac_rx_rst(mac_rst), .cmac_tx_clk(mac_clk), .cmac_tx_rst(mac_rst),
    .qp_mgr_m_axi_awid(qp_mgr_awid),
    .qp_mgr_m_axi_awaddr(qp_mgr_awaddr),
    .qp_mgr_m_axi_awlen(qp_mgr_awlen),
    .qp_mgr_m_axi_awsize(qp_mgr_awsize),
    .qp_mgr_m_axi_awburst(qp_mgr_awburst),
    .qp_mgr_m_axi_awlock(qp_mgr_awlock),
    .qp_mgr_m_axi_awcache(qp_mgr_awcache),
    .qp_mgr_m_axi_awprot(qp_mgr_awprot),
    .qp_mgr_m_axi_awvalid(qp_mgr_awvalid),
    .qp_mgr_m_axi_awready(qp_mgr_awready),
    .qp_mgr_m_axi_wdata(qp_mgr_wdata),
    .qp_mgr_m_axi_wstrb(qp_mgr_wstrb),
    .qp_mgr_m_axi_wlast(qp_mgr_wlast),
    .qp_mgr_m_axi_wvalid(qp_mgr_wvalid),
    .qp_mgr_m_axi_wready(qp_mgr_wready),
    .qp_mgr_m_axi_bid(qp_mgr_bid),
    .qp_mgr_m_axi_bresp(qp_mgr_bresp),
    .qp_mgr_m_axi_bvalid(qp_mgr_bvalid),
    .qp_mgr_m_axi_bready(qp_mgr_bready),
    .qp_mgr_m_axi_arid(qp_mgr_arid),
    .qp_mgr_m_axi_araddr(qp_mgr_araddr),
    .qp_mgr_m_axi_arlen(qp_mgr_arlen),
    .qp_mgr_m_axi_arsize(qp_mgr_arsize),
    .qp_mgr_m_axi_arburst(qp_mgr_arburst),
    .qp_mgr_m_axi_arlock(qp_mgr_arlock),
    .qp_mgr_m_axi_arcache(qp_mgr_arcache),
    .qp_mgr_m_axi_arprot(qp_mgr_arprot),
    .qp_mgr_m_axi_arvalid(qp_mgr_arvalid),
    .qp_mgr_m_axi_arready(qp_mgr_arready),
    .qp_mgr_m_axi_rid(qp_mgr_rid),
    .qp_mgr_m_axi_rdata(qp_mgr_rdata),
    .qp_mgr_m_axi_rresp(qp_mgr_rresp),
    .qp_mgr_m_axi_rlast(qp_mgr_rlast),
    .qp_mgr_m_axi_rvalid(qp_mgr_rvalid),
    .qp_mgr_m_axi_rready(qp_mgr_rready),
    .wqe_proc_top_m_axi_awid(wqe_proc_top_awid),
    .wqe_proc_top_m_axi_awaddr(wqe_proc_top_awaddr),
    .wqe_proc_top_m_axi_awlen(wqe_proc_top_awlen),
    .wqe_proc_top_m_axi_awsize(wqe_proc_top_awsize),
    .wqe_proc_top_m_axi_awburst(wqe_proc_top_awburst),
    .wqe_proc_top_m_axi_awlock(wqe_proc_top_awlock),
    .wqe_proc_top_m_axi_awcache(wqe_proc_top_awcache),
    .wqe_proc_top_m_axi_awprot(wqe_proc_top_awprot),
    .wqe_proc_top_m_axi_awvalid(wqe_proc_top_awvalid),
    .wqe_proc_top_m_axi_awready(wqe_proc_top_awready),
    .wqe_proc_top_m_axi_wdata(wqe_proc_top_wdata),
    .wqe_proc_top_m_axi_wstrb(wqe_proc_top_wstrb),
    .wqe_proc_top_m_axi_wlast(wqe_proc_top_wlast),
    .wqe_proc_top_m_axi_wvalid(wqe_proc_top_wvalid),
    .wqe_proc_top_m_axi_wready(wqe_proc_top_wready),
    .wqe_proc_top_m_axi_bid(wqe_proc_top_bid),
    .wqe_proc_top_m_axi_bresp(wqe_proc_top_bresp),
    .wqe_proc_top_m_axi_bvalid(wqe_proc_top_bvalid),
    .wqe_proc_top_m_axi_bready(wqe_proc_top_bready),
    .wqe_proc_top_m_axi_arid(wqe_proc_top_arid),
    .wqe_proc_top_m_axi_araddr(wqe_proc_top_araddr),
    .wqe_proc_top_m_axi_arlen(wqe_proc_top_arlen),
    .wqe_proc_top_m_axi_arsize(wqe_proc_top_arsize),
    .wqe_proc_top_m_axi_arburst(wqe_proc_top_arburst),
    .wqe_proc_top_m_axi_arlock(wqe_proc_top_arlock),
    .wqe_proc_top_m_axi_arcache(wqe_proc_top_arcache),
    .wqe_proc_top_m_axi_arprot(wqe_proc_top_arprot),
    .wqe_proc_top_m_axi_arvalid(wqe_proc_top_arvalid),
    .wqe_proc_top_m_axi_arready(wqe_proc_top_arready),
    .wqe_proc_top_m_axi_rid(wqe_proc_top_rid),
    .wqe_proc_top_m_axi_rdata(wqe_proc_top_rdata),
    .wqe_proc_top_m_axi_rresp(wqe_proc_top_rresp),
    .wqe_proc_top_m_axi_rlast(wqe_proc_top_rlast),
    .wqe_proc_top_m_axi_rvalid(wqe_proc_top_rvalid),
    .wqe_proc_top_m_axi_rready(wqe_proc_top_rready),
    .rx_pkt_hndler_ddr_m_axi_awid(rx_pkt_hndler_ddr_awid),
    .rx_pkt_hndler_ddr_m_axi_awaddr(rx_pkt_hndler_ddr_awaddr),
    .rx_pkt_hndler_ddr_m_axi_awlen(rx_pkt_hndler_ddr_awlen),
    .rx_pkt_hndler_ddr_m_axi_awsize(rx_pkt_hndler_ddr_awsize),
    .rx_pkt_hndler_ddr_m_axi_awburst(rx_pkt_hndler_ddr_awburst),
    .rx_pkt_hndler_ddr_m_axi_awlock(rx_pkt_hndler_ddr_awlock),
    .rx_pkt_hndler_ddr_m_axi_awcache(rx_pkt_hndler_ddr_awcache),
    .rx_pkt_hndler_ddr_m_axi_awprot(rx_pkt_hndler_ddr_awprot),
    .rx_pkt_hndler_ddr_m_axi_awvalid(rx_pkt_hndler_ddr_awvalid),
    .rx_pkt_hndler_ddr_m_axi_awready(rx_pkt_hndler_ddr_awready),
    .rx_pkt_hndler_ddr_m_axi_wdata(rx_pkt_hndler_ddr_wdata),
    .rx_pkt_hndler_ddr_m_axi_wstrb(rx_pkt_hndler_ddr_wstrb),
    .rx_pkt_hndler_ddr_m_axi_wlast(rx_pkt_hndler_ddr_wlast),
    .rx_pkt_hndler_ddr_m_axi_wvalid(rx_pkt_hndler_ddr_wvalid),
    .rx_pkt_hndler_ddr_m_axi_wready(rx_pkt_hndler_ddr_wready),
    .rx_pkt_hndler_ddr_m_axi_bid(rx_pkt_hndler_ddr_bid),
    .rx_pkt_hndler_ddr_m_axi_bresp(rx_pkt_hndler_ddr_bresp),
    .rx_pkt_hndler_ddr_m_axi_bvalid(rx_pkt_hndler_ddr_bvalid),
    .rx_pkt_hndler_ddr_m_axi_bready(rx_pkt_hndler_ddr_bready),
    .rx_pkt_hndler_ddr_m_axi_arid(rx_pkt_hndler_ddr_arid),
    .rx_pkt_hndler_ddr_m_axi_araddr(rx_pkt_hndler_ddr_araddr),
    .rx_pkt_hndler_ddr_m_axi_arlen(rx_pkt_hndler_ddr_arlen),
    .rx_pkt_hndler_ddr_m_axi_arsize(rx_pkt_hndler_ddr_arsize),
    .rx_pkt_hndler_ddr_m_axi_arburst(rx_pkt_hndler_ddr_arburst),
    .rx_pkt_hndler_ddr_m_axi_arlock(rx_pkt_hndler_ddr_arlock),
    .rx_pkt_hndler_ddr_m_axi_arcache(rx_pkt_hndler_ddr_arcache),
    .rx_pkt_hndler_ddr_m_axi_arprot(rx_pkt_hndler_ddr_arprot),
    .rx_pkt_hndler_ddr_m_axi_arvalid(rx_pkt_hndler_ddr_arvalid),
    .rx_pkt_hndler_ddr_m_axi_arready(rx_pkt_hndler_ddr_arready),
    .rx_pkt_hndler_ddr_m_axi_rid(rx_pkt_hndler_ddr_rid),
    .rx_pkt_hndler_ddr_m_axi_rdata(rx_pkt_hndler_ddr_rdata),
    .rx_pkt_hndler_ddr_m_axi_rresp(rx_pkt_hndler_ddr_rresp),
    .rx_pkt_hndler_ddr_m_axi_rlast(rx_pkt_hndler_ddr_rlast),
    .rx_pkt_hndler_ddr_m_axi_rvalid(rx_pkt_hndler_ddr_rvalid),
    .rx_pkt_hndler_ddr_m_axi_rready(rx_pkt_hndler_ddr_rready),
    .rx_pkt_hndler_rdrsp_m_axi_awid(rx_pkt_hndler_rdrsp_awid),
    .rx_pkt_hndler_rdrsp_m_axi_awaddr(rx_pkt_hndler_rdrsp_awaddr),
    .rx_pkt_hndler_rdrsp_m_axi_awlen(rx_pkt_hndler_rdrsp_awlen),
    .rx_pkt_hndler_rdrsp_m_axi_awsize(rx_pkt_hndler_rdrsp_awsize),
    .rx_pkt_hndler_rdrsp_m_axi_awburst(rx_pkt_hndler_rdrsp_awburst),
    .rx_pkt_hndler_rdrsp_m_axi_awlock(rx_pkt_hndler_rdrsp_awlock),
    .rx_pkt_hndler_rdrsp_m_axi_awcache(rx_pkt_hndler_rdrsp_awcache),
    .rx_pkt_hndler_rdrsp_m_axi_awprot(rx_pkt_hndler_rdrsp_awprot),
    .rx_pkt_hndler_rdrsp_m_axi_awvalid(rx_pkt_hndler_rdrsp_awvalid),
    .rx_pkt_hndler_rdrsp_m_axi_awready(rx_pkt_hndler_rdrsp_awready),
    .rx_pkt_hndler_rdrsp_m_axi_wdata(rx_pkt_hndler_rdrsp_wdata),
    .rx_pkt_hndler_rdrsp_m_axi_wstrb(rx_pkt_hndler_rdrsp_wstrb),
    .rx_pkt_hndler_rdrsp_m_axi_wlast(rx_pkt_hndler_rdrsp_wlast),
    .rx_pkt_hndler_rdrsp_m_axi_wvalid(rx_pkt_hndler_rdrsp_wvalid),
    .rx_pkt_hndler_rdrsp_m_axi_wready(rx_pkt_hndler_rdrsp_wready),
    .rx_pkt_hndler_rdrsp_m_axi_bid(rx_pkt_hndler_rdrsp_bid),
    .rx_pkt_hndler_rdrsp_m_axi_bresp(rx_pkt_hndler_rdrsp_bresp),
    .rx_pkt_hndler_rdrsp_m_axi_bvalid(rx_pkt_hndler_rdrsp_bvalid),
    .rx_pkt_hndler_rdrsp_m_axi_bready(rx_pkt_hndler_rdrsp_bready),
    .rx_pkt_hndler_rdrsp_m_axi_arid(rx_pkt_hndler_rdrsp_arid),
    .rx_pkt_hndler_rdrsp_m_axi_araddr(rx_pkt_hndler_rdrsp_araddr),
    .rx_pkt_hndler_rdrsp_m_axi_arlen(rx_pkt_hndler_rdrsp_arlen),
    .rx_pkt_hndler_rdrsp_m_axi_arsize(rx_pkt_hndler_rdrsp_arsize),
    .rx_pkt_hndler_rdrsp_m_axi_arburst(rx_pkt_hndler_rdrsp_arburst),
    .rx_pkt_hndler_rdrsp_m_axi_arlock(rx_pkt_hndler_rdrsp_arlock),
    .rx_pkt_hndler_rdrsp_m_axi_arcache(rx_pkt_hndler_rdrsp_arcache),
    .rx_pkt_hndler_rdrsp_m_axi_arprot(rx_pkt_hndler_rdrsp_arprot),
    .rx_pkt_hndler_rdrsp_m_axi_arvalid(rx_pkt_hndler_rdrsp_arvalid),
    .rx_pkt_hndler_rdrsp_m_axi_arready(rx_pkt_hndler_rdrsp_arready),
    .rx_pkt_hndler_rdrsp_m_axi_rid(rx_pkt_hndler_rdrsp_rid),
    .rx_pkt_hndler_rdrsp_m_axi_rdata(rx_pkt_hndler_rdrsp_rdata),
    .rx_pkt_hndler_rdrsp_m_axi_rresp(rx_pkt_hndler_rdrsp_rresp),
    .rx_pkt_hndler_rdrsp_m_axi_rlast(rx_pkt_hndler_rdrsp_rlast),
    .rx_pkt_hndler_rdrsp_m_axi_rvalid(rx_pkt_hndler_rdrsp_rvalid),
    .rx_pkt_hndler_rdrsp_m_axi_rready(rx_pkt_hndler_rdrsp_rready),
    .resp_hndler_m_axi_awid(resp_hndler_awid),
    .resp_hndler_m_axi_awaddr(resp_hndler_awaddr),
    .resp_hndler_m_axi_awlen(resp_hndler_awlen),
    .resp_hndler_m_axi_awsize(resp_hndler_awsize),
    .resp_hndler_m_axi_awburst(resp_hndler_awburst),
    .resp_hndler_m_axi_awlock(resp_hndler_awlock),
    .resp_hndler_m_axi_awcache(resp_hndler_awcache),
    .resp_hndler_m_axi_awprot(resp_hndler_awprot),
    .resp_hndler_m_axi_awvalid(resp_hndler_awvalid),
    .resp_hndler_m_axi_awready(resp_hndler_awready),
    .resp_hndler_m_axi_wdata(resp_hndler_wdata),
    .resp_hndler_m_axi_wstrb(resp_hndler_wstrb),
    .resp_hndler_m_axi_wlast(resp_hndler_wlast),
    .resp_hndler_m_axi_wvalid(resp_hndler_wvalid),
    .resp_hndler_m_axi_wready(resp_hndler_wready),
    .resp_hndler_m_axi_bid(resp_hndler_bid),
    .resp_hndler_m_axi_bresp(resp_hndler_bresp),
    .resp_hndler_m_axi_bvalid(resp_hndler_bvalid),
    .resp_hndler_m_axi_bready(resp_hndler_bready),
    .resp_hndler_m_axi_arid(resp_hndler_arid),
    .resp_hndler_m_axi_araddr(resp_hndler_araddr),
    .resp_hndler_m_axi_arlen(resp_hndler_arlen),
    .resp_hndler_m_axi_arsize(resp_hndler_arsize),
    .resp_hndler_m_axi_arburst(resp_hndler_arburst),
    .resp_hndler_m_axi_arlock(resp_hndler_arlock),
    .resp_hndler_m_axi_arcache(resp_hndler_arcache),
    .resp_hndler_m_axi_arprot(resp_hndler_arprot),
    .resp_hndler_m_axi_arvalid(resp_hndler_arvalid),
    .resp_hndler_m_axi_arready(resp_hndler_arready),
    .resp_hndler_m_axi_rid(resp_hndler_rid),
    .resp_hndler_m_axi_rdata(resp_hndler_rdata),
    .resp_hndler_m_axi_rresp(resp_hndler_rresp),
    .resp_hndler_m_axi_rlast(resp_hndler_rlast),
    .resp_hndler_m_axi_rvalid(resp_hndler_rvalid),
    .resp_hndler_m_axi_rready(resp_hndler_rready),
    .rx_pkt_hndler_ddr_m_axi_awuser(),
    .roce_cmac_s_axis_tvalid(rq_tvalid), .roce_cmac_s_axis_tdata(rq_tdata),
    .roce_cmac_s_axis_tkeep(rq_tkeep), .roce_cmac_s_axis_tlast(rq_tlast),
    .roce_cmac_s_axis_tuser(rq_tlast),        // ERNIC: 1 on the last beat = frame good (bad ones are dropped above)
    .non_roce_cmac_s_axis_tvalid(1'b0), .non_roce_cmac_s_axis_tdata({DW{1'b0}}),
    .non_roce_cmac_s_axis_tkeep({KW{1'b0}}), .non_roce_cmac_s_axis_tlast(1'b0),
    .non_roce_cmac_s_axis_tuser(1'b0),
    .non_roce_dma_s_axis_tvalid(1'b0), .non_roce_dma_s_axis_tdata({DW{1'b0}}),
    .non_roce_dma_s_axis_tkeep({KW{1'b0}}), .non_roce_dma_s_axis_tlast(1'b0),
    .non_roce_dma_s_axis_tready(),
    .non_roce_dma_m_axis_tdata(), .non_roce_dma_m_axis_tkeep(), .non_roce_dma_m_axis_tvalid(),
    .non_roce_dma_m_axis_tready(1'b1), .non_roce_dma_m_axis_tlast(),
    .cmac_m_axis_tdata(ern_tx_tdata), .cmac_m_axis_tkeep(ern_tx_tkeep), .cmac_m_axis_tvalid(ern_tx_tvalid),
    .cmac_m_axis_tready(ern_tx_tready), .cmac_m_axis_tlast(ern_tx_tlast),
    .s_axi_lite_awaddr(lite_awaddr), .s_axi_lite_awready(lite_awready), .s_axi_lite_awvalid(lite_awvalid),
    .s_axi_lite_araddr(lite_araddr), .s_axi_lite_arready(lite_arready), .s_axi_lite_arvalid(lite_arvalid),
    .s_axi_lite_wdata(lite_wdata), .s_axi_lite_wstrb(lite_wstrb), .s_axi_lite_wready(lite_wready),
    .s_axi_lite_wvalid(lite_wvalid), .s_axi_lite_rdata(lite_rdata), .s_axi_lite_rresp(lite_rresp),
    .s_axi_lite_rready(lite_rready), .s_axi_lite_rvalid(lite_rvalid), .s_axi_lite_bresp(lite_bresp),
    .s_axi_lite_bready(lite_bready), .s_axi_lite_bvalid(lite_bvalid),
    // doorbells go to DDR (QPCONFi[4] = 1): the hardware handshake ports are idle
    // doorbell handshake ports (QPs with QPCONFi[4] = 0) -> send_echo
    .resp_hndler_o_send_cq_db_cnt_valid(cq_db_valid), .resp_hndler_o_send_cq_db_addr(cq_db_addr), .resp_hndler_o_send_cq_db_cnt(cq_db_cnt),
    .resp_hndler_i_send_cq_db_rdy(cq_db_rdy),
    .i_qp_rq_cidb_hndshk(rq_cidb), .i_qp_rq_cidb_wr_addr_hndshk(rq_cidb_addr), .i_qp_rq_cidb_wr_valid_hndshk(rq_cidb_valid),
    .o_qp_rq_cidb_wr_rdy(rq_cidb_rdy),
    .i_qp_sq_pidb_hndshk(sq_pidb), .i_qp_sq_pidb_wr_addr_hndshk(sq_pidb_addr), .i_qp_sq_pidb_wr_valid_hndshk(sq_pidb_valid),
    .o_qp_sq_pidb_wr_rdy(sq_pidb_rdy),
    .rx_pkt_hndler_o_rq_db_data(rq_db_data), .rx_pkt_hndler_o_rq_db_addr(rq_db_addr), .rx_pkt_hndler_o_rq_db_data_valid(rq_db_valid),
    .rx_pkt_hndler_i_rq_db_rdy(rq_db_rdy),
    .rnic_intr(rnic_intr),
    .stat_rx_pause_req(9'd0), .ctl_tx_pause_req(), .ctl_tx_resend_pause(),
    .ieth_immdt_axis_tvalid(), .ieth_immdt_axis_tlast(), .ieth_immdt_axis_tdata(), .ieth_immdt_axis_trdy(1'b1),
    .o_global_dbg_cnt_en(), .o_global_dbg_cnt_clr()
);

// ---------------------------------------------------------------- ARP: answer for the ERNIC address
wire [DW-1:0] arp_tdata;
wire [KW-1:0] arp_tkeep;
wire          arp_tvalid, arp_tready, arp_tlast, arp_reply;

arp_responder #(.DW(DW)) arp_inst (
    .clk(mac_clk), .rst(mac_rst),
    .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP),
    .s_tdata(mac_rx_tdata), .s_tvalid(mac_rx_tvalid), .s_tlast(mac_rx_tlast),
    .m_tdata(arp_tdata), .m_tkeep(arp_tkeep), .m_tvalid(arp_tvalid), .m_tready(arp_tready),
    .m_tlast(arp_tlast), .reply_sent(arp_reply)
);

// ERNIC frames and ARP replies, whole frames each
wire [DW-1:0] txm_tdata;
wire [KW-1:0] txm_tkeep;
wire          txm_tvalid, txm_tready, txm_tlast;

axis_arb_mux #(
    .S_COUNT(2), .DATA_WIDTH(DW), .KEEP_ENABLE(1), .KEEP_WIDTH(KW), .ID_ENABLE(0), .DEST_ENABLE(0),
    .USER_ENABLE(0), .LAST_ENABLE(1), .ARB_TYPE_ROUND_ROBIN(1), .ARB_LSB_HIGH_PRIORITY(1)
)
tx_mux (
    .clk(mac_clk), .rst(mac_rst),
    .s_axis_tdata({arp_tdata, ern_tx_tdata}), .s_axis_tkeep({arp_tkeep, ern_tx_tkeep}),
    .s_axis_tvalid({arp_tvalid, ern_tx_tvalid}), .s_axis_tready({arp_tready, ern_tx_tready}),
    .s_axis_tlast({arp_tlast, ern_tx_tlast}), .s_axis_tid(16'd0), .s_axis_tdest(16'd0), .s_axis_tuser(2'd0),
    .m_axis_tdata(txm_tdata), .m_axis_tkeep(txm_tkeep), .m_axis_tvalid(txm_tvalid), .m_axis_tready(txm_tready),
    .m_axis_tlast(txm_tlast), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser()
);

// ---------------------------------------------------------------- TX: store and forward to the CMAC
wire [DW-1:0] txf_tdata;
wire [KW-1:0] txf_tkeep;
wire          txf_tvalid, txf_tready, txf_tlast, txf_tuser;

axis_fifo #(
    .DEPTH(32768), .DATA_WIDTH(DW), .KEEP_ENABLE(1), .KEEP_WIDTH(KW), .LAST_ENABLE(1),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
    .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(0), .DROP_WHEN_FULL(0)
)
tx_fifo (
    .clk(mac_clk), .rst(mac_rst),
    .s_axis_tdata(txm_tdata), .s_axis_tkeep(txm_tkeep), .s_axis_tvalid(txm_tvalid),
    .s_axis_tready(txm_tready), .s_axis_tlast(txm_tlast), .s_axis_tid(8'd0),
    .s_axis_tdest(8'd0), .s_axis_tuser(1'b0),
    .m_axis_tdata(txf_tdata), .m_axis_tkeep(txf_tkeep), .m_axis_tvalid(txf_tvalid),
    .m_axis_tready(txf_tready), .m_axis_tlast(txf_tlast), .m_axis_tid(), .m_axis_tdest(),
    .m_axis_tuser(txf_tuser),
    .status_overflow(), .status_bad_frame(), .status_good_frame()
);

assign mac_tx_tdata  = txf_tdata;
assign mac_tx_tkeep  = txf_tkeep;
assign mac_tx_tvalid = txf_tvalid;
assign mac_tx_tlast  = txf_tlast;
assign mac_tx_tuser  = 1'b0;
assign txf_tready    = mac_tx_tready;

// ---------------------------------------------------------------- JTAG masters
jtag_axi_lite jtag_lite (
    .aclk(clk_100), .aresetn(!rst_100),
    .m_axi_awaddr(lite_awaddr), .m_axi_awprot(lite_awprot), .m_axi_awvalid(lite_awvalid),
    .m_axi_awready(lite_awready), .m_axi_wdata(lite_wdata), .m_axi_wstrb(lite_wstrb),
    .m_axi_wvalid(lite_wvalid), .m_axi_wready(lite_wready), .m_axi_bresp(lite_bresp),
    .m_axi_bvalid(lite_bvalid), .m_axi_bready(lite_bready), .m_axi_araddr(lite_araddr),
    .m_axi_arprot(lite_arprot), .m_axi_arvalid(lite_arvalid), .m_axi_arready(lite_arready),
    .m_axi_rdata(lite_rdata), .m_axi_rresp(lite_rresp), .m_axi_rvalid(lite_rvalid),
    .m_axi_rready(lite_rready)
);

jtag_axi_mem jtag_mem (
    .aclk(clk_200), .aresetn(!rst_200),
    .m_axi_awid(jm_awid),
    .m_axi_awaddr(jm_awaddr),
    .m_axi_awlen(jm_awlen),
    .m_axi_awsize(jm_awsize),
    .m_axi_awburst(jm_awburst),
    .m_axi_awlock(jm_awlock),
    .m_axi_awcache(jm_awcache),
    .m_axi_awprot(jm_awprot),
    .m_axi_awvalid(jm_awvalid),
    .m_axi_awready(jm_awready),
    .m_axi_wdata(jm_wdata),
    .m_axi_wstrb(jm_wstrb),
    .m_axi_wlast(jm_wlast),
    .m_axi_wvalid(jm_wvalid),
    .m_axi_wready(jm_wready),
    .m_axi_bid(jm_bid),
    .m_axi_bresp(jm_bresp),
    .m_axi_bvalid(jm_bvalid),
    .m_axi_bready(jm_bready),
    .m_axi_arid(jm_arid),
    .m_axi_araddr(jm_araddr),
    .m_axi_arlen(jm_arlen),
    .m_axi_arsize(jm_arsize),
    .m_axi_arburst(jm_arburst),
    .m_axi_arlock(jm_arlock),
    .m_axi_arcache(jm_arcache),
    .m_axi_arprot(jm_arprot),
    .m_axi_arvalid(jm_arvalid),
    .m_axi_arready(jm_arready),
    .m_axi_rid(jm_rid),
    .m_axi_rdata(jm_rdata),
    .m_axi_rresp(jm_rresp),
    .m_axi_rlast(jm_rlast),
    .m_axi_rvalid(jm_rvalid),
    .m_axi_rready(jm_rready),
    .m_axi_awqos(jm_awqos), .m_axi_arqos(jm_arqos)
);

// ---------------------------------------------------------------- DDR4
wire ui_clk, ui_rst, calib_done;

// ERNIC's receive writer and WQE processor pass a 1 -> 2 address split: DDR4 (interconnect) or echo_mem
wire wqe_ddr_awid;
wire [31:0] wqe_ddr_awaddr;
wire [7:0] wqe_ddr_awlen;
wire [2:0] wqe_ddr_awsize;
wire [1:0] wqe_ddr_awburst;
wire wqe_ddr_awlock;
wire [3:0] wqe_ddr_awcache;
wire [2:0] wqe_ddr_awprot;
wire wqe_ddr_awvalid;
wire wqe_ddr_awready;
wire [511:0] wqe_ddr_wdata;
wire [63:0] wqe_ddr_wstrb;
wire wqe_ddr_wlast;
wire wqe_ddr_wvalid;
wire wqe_ddr_wready;
wire wqe_ddr_bid;
wire [1:0] wqe_ddr_bresp;
wire wqe_ddr_bvalid;
wire wqe_ddr_bready;
wire wqe_ddr_arid;
wire [31:0] wqe_ddr_araddr;
wire [7:0] wqe_ddr_arlen;
wire [2:0] wqe_ddr_arsize;
wire [1:0] wqe_ddr_arburst;
wire wqe_ddr_arlock;
wire [3:0] wqe_ddr_arcache;
wire [2:0] wqe_ddr_arprot;
wire wqe_ddr_arvalid;
wire wqe_ddr_arready;
wire wqe_ddr_rid;
wire [511:0] wqe_ddr_rdata;
wire [1:0] wqe_ddr_rresp;
wire wqe_ddr_rlast;
wire wqe_ddr_rvalid;
wire wqe_ddr_rready;
wire wqe_mem_awid;
wire [31:0] wqe_mem_awaddr;
wire [7:0] wqe_mem_awlen;
wire [2:0] wqe_mem_awsize;
wire [1:0] wqe_mem_awburst;
wire wqe_mem_awlock;
wire [3:0] wqe_mem_awcache;
wire [2:0] wqe_mem_awprot;
wire wqe_mem_awvalid;
wire wqe_mem_awready;
wire [511:0] wqe_mem_wdata;
wire [63:0] wqe_mem_wstrb;
wire wqe_mem_wlast;
wire wqe_mem_wvalid;
wire wqe_mem_wready;
wire wqe_mem_bid;
wire [1:0] wqe_mem_bresp;
wire wqe_mem_bvalid;
wire wqe_mem_bready;
wire wqe_mem_arid;
wire [31:0] wqe_mem_araddr;
wire [7:0] wqe_mem_arlen;
wire [2:0] wqe_mem_arsize;
wire [1:0] wqe_mem_arburst;
wire wqe_mem_arlock;
wire [3:0] wqe_mem_arcache;
wire [2:0] wqe_mem_arprot;
wire wqe_mem_arvalid;
wire wqe_mem_arready;
wire wqe_mem_rid;
wire [511:0] wqe_mem_rdata;
wire [1:0] wqe_mem_rresp;
wire wqe_mem_rlast;
wire wqe_mem_rvalid;
wire wqe_mem_rready;
wire rxd_ddr_awid;
wire [31:0] rxd_ddr_awaddr;
wire [7:0] rxd_ddr_awlen;
wire [2:0] rxd_ddr_awsize;
wire [1:0] rxd_ddr_awburst;
wire rxd_ddr_awlock;
wire [3:0] rxd_ddr_awcache;
wire [2:0] rxd_ddr_awprot;
wire rxd_ddr_awvalid;
wire rxd_ddr_awready;
wire [511:0] rxd_ddr_wdata;
wire [63:0] rxd_ddr_wstrb;
wire rxd_ddr_wlast;
wire rxd_ddr_wvalid;
wire rxd_ddr_wready;
wire rxd_ddr_bid;
wire [1:0] rxd_ddr_bresp;
wire rxd_ddr_bvalid;
wire rxd_ddr_bready;
wire rxd_ddr_arid;
wire [31:0] rxd_ddr_araddr;
wire [7:0] rxd_ddr_arlen;
wire [2:0] rxd_ddr_arsize;
wire [1:0] rxd_ddr_arburst;
wire rxd_ddr_arlock;
wire [3:0] rxd_ddr_arcache;
wire [2:0] rxd_ddr_arprot;
wire rxd_ddr_arvalid;
wire rxd_ddr_arready;
wire rxd_ddr_rid;
wire [511:0] rxd_ddr_rdata;
wire [1:0] rxd_ddr_rresp;
wire rxd_ddr_rlast;
wire rxd_ddr_rvalid;
wire rxd_ddr_rready;
wire rxd_mem_awid;
wire [31:0] rxd_mem_awaddr;
wire [7:0] rxd_mem_awlen;
wire [2:0] rxd_mem_awsize;
wire [1:0] rxd_mem_awburst;
wire rxd_mem_awlock;
wire [3:0] rxd_mem_awcache;
wire [2:0] rxd_mem_awprot;
wire rxd_mem_awvalid;
wire rxd_mem_awready;
wire [511:0] rxd_mem_wdata;
wire [63:0] rxd_mem_wstrb;
wire rxd_mem_wlast;
wire rxd_mem_wvalid;
wire rxd_mem_wready;
wire rxd_mem_bid;
wire [1:0] rxd_mem_bresp;
wire rxd_mem_bvalid;
wire rxd_mem_bready;
wire rxd_mem_arid;
wire [31:0] rxd_mem_araddr;
wire [7:0] rxd_mem_arlen;
wire [2:0] rxd_mem_arsize;
wire [1:0] rxd_mem_arburst;
wire rxd_mem_arlock;
wire [3:0] rxd_mem_arcache;
wire [2:0] rxd_mem_arprot;
wire rxd_mem_arvalid;
wire rxd_mem_arready;
wire rxd_mem_rid;
wire [511:0] rxd_mem_rdata;
wire [1:0] rxd_mem_rresp;
wire rxd_mem_rlast;
wire rxd_mem_rvalid;
wire rxd_mem_rready;

axi_ic_0 ddr_ic (
    .INTERCONNECT_ACLK(ui_clk), .INTERCONNECT_ARESETN(!ui_rst),
    .S00_AXI_AWID(qp_mgr_awid),
    .S00_AXI_AWADDR(qp_mgr_awaddr),
    .S00_AXI_AWLEN(qp_mgr_awlen),
    .S00_AXI_AWSIZE(qp_mgr_awsize),
    .S00_AXI_AWBURST(qp_mgr_awburst),
    .S00_AXI_AWLOCK(qp_mgr_awlock),
    .S00_AXI_AWCACHE(qp_mgr_awcache),
    .S00_AXI_AWPROT(qp_mgr_awprot),
    .S00_AXI_AWVALID(qp_mgr_awvalid),
    .S00_AXI_AWREADY(qp_mgr_awready),
    .S00_AXI_WDATA(qp_mgr_wdata),
    .S00_AXI_WSTRB(qp_mgr_wstrb),
    .S00_AXI_WLAST(qp_mgr_wlast),
    .S00_AXI_WVALID(qp_mgr_wvalid),
    .S00_AXI_WREADY(qp_mgr_wready),
    .S00_AXI_BID(qp_mgr_bid),
    .S00_AXI_BRESP(qp_mgr_bresp),
    .S00_AXI_BVALID(qp_mgr_bvalid),
    .S00_AXI_BREADY(qp_mgr_bready),
    .S00_AXI_ARID(qp_mgr_arid),
    .S00_AXI_ARADDR(qp_mgr_araddr),
    .S00_AXI_ARLEN(qp_mgr_arlen),
    .S00_AXI_ARSIZE(qp_mgr_arsize),
    .S00_AXI_ARBURST(qp_mgr_arburst),
    .S00_AXI_ARLOCK(qp_mgr_arlock),
    .S00_AXI_ARCACHE(qp_mgr_arcache),
    .S00_AXI_ARPROT(qp_mgr_arprot),
    .S00_AXI_ARVALID(qp_mgr_arvalid),
    .S00_AXI_ARREADY(qp_mgr_arready),
    .S00_AXI_RID(qp_mgr_rid),
    .S00_AXI_RDATA(qp_mgr_rdata),
    .S00_AXI_RRESP(qp_mgr_rresp),
    .S00_AXI_RLAST(qp_mgr_rlast),
    .S00_AXI_RVALID(qp_mgr_rvalid),
    .S00_AXI_RREADY(qp_mgr_rready),
    .S00_AXI_AWQOS(4'd0), .S00_AXI_ARQOS(4'd0),
    .S00_AXI_ACLK(clk_200), .S00_AXI_ARESET_OUT_N(),
    .S01_AXI_AWID(wqe_ddr_awid),
    .S01_AXI_AWADDR(wqe_ddr_awaddr),
    .S01_AXI_AWLEN(wqe_ddr_awlen),
    .S01_AXI_AWSIZE(wqe_ddr_awsize),
    .S01_AXI_AWBURST(wqe_ddr_awburst),
    .S01_AXI_AWLOCK(wqe_ddr_awlock),
    .S01_AXI_AWCACHE(wqe_ddr_awcache),
    .S01_AXI_AWPROT(wqe_ddr_awprot),
    .S01_AXI_AWVALID(wqe_ddr_awvalid),
    .S01_AXI_AWREADY(wqe_ddr_awready),
    .S01_AXI_WDATA(wqe_ddr_wdata),
    .S01_AXI_WSTRB(wqe_ddr_wstrb),
    .S01_AXI_WLAST(wqe_ddr_wlast),
    .S01_AXI_WVALID(wqe_ddr_wvalid),
    .S01_AXI_WREADY(wqe_ddr_wready),
    .S01_AXI_BID(wqe_ddr_bid),
    .S01_AXI_BRESP(wqe_ddr_bresp),
    .S01_AXI_BVALID(wqe_ddr_bvalid),
    .S01_AXI_BREADY(wqe_ddr_bready),
    .S01_AXI_ARID(wqe_ddr_arid),
    .S01_AXI_ARADDR(wqe_ddr_araddr),
    .S01_AXI_ARLEN(wqe_ddr_arlen),
    .S01_AXI_ARSIZE(wqe_ddr_arsize),
    .S01_AXI_ARBURST(wqe_ddr_arburst),
    .S01_AXI_ARLOCK(wqe_ddr_arlock),
    .S01_AXI_ARCACHE(wqe_ddr_arcache),
    .S01_AXI_ARPROT(wqe_ddr_arprot),
    .S01_AXI_ARVALID(wqe_ddr_arvalid),
    .S01_AXI_ARREADY(wqe_ddr_arready),
    .S01_AXI_RID(wqe_ddr_rid),
    .S01_AXI_RDATA(wqe_ddr_rdata),
    .S01_AXI_RRESP(wqe_ddr_rresp),
    .S01_AXI_RLAST(wqe_ddr_rlast),
    .S01_AXI_RVALID(wqe_ddr_rvalid),
    .S01_AXI_RREADY(wqe_ddr_rready),
    .S01_AXI_AWQOS(4'd0), .S01_AXI_ARQOS(4'd0),
    .S01_AXI_ACLK(clk_200), .S01_AXI_ARESET_OUT_N(),
    .S02_AXI_AWID(rxd_ddr_awid),
    .S02_AXI_AWADDR(rxd_ddr_awaddr),
    .S02_AXI_AWLEN(rxd_ddr_awlen),
    .S02_AXI_AWSIZE(rxd_ddr_awsize),
    .S02_AXI_AWBURST(rxd_ddr_awburst),
    .S02_AXI_AWLOCK(rxd_ddr_awlock),
    .S02_AXI_AWCACHE(rxd_ddr_awcache),
    .S02_AXI_AWPROT(rxd_ddr_awprot),
    .S02_AXI_AWVALID(rxd_ddr_awvalid),
    .S02_AXI_AWREADY(rxd_ddr_awready),
    .S02_AXI_WDATA(rxd_ddr_wdata),
    .S02_AXI_WSTRB(rxd_ddr_wstrb),
    .S02_AXI_WLAST(rxd_ddr_wlast),
    .S02_AXI_WVALID(rxd_ddr_wvalid),
    .S02_AXI_WREADY(rxd_ddr_wready),
    .S02_AXI_BID(rxd_ddr_bid),
    .S02_AXI_BRESP(rxd_ddr_bresp),
    .S02_AXI_BVALID(rxd_ddr_bvalid),
    .S02_AXI_BREADY(rxd_ddr_bready),
    .S02_AXI_ARID(rxd_ddr_arid),
    .S02_AXI_ARADDR(rxd_ddr_araddr),
    .S02_AXI_ARLEN(rxd_ddr_arlen),
    .S02_AXI_ARSIZE(rxd_ddr_arsize),
    .S02_AXI_ARBURST(rxd_ddr_arburst),
    .S02_AXI_ARLOCK(rxd_ddr_arlock),
    .S02_AXI_ARCACHE(rxd_ddr_arcache),
    .S02_AXI_ARPROT(rxd_ddr_arprot),
    .S02_AXI_ARVALID(rxd_ddr_arvalid),
    .S02_AXI_ARREADY(rxd_ddr_arready),
    .S02_AXI_RID(rxd_ddr_rid),
    .S02_AXI_RDATA(rxd_ddr_rdata),
    .S02_AXI_RRESP(rxd_ddr_rresp),
    .S02_AXI_RLAST(rxd_ddr_rlast),
    .S02_AXI_RVALID(rxd_ddr_rvalid),
    .S02_AXI_RREADY(rxd_ddr_rready),
    .S02_AXI_AWQOS(4'd0), .S02_AXI_ARQOS(4'd0),
    .S02_AXI_ACLK(clk_200), .S02_AXI_ARESET_OUT_N(),
    .S03_AXI_AWID(rx_pkt_hndler_rdrsp_awid),
    .S03_AXI_AWADDR(rx_pkt_hndler_rdrsp_awaddr),
    .S03_AXI_AWLEN(rx_pkt_hndler_rdrsp_awlen),
    .S03_AXI_AWSIZE(rx_pkt_hndler_rdrsp_awsize),
    .S03_AXI_AWBURST(rx_pkt_hndler_rdrsp_awburst),
    .S03_AXI_AWLOCK(rx_pkt_hndler_rdrsp_awlock),
    .S03_AXI_AWCACHE(rx_pkt_hndler_rdrsp_awcache),
    .S03_AXI_AWPROT(rx_pkt_hndler_rdrsp_awprot),
    .S03_AXI_AWVALID(rx_pkt_hndler_rdrsp_awvalid),
    .S03_AXI_AWREADY(rx_pkt_hndler_rdrsp_awready),
    .S03_AXI_WDATA(rx_pkt_hndler_rdrsp_wdata),
    .S03_AXI_WSTRB(rx_pkt_hndler_rdrsp_wstrb),
    .S03_AXI_WLAST(rx_pkt_hndler_rdrsp_wlast),
    .S03_AXI_WVALID(rx_pkt_hndler_rdrsp_wvalid),
    .S03_AXI_WREADY(rx_pkt_hndler_rdrsp_wready),
    .S03_AXI_BID(rx_pkt_hndler_rdrsp_bid),
    .S03_AXI_BRESP(rx_pkt_hndler_rdrsp_bresp),
    .S03_AXI_BVALID(rx_pkt_hndler_rdrsp_bvalid),
    .S03_AXI_BREADY(rx_pkt_hndler_rdrsp_bready),
    .S03_AXI_ARID(rx_pkt_hndler_rdrsp_arid),
    .S03_AXI_ARADDR(rx_pkt_hndler_rdrsp_araddr),
    .S03_AXI_ARLEN(rx_pkt_hndler_rdrsp_arlen),
    .S03_AXI_ARSIZE(rx_pkt_hndler_rdrsp_arsize),
    .S03_AXI_ARBURST(rx_pkt_hndler_rdrsp_arburst),
    .S03_AXI_ARLOCK(rx_pkt_hndler_rdrsp_arlock),
    .S03_AXI_ARCACHE(rx_pkt_hndler_rdrsp_arcache),
    .S03_AXI_ARPROT(rx_pkt_hndler_rdrsp_arprot),
    .S03_AXI_ARVALID(rx_pkt_hndler_rdrsp_arvalid),
    .S03_AXI_ARREADY(rx_pkt_hndler_rdrsp_arready),
    .S03_AXI_RID(rx_pkt_hndler_rdrsp_rid),
    .S03_AXI_RDATA(rx_pkt_hndler_rdrsp_rdata),
    .S03_AXI_RRESP(rx_pkt_hndler_rdrsp_rresp),
    .S03_AXI_RLAST(rx_pkt_hndler_rdrsp_rlast),
    .S03_AXI_RVALID(rx_pkt_hndler_rdrsp_rvalid),
    .S03_AXI_RREADY(rx_pkt_hndler_rdrsp_rready),
    .S03_AXI_AWQOS(4'd0), .S03_AXI_ARQOS(4'd0),
    .S03_AXI_ACLK(clk_200), .S03_AXI_ARESET_OUT_N(),
    .S04_AXI_AWID(resp_hndler_awid),
    .S04_AXI_AWADDR(resp_hndler_awaddr),
    .S04_AXI_AWLEN(resp_hndler_awlen),
    .S04_AXI_AWSIZE(resp_hndler_awsize),
    .S04_AXI_AWBURST(resp_hndler_awburst),
    .S04_AXI_AWLOCK(resp_hndler_awlock),
    .S04_AXI_AWCACHE(resp_hndler_awcache),
    .S04_AXI_AWPROT(resp_hndler_awprot),
    .S04_AXI_AWVALID(resp_hndler_awvalid),
    .S04_AXI_AWREADY(resp_hndler_awready),
    .S04_AXI_WDATA(resp_hndler_wdata),
    .S04_AXI_WSTRB(resp_hndler_wstrb),
    .S04_AXI_WLAST(resp_hndler_wlast),
    .S04_AXI_WVALID(resp_hndler_wvalid),
    .S04_AXI_WREADY(resp_hndler_wready),
    .S04_AXI_BID(resp_hndler_bid),
    .S04_AXI_BRESP(resp_hndler_bresp),
    .S04_AXI_BVALID(resp_hndler_bvalid),
    .S04_AXI_BREADY(resp_hndler_bready),
    .S04_AXI_ARID(resp_hndler_arid),
    .S04_AXI_ARADDR(resp_hndler_araddr),
    .S04_AXI_ARLEN(resp_hndler_arlen),
    .S04_AXI_ARSIZE(resp_hndler_arsize),
    .S04_AXI_ARBURST(resp_hndler_arburst),
    .S04_AXI_ARLOCK(resp_hndler_arlock),
    .S04_AXI_ARCACHE(resp_hndler_arcache),
    .S04_AXI_ARPROT(resp_hndler_arprot),
    .S04_AXI_ARVALID(resp_hndler_arvalid),
    .S04_AXI_ARREADY(resp_hndler_arready),
    .S04_AXI_RID(resp_hndler_rid),
    .S04_AXI_RDATA(resp_hndler_rdata),
    .S04_AXI_RRESP(resp_hndler_rresp),
    .S04_AXI_RLAST(resp_hndler_rlast),
    .S04_AXI_RVALID(resp_hndler_rvalid),
    .S04_AXI_RREADY(resp_hndler_rready),
    .S04_AXI_AWQOS(4'd0), .S04_AXI_ARQOS(4'd0),
    .S04_AXI_ACLK(clk_200), .S04_AXI_ARESET_OUT_N(),
    .S05_AXI_AWID(jm_awid),
    .S05_AXI_AWADDR(jm_awaddr),
    .S05_AXI_AWLEN(jm_awlen),
    .S05_AXI_AWSIZE(jm_awsize),
    .S05_AXI_AWBURST(jm_awburst),
    .S05_AXI_AWLOCK(jm_awlock),
    .S05_AXI_AWCACHE(jm_awcache),
    .S05_AXI_AWPROT(jm_awprot),
    .S05_AXI_AWVALID(jm_awvalid),
    .S05_AXI_AWREADY(jm_awready),
    .S05_AXI_WDATA(jm_wdata),
    .S05_AXI_WSTRB(jm_wstrb),
    .S05_AXI_WLAST(jm_wlast),
    .S05_AXI_WVALID(jm_wvalid),
    .S05_AXI_WREADY(jm_wready),
    .S05_AXI_BID(jm_bid),
    .S05_AXI_BRESP(jm_bresp),
    .S05_AXI_BVALID(jm_bvalid),
    .S05_AXI_BREADY(jm_bready),
    .S05_AXI_ARID(jm_arid),
    .S05_AXI_ARADDR(jm_araddr),
    .S05_AXI_ARLEN(jm_arlen),
    .S05_AXI_ARSIZE(jm_arsize),
    .S05_AXI_ARBURST(jm_arburst),
    .S05_AXI_ARLOCK(jm_arlock),
    .S05_AXI_ARCACHE(jm_arcache),
    .S05_AXI_ARPROT(jm_arprot),
    .S05_AXI_ARVALID(jm_arvalid),
    .S05_AXI_ARREADY(jm_arready),
    .S05_AXI_RID(jm_rid),
    .S05_AXI_RDATA(jm_rdata),
    .S05_AXI_RRESP(jm_rresp),
    .S05_AXI_RLAST(jm_rlast),
    .S05_AXI_RVALID(jm_rvalid),
    .S05_AXI_RREADY(jm_rready),
    .S05_AXI_AWQOS(jm_awqos), .S05_AXI_ARQOS(jm_arqos),
    .S05_AXI_ACLK(clk_200), .S05_AXI_ARESET_OUT_N(),
    .M00_AXI_AWID(ddr_awid),
    .M00_AXI_AWADDR(ddr_awaddr),
    .M00_AXI_AWLEN(ddr_awlen),
    .M00_AXI_AWSIZE(ddr_awsize),
    .M00_AXI_AWBURST(ddr_awburst),
    .M00_AXI_AWLOCK(ddr_awlock),
    .M00_AXI_AWCACHE(ddr_awcache),
    .M00_AXI_AWPROT(ddr_awprot),
    .M00_AXI_AWVALID(ddr_awvalid),
    .M00_AXI_AWREADY(ddr_awready),
    .M00_AXI_WDATA(ddr_wdata),
    .M00_AXI_WSTRB(ddr_wstrb),
    .M00_AXI_WLAST(ddr_wlast),
    .M00_AXI_WVALID(ddr_wvalid),
    .M00_AXI_WREADY(ddr_wready),
    .M00_AXI_BID(ddr_bid),
    .M00_AXI_BRESP(ddr_bresp),
    .M00_AXI_BVALID(ddr_bvalid),
    .M00_AXI_BREADY(ddr_bready),
    .M00_AXI_ARID(ddr_arid),
    .M00_AXI_ARADDR(ddr_araddr),
    .M00_AXI_ARLEN(ddr_arlen),
    .M00_AXI_ARSIZE(ddr_arsize),
    .M00_AXI_ARBURST(ddr_arburst),
    .M00_AXI_ARLOCK(ddr_arlock),
    .M00_AXI_ARCACHE(ddr_arcache),
    .M00_AXI_ARPROT(ddr_arprot),
    .M00_AXI_ARVALID(ddr_arvalid),
    .M00_AXI_ARREADY(ddr_arready),
    .M00_AXI_RID(ddr_rid),
    .M00_AXI_RDATA(ddr_rdata),
    .M00_AXI_RRESP(ddr_rresp),
    .M00_AXI_RLAST(ddr_rlast),
    .M00_AXI_RVALID(ddr_rvalid),
    .M00_AXI_RREADY(ddr_rready),
    .M00_AXI_AWQOS(ddr_awqos), .M00_AXI_ARQOS(ddr_arqos),
    .M00_AXI_ACLK(ui_clk), .M00_AXI_ARESET_OUT_N()
);

ddr4_0 ddr_inst (
    .c0_init_calib_complete(calib_done), .dbg_clk(), .dbg_bus(),
    .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n),
    .c0_ddr4_adr(c0_ddr4_adr), .c0_ddr4_ba(c0_ddr4_ba), .c0_ddr4_cke(c0_ddr4_cke),
    .c0_ddr4_cs_n(c0_ddr4_cs_n), .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n), .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c), .c0_ddr4_dqs_t(c0_ddr4_dqs_t), .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_bg(c0_ddr4_bg), .c0_ddr4_reset_n(c0_ddr4_reset_n), .c0_ddr4_act_n(c0_ddr4_act_n),
    .c0_ddr4_ck_c(c0_ddr4_ck_c), .c0_ddr4_ck_t(c0_ddr4_ck_t),
    .c0_ddr4_ui_clk(ui_clk), .c0_ddr4_ui_clk_sync_rst(ui_rst),
    .c0_ddr4_aresetn(!ui_rst),
    .c0_ddr4_s_axi_awqos(ddr_awqos), .c0_ddr4_s_axi_arqos(ddr_arqos),
    .c0_ddr4_s_axi_awid(ddr_awid),
    .c0_ddr4_s_axi_awaddr(ddr_awaddr),
    .c0_ddr4_s_axi_awlen(ddr_awlen),
    .c0_ddr4_s_axi_awsize(ddr_awsize),
    .c0_ddr4_s_axi_awburst(ddr_awburst),
    .c0_ddr4_s_axi_awlock(ddr_awlock),
    .c0_ddr4_s_axi_awcache(ddr_awcache),
    .c0_ddr4_s_axi_awprot(ddr_awprot),
    .c0_ddr4_s_axi_awvalid(ddr_awvalid),
    .c0_ddr4_s_axi_awready(ddr_awready),
    .c0_ddr4_s_axi_wdata(ddr_wdata),
    .c0_ddr4_s_axi_wstrb(ddr_wstrb),
    .c0_ddr4_s_axi_wlast(ddr_wlast),
    .c0_ddr4_s_axi_wvalid(ddr_wvalid),
    .c0_ddr4_s_axi_wready(ddr_wready),
    .c0_ddr4_s_axi_bid(ddr_bid),
    .c0_ddr4_s_axi_bresp(ddr_bresp),
    .c0_ddr4_s_axi_bvalid(ddr_bvalid),
    .c0_ddr4_s_axi_bready(ddr_bready),
    .c0_ddr4_s_axi_arid(ddr_arid),
    .c0_ddr4_s_axi_araddr(ddr_araddr),
    .c0_ddr4_s_axi_arlen(ddr_arlen),
    .c0_ddr4_s_axi_arsize(ddr_arsize),
    .c0_ddr4_s_axi_arburst(ddr_arburst),
    .c0_ddr4_s_axi_arlock(ddr_arlock),
    .c0_ddr4_s_axi_arcache(ddr_arcache),
    .c0_ddr4_s_axi_arprot(ddr_arprot),
    .c0_ddr4_s_axi_arvalid(ddr_arvalid),
    .c0_ddr4_s_axi_arready(ddr_arready),
    .c0_ddr4_s_axi_rid(ddr_rid),
    .c0_ddr4_s_axi_rdata(ddr_rdata),
    .c0_ddr4_s_axi_rresp(ddr_rresp),
    .c0_ddr4_s_axi_rlast(ddr_rlast),
    .c0_ddr4_s_axi_rvalid(ddr_rvalid),
    .c0_ddr4_s_axi_rready(ddr_rready),
    .sys_rst(!reset_n)
);

// ---------------------------------------------------------------- per-second counters (VIO)
wire [31:0] c_mac_rx, c_roce_rx, c_other_rx, c_mac_rx_bad, c_mac_tx;
wire [39:0] c_mac_rx_bytes, c_mac_tx_bytes;

rate_counter #(.CLK_HZ(MAC_HZ)) r0 (.clk(mac_clk), .rst(mac_rst), .inc(mac_rx_tvalid && mac_rx_tlast), .rate(c_mac_rx));
rate_counter #(.CLK_HZ(MAC_HZ)) r1 (.clk(mac_clk), .rst(mac_rst), .inc(roce_frame), .rate(c_roce_rx));
rate_counter #(.CLK_HZ(MAC_HZ)) r2 (.clk(mac_clk), .rst(mac_rst), .inc(other_frame), .rate(c_other_rx));
rate_counter #(.CLK_HZ(MAC_HZ)) r3 (.clk(mac_clk), .rst(mac_rst), .inc(mac_rx_tvalid && mac_rx_tlast && mac_rx_tuser), .rate(c_mac_rx_bad));
rate_counter #(.CLK_HZ(MAC_HZ)) r4 (.clk(mac_clk), .rst(mac_rst), .inc(mac_tx_tvalid && mac_tx_tready && mac_tx_tlast), .rate(c_mac_tx));
// bytes per beat, three pipeline stages (a 64-bit popcount does not fit in one 322 MHz cycle):
// keep registered, four 16-bit counts, their sum. RX counts the RoCE frames going to ERNIC.
function [4:0] ones16(input [15:0] k);
    integer i;
    begin
        ones16 = 5'd0;
        for (i = 0; i < 16; i = i + 1) ones16 = ones16 + k[i];
    end
endfunction

reg [KW-1:0] rx_keep_q = {KW{1'b0}}, tx_keep_q = {KW{1'b0}};
reg [19:0]   rx_part_q = 20'd0, tx_part_q = 20'd0;
reg [6:0]    rx_bytes_q = 7'd0, tx_bytes_q = 7'd0;
always @(posedge mac_clk) begin
    rx_keep_q  <= roce_tvalid ? roce_tkeep : {KW{1'b0}};
    tx_keep_q  <= (mac_tx_tvalid && mac_tx_tready) ? mac_tx_tkeep : {KW{1'b0}};
    rx_part_q  <= {ones16(rx_keep_q[63:48]), ones16(rx_keep_q[47:32]), ones16(rx_keep_q[31:16]), ones16(rx_keep_q[15:0])};
    tx_part_q  <= {ones16(tx_keep_q[63:48]), ones16(tx_keep_q[47:32]), ones16(tx_keep_q[31:16]), ones16(tx_keep_q[15:0])};
    rx_bytes_q <= rx_part_q[19:15] + rx_part_q[14:10] + rx_part_q[9:5] + rx_part_q[4:0];
    tx_bytes_q <= tx_part_q[19:15] + tx_part_q[14:10] + tx_part_q[9:5] + tx_part_q[4:0];
end

wire [31:0] c_rxq_drop;
rate_counter #(.CLK_HZ(MAC_HZ), .INC_WIDTH(7), .WIDTH(40)) r5 (.clk(mac_clk), .rst(mac_rst), .inc(rx_bytes_q), .rate(c_mac_rx_bytes));
rate_counter #(.CLK_HZ(MAC_HZ), .INC_WIDTH(7), .WIDTH(40)) r6 (.clk(mac_clk), .rst(mac_rst), .inc(tx_bytes_q), .rate(c_mac_tx_bytes));
rate_counter #(.CLK_HZ(MAC_HZ)) r7 (.clk(mac_clk), .rst(mac_rst), .inc(rxq_overflow), .rate(c_rxq_drop));

// quasi-static status bits from other clock domains, re-timed for the VIO
(* ASYNC_REG = "TRUE" *) reg [2:0] status_cdc_sr [0:1];
always @(posedge mac_clk) begin
    status_cdc_sr[0] <= {rnic_intr, mmcm_locked, calib_done};
    status_cdc_sr[1] <= status_cdc_sr[0];
end
wire [7:0] status = {5'd0, status_cdc_sr[1]};

// ---------------------------------------------------------------- echo_mem (0x8000_0000) behind two address splits
axi_split2 wqe_split (
    .clk(clk_200), .rst(rst_200),
    .s_awid(wqe_proc_top_awid), .s_awaddr(wqe_proc_top_awaddr), .s_awlen(wqe_proc_top_awlen), .s_awsize(wqe_proc_top_awsize), .s_awburst(wqe_proc_top_awburst), .s_awlock(wqe_proc_top_awlock), .s_awcache(wqe_proc_top_awcache), .s_awprot(wqe_proc_top_awprot), .s_wdata(wqe_proc_top_wdata), .s_wstrb(wqe_proc_top_wstrb), .s_wlast(wqe_proc_top_wlast),
    .s_arid(wqe_proc_top_arid), .s_araddr(wqe_proc_top_araddr), .s_arlen(wqe_proc_top_arlen), .s_arsize(wqe_proc_top_arsize), .s_arburst(wqe_proc_top_arburst), .s_arlock(wqe_proc_top_arlock), .s_arcache(wqe_proc_top_arcache), .s_arprot(wqe_proc_top_arprot), .s_awvalid(wqe_proc_top_awvalid), .s_awready(wqe_proc_top_awready), .s_wvalid(wqe_proc_top_wvalid), .s_wready(wqe_proc_top_wready), .s_bid(wqe_proc_top_bid), .s_bresp(wqe_proc_top_bresp), .s_bvalid(wqe_proc_top_bvalid), .s_bready(wqe_proc_top_bready), .s_arvalid(wqe_proc_top_arvalid), .s_arready(wqe_proc_top_arready), .s_rid(wqe_proc_top_rid), .s_rdata(wqe_proc_top_rdata), .s_rresp(wqe_proc_top_rresp), .s_rlast(wqe_proc_top_rlast), .s_rvalid(wqe_proc_top_rvalid), .s_rready(wqe_proc_top_rready),
    .m_awid(wqe_ddr_awid), .m_awaddr(wqe_ddr_awaddr), .m_awlen(wqe_ddr_awlen), .m_awsize(wqe_ddr_awsize), .m_awburst(wqe_ddr_awburst), .m_awlock(wqe_ddr_awlock), .m_awcache(wqe_ddr_awcache), .m_awprot(wqe_ddr_awprot), .m_wdata(wqe_ddr_wdata), .m_wstrb(wqe_ddr_wstrb), .m_wlast(wqe_ddr_wlast), .m_arid(wqe_ddr_arid), .m_araddr(wqe_ddr_araddr), .m_arlen(wqe_ddr_arlen), .m_arsize(wqe_ddr_arsize), .m_arburst(wqe_ddr_arburst), .m_arlock(wqe_ddr_arlock), .m_arcache(wqe_ddr_arcache), .m_arprot(wqe_ddr_arprot),
    .m_awvalid({wqe_mem_awvalid, wqe_ddr_awvalid}),
    .m_awready({wqe_mem_awready, wqe_ddr_awready}),
    .m_wvalid({wqe_mem_wvalid, wqe_ddr_wvalid}),
    .m_wready({wqe_mem_wready, wqe_ddr_wready}),
    .m_bid({wqe_mem_bid, wqe_ddr_bid}),
    .m_bresp({wqe_mem_bresp, wqe_ddr_bresp}),
    .m_bvalid({wqe_mem_bvalid, wqe_ddr_bvalid}),
    .m_bready({wqe_mem_bready, wqe_ddr_bready}),
    .m_arvalid({wqe_mem_arvalid, wqe_ddr_arvalid}),
    .m_arready({wqe_mem_arready, wqe_ddr_arready}),
    .m_rid({wqe_mem_rid, wqe_ddr_rid}),
    .m_rdata({wqe_mem_rdata, wqe_ddr_rdata}),
    .m_rresp({wqe_mem_rresp, wqe_ddr_rresp}),
    .m_rlast({wqe_mem_rlast, wqe_ddr_rlast}),
    .m_rvalid({wqe_mem_rvalid, wqe_ddr_rvalid}),
    .m_rready({wqe_mem_rready, wqe_ddr_rready})
);
assign {wqe_mem_awid, wqe_mem_awaddr, wqe_mem_awlen, wqe_mem_awsize, wqe_mem_awburst, wqe_mem_awlock, wqe_mem_awcache, wqe_mem_awprot, wqe_mem_wdata, wqe_mem_wstrb, wqe_mem_wlast, wqe_mem_arid, wqe_mem_araddr, wqe_mem_arlen, wqe_mem_arsize, wqe_mem_arburst, wqe_mem_arlock, wqe_mem_arcache, wqe_mem_arprot} =
       {wqe_ddr_awid, wqe_ddr_awaddr, wqe_ddr_awlen, wqe_ddr_awsize, wqe_ddr_awburst, wqe_ddr_awlock, wqe_ddr_awcache, wqe_ddr_awprot, wqe_ddr_wdata, wqe_ddr_wstrb, wqe_ddr_wlast, wqe_ddr_arid, wqe_ddr_araddr, wqe_ddr_arlen, wqe_ddr_arsize, wqe_ddr_arburst, wqe_ddr_arlock, wqe_ddr_arcache, wqe_ddr_arprot};

axi_split2 rxd_split (
    .clk(clk_200), .rst(rst_200),
    .s_awid(rx_pkt_hndler_ddr_awid), .s_awaddr(rx_pkt_hndler_ddr_awaddr), .s_awlen(rx_pkt_hndler_ddr_awlen), .s_awsize(rx_pkt_hndler_ddr_awsize), .s_awburst(rx_pkt_hndler_ddr_awburst), .s_awlock(rx_pkt_hndler_ddr_awlock), .s_awcache(rx_pkt_hndler_ddr_awcache), .s_awprot(rx_pkt_hndler_ddr_awprot), .s_wdata(rx_pkt_hndler_ddr_wdata), .s_wstrb(rx_pkt_hndler_ddr_wstrb), .s_wlast(rx_pkt_hndler_ddr_wlast),
    .s_arid(rx_pkt_hndler_ddr_arid), .s_araddr(rx_pkt_hndler_ddr_araddr), .s_arlen(rx_pkt_hndler_ddr_arlen), .s_arsize(rx_pkt_hndler_ddr_arsize), .s_arburst(rx_pkt_hndler_ddr_arburst), .s_arlock(rx_pkt_hndler_ddr_arlock), .s_arcache(rx_pkt_hndler_ddr_arcache), .s_arprot(rx_pkt_hndler_ddr_arprot), .s_awvalid(rx_pkt_hndler_ddr_awvalid), .s_awready(rx_pkt_hndler_ddr_awready), .s_wvalid(rx_pkt_hndler_ddr_wvalid), .s_wready(rx_pkt_hndler_ddr_wready), .s_bid(rx_pkt_hndler_ddr_bid), .s_bresp(rx_pkt_hndler_ddr_bresp), .s_bvalid(rx_pkt_hndler_ddr_bvalid), .s_bready(rx_pkt_hndler_ddr_bready), .s_arvalid(rx_pkt_hndler_ddr_arvalid), .s_arready(rx_pkt_hndler_ddr_arready), .s_rid(rx_pkt_hndler_ddr_rid), .s_rdata(rx_pkt_hndler_ddr_rdata), .s_rresp(rx_pkt_hndler_ddr_rresp), .s_rlast(rx_pkt_hndler_ddr_rlast), .s_rvalid(rx_pkt_hndler_ddr_rvalid), .s_rready(rx_pkt_hndler_ddr_rready),
    .m_awid(rxd_ddr_awid), .m_awaddr(rxd_ddr_awaddr), .m_awlen(rxd_ddr_awlen), .m_awsize(rxd_ddr_awsize), .m_awburst(rxd_ddr_awburst), .m_awlock(rxd_ddr_awlock), .m_awcache(rxd_ddr_awcache), .m_awprot(rxd_ddr_awprot), .m_wdata(rxd_ddr_wdata), .m_wstrb(rxd_ddr_wstrb), .m_wlast(rxd_ddr_wlast), .m_arid(rxd_ddr_arid), .m_araddr(rxd_ddr_araddr), .m_arlen(rxd_ddr_arlen), .m_arsize(rxd_ddr_arsize), .m_arburst(rxd_ddr_arburst), .m_arlock(rxd_ddr_arlock), .m_arcache(rxd_ddr_arcache), .m_arprot(rxd_ddr_arprot),
    .m_awvalid({rxd_mem_awvalid, rxd_ddr_awvalid}),
    .m_awready({rxd_mem_awready, rxd_ddr_awready}),
    .m_wvalid({rxd_mem_wvalid, rxd_ddr_wvalid}),
    .m_wready({rxd_mem_wready, rxd_ddr_wready}),
    .m_bid({rxd_mem_bid, rxd_ddr_bid}),
    .m_bresp({rxd_mem_bresp, rxd_ddr_bresp}),
    .m_bvalid({rxd_mem_bvalid, rxd_ddr_bvalid}),
    .m_bready({rxd_mem_bready, rxd_ddr_bready}),
    .m_arvalid({rxd_mem_arvalid, rxd_ddr_arvalid}),
    .m_arready({rxd_mem_arready, rxd_ddr_arready}),
    .m_rid({rxd_mem_rid, rxd_ddr_rid}),
    .m_rdata({rxd_mem_rdata, rxd_ddr_rdata}),
    .m_rresp({rxd_mem_rresp, rxd_ddr_rresp}),
    .m_rlast({rxd_mem_rlast, rxd_ddr_rlast}),
    .m_rvalid({rxd_mem_rvalid, rxd_ddr_rvalid}),
    .m_rready({rxd_mem_rready, rxd_ddr_rready})
);
assign {rxd_mem_awid, rxd_mem_awaddr, rxd_mem_awlen, rxd_mem_awsize, rxd_mem_awburst, rxd_mem_awlock, rxd_mem_awcache, rxd_mem_awprot, rxd_mem_wdata, rxd_mem_wstrb, rxd_mem_wlast, rxd_mem_arid, rxd_mem_araddr, rxd_mem_arlen, rxd_mem_arsize, rxd_mem_arburst, rxd_mem_arlock, rxd_mem_arcache, rxd_mem_arprot} =
       {rxd_ddr_awid, rxd_ddr_awaddr, rxd_ddr_awlen, rxd_ddr_awsize, rxd_ddr_awburst, rxd_ddr_awlock, rxd_ddr_awcache, rxd_ddr_awprot, rxd_ddr_wdata, rxd_ddr_wstrb, rxd_ddr_wlast, rxd_ddr_arid, rxd_ddr_araddr, rxd_ddr_arlen, rxd_ddr_arsize, rxd_ddr_arburst, rxd_ddr_arlock, rxd_ddr_arcache, rxd_ddr_arprot};

echo_mem #(.DEPTH(64), .BUF_BYTES(4096), .BASE(32'h8000_0000)) echo_mem_inst (
    .clk(clk_200), .rst(rst_200),
    .a_awid(rxd_mem_awid), .a_awaddr(rxd_mem_awaddr), .a_awlen(rxd_mem_awlen), .a_awsize(rxd_mem_awsize),
    .a_awvalid(rxd_mem_awvalid), .a_awready(rxd_mem_awready),
    .a_wdata(rxd_mem_wdata), .a_wstrb(rxd_mem_wstrb), .a_wlast(rxd_mem_wlast), .a_wvalid(rxd_mem_wvalid), .a_wready(rxd_mem_wready),
    .a_bid(rxd_mem_bid), .a_bresp(rxd_mem_bresp), .a_bvalid(rxd_mem_bvalid), .a_bready(rxd_mem_bready),
    .a_arid(rxd_mem_arid), .a_arlen(rxd_mem_arlen), .a_arvalid(rxd_mem_arvalid), .a_arready(rxd_mem_arready),
    .a_rid(rxd_mem_rid), .a_rdata(rxd_mem_rdata), .a_rresp(rxd_mem_rresp), .a_rlast(rxd_mem_rlast),
    .a_rvalid(rxd_mem_rvalid), .a_rready(rxd_mem_rready),
    .b_arid(wqe_mem_arid), .b_araddr(wqe_mem_araddr), .b_arlen(wqe_mem_arlen), .b_arsize(wqe_mem_arsize),
    .b_arvalid(wqe_mem_arvalid), .b_arready(wqe_mem_arready),
    .b_rid(wqe_mem_rid), .b_rdata(wqe_mem_rdata), .b_rresp(wqe_mem_rresp), .b_rlast(wqe_mem_rlast),
    .b_rvalid(wqe_mem_rvalid), .b_rready(wqe_mem_rready),
    .b_awid(wqe_mem_awid), .b_awvalid(wqe_mem_awvalid), .b_awready(wqe_mem_awready),
    .b_wlast(wqe_mem_wlast), .b_wvalid(wqe_mem_wvalid), .b_wready(wqe_mem_wready),
    .b_bid(wqe_mem_bid), .b_bresp(wqe_mem_bresp), .b_bvalid(wqe_mem_bvalid), .b_bready(wqe_mem_bready)
);

// ---------------------------------------------------------------- hardware SEND echo (QP2)
wire [15:0] e_rq_db, e_cq_db, e_other_db, e_sq_pidb, e_rq_cidb;
wire [31:0] e_last_rq, e_last_cq;
wire        echo_rst;                          // pulsed by tests/ernic_config.tcl while configuring

send_echo #(.QP(2), .DEPTH(64)) echo_inst (
    .clk(clk_200), .rst(rst_200 || echo_rst),
    .rq_db_data(rq_db_data), .rq_db_addr(rq_db_addr), .rq_db_valid(rq_db_valid), .rq_db_rdy(rq_db_rdy),
    .cq_db_cnt(cq_db_cnt), .cq_db_addr(cq_db_addr), .cq_db_valid(cq_db_valid), .cq_db_rdy(cq_db_rdy),
    .sq_pidb(sq_pidb), .sq_pidb_addr(sq_pidb_addr), .sq_pidb_valid(sq_pidb_valid), .sq_pidb_rdy(sq_pidb_rdy),
    .rq_cidb(rq_cidb), .rq_cidb_addr(rq_cidb_addr), .rq_cidb_valid(rq_cidb_valid), .rq_cidb_rdy(rq_cidb_rdy),
    .n_rq_db(e_rq_db), .n_cq_db(e_cq_db), .n_other_db(e_other_db), .n_sq_pidb(e_sq_pidb), .n_rq_cidb(e_rq_cidb),
    .last_rq_db(e_last_rq), .last_cq_db(e_last_cq)
);

// echo counters, sampled in their own clock domain
vio_1 vio_echo (
    .clk(clk_200),
    .probe_in0({e_rq_db, e_cq_db, e_sq_pidb, e_rq_cidb}), .probe_in1(e_other_db),
    .probe_in2(e_last_rq), .probe_in3(e_last_cq),
    .probe_out0(echo_rst)
);

vio_0 vio_inst (
    .clk(mac_clk),
    .probe_in0(c_mac_rx), .probe_in1(c_roce_rx), .probe_in2(c_other_rx), .probe_in3(c_mac_rx_bad),
    .probe_in4(c_mac_tx), .probe_in5(c_mac_rx_bytes), .probe_in6(c_mac_tx_bytes), .probe_in7(status),
    .probe_in8(c_rxq_drop)
);

endmodule

`resetall
