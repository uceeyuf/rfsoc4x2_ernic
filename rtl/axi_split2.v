// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// 1 -> 2 AXI4 address split without added latency: addresses with bit SEL_BIT set go to m1, the
// rest to m0. Address, data and response channels pass through combinationally. Ordering is kept
// the simple way: a new read (write) goes out only while all outstanding reads (writes) are for
// the same target, so responses come back in order from one target at a time. W beats follow
// their AW (a W burst waits until its AW has been accepted).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module axi_split2 #(
    parameter SEL_BIT = 31,
    parameter CW      = 6                     // outstanding counter width
)(
    input  wire         clk,
    input  wire         rst,

    // from the master
    input  wire         s_awid,
    input  wire [31:0]  s_awaddr,
    input  wire [7:0]   s_awlen,
    input  wire [2:0]   s_awsize,
    input  wire [1:0]   s_awburst,
    input  wire         s_awlock,
    input  wire [3:0]   s_awcache,
    input  wire [2:0]   s_awprot,
    input  wire         s_awvalid,
    output wire         s_awready,
    input  wire [511:0] s_wdata,
    input  wire [63:0]  s_wstrb,
    input  wire         s_wlast,
    input  wire         s_wvalid,
    output wire         s_wready,
    output wire         s_bid,
    output wire [1:0]   s_bresp,
    output wire         s_bvalid,
    input  wire         s_bready,
    input  wire         s_arid,
    input  wire [31:0]  s_araddr,
    input  wire [7:0]   s_arlen,
    input  wire [2:0]   s_arsize,
    input  wire [1:0]   s_arburst,
    input  wire         s_arlock,
    input  wire [3:0]   s_arcache,
    input  wire [2:0]   s_arprot,
    input  wire         s_arvalid,
    output wire         s_arready,
    output wire         s_rid,
    output wire [511:0] s_rdata,
    output wire [1:0]   s_rresp,
    output wire         s_rlast,
    output wire         s_rvalid,
    input  wire         s_rready,

    // to the targets: request fields are shared, handshakes per target ({m1, m0})
    output wire         m_awid,
    output wire [31:0]  m_awaddr,
    output wire [7:0]   m_awlen,
    output wire [2:0]   m_awsize,
    output wire [1:0]   m_awburst,
    output wire         m_awlock,
    output wire [3:0]   m_awcache,
    output wire [2:0]   m_awprot,
    output wire [1:0]   m_awvalid,
    input  wire [1:0]   m_awready,
    output wire [511:0] m_wdata,
    output wire [63:0]  m_wstrb,
    output wire         m_wlast,
    output wire [1:0]   m_wvalid,
    input  wire [1:0]   m_wready,
    input  wire [1:0]   m_bid,
    input  wire [3:0]   m_bresp,
    input  wire [1:0]   m_bvalid,
    output wire [1:0]   m_bready,
    output wire         m_arid,
    output wire [31:0]  m_araddr,
    output wire [7:0]   m_arlen,
    output wire [2:0]   m_arsize,
    output wire [1:0]   m_arburst,
    output wire         m_arlock,
    output wire [3:0]   m_arcache,
    output wire [2:0]   m_arprot,
    output wire [1:0]   m_arvalid,
    input  wire [1:0]   m_arready,
    input  wire [1:0]   m_rid,
    input  wire [1023:0] m_rdata,
    input  wire [3:0]   m_rresp,
    input  wire [1:0]   m_rlast,
    input  wire [1:0]   m_rvalid,
    output wire [1:0]   m_rready
);

assign m_awid = s_awid;     assign m_awaddr = s_awaddr;   assign m_awlen = s_awlen;
assign m_awsize = s_awsize; assign m_awburst = s_awburst; assign m_awlock = s_awlock;
assign m_awcache = s_awcache; assign m_awprot = s_awprot;
assign m_wdata = s_wdata;   assign m_wstrb = s_wstrb;     assign m_wlast = s_wlast;
assign m_arid = s_arid;     assign m_araddr = s_araddr;   assign m_arlen = s_arlen;
assign m_arsize = s_arsize; assign m_arburst = s_arburst; assign m_arlock = s_arlock;
assign m_arcache = s_arcache; assign m_arprot = s_arprot;

// ------------------------------------------------------------------------ reads
reg [CW-1:0] rd_cnt = {CW{1'b0}};           // bursts whose last beat has not come back
reg          rd_tgt = 1'b0;
wire         ar_sel   = s_araddr[SEL_BIT];
wire         ar_allow = (rd_cnt == 0 || rd_tgt == ar_sel) && rd_cnt != {CW{1'b1}};
wire         ar_hs    = s_arvalid && s_arready;
wire         r_end    = s_rvalid && s_rready && s_rlast;

assign m_arvalid = {s_arvalid && ar_allow && ar_sel, s_arvalid && ar_allow && !ar_sel};
assign s_arready = ar_allow && m_arready[ar_sel];
assign s_rvalid  = m_rvalid[rd_tgt];
assign s_rid     = m_rid[rd_tgt];
assign s_rdata   = m_rdata[rd_tgt * 512 +: 512];
assign s_rresp   = m_rresp[rd_tgt * 2 +: 2];
assign s_rlast   = m_rlast[rd_tgt];
assign m_rready  = {s_rready && rd_tgt, s_rready && !rd_tgt};

always @(posedge clk) begin
    if (ar_hs) rd_tgt <= ar_sel;
    rd_cnt <= rd_cnt + ar_hs - r_end;
    if (rst) rd_cnt <= {CW{1'b0}};
end

// ------------------------------------------------------------------------ writes
reg [CW-1:0] wr_cnt = {CW{1'b0}};           // writes without a B response yet
reg [CW-1:0] wb_cnt = {CW{1'b0}};           // accepted AWs whose W burst is not complete
reg          wr_tgt = 1'b0;
wire         aw_sel   = s_awaddr[SEL_BIT];
wire         aw_allow = (wr_cnt == 0 || wr_tgt == aw_sel) && wr_cnt != {CW{1'b1}};
wire         aw_hs    = s_awvalid && s_awready;
wire         w_end    = s_wvalid && s_wready && s_wlast;
wire         b_hs     = s_bvalid && s_bready;
wire         w_go     = wb_cnt != 0;

assign m_awvalid = {s_awvalid && aw_allow && aw_sel, s_awvalid && aw_allow && !aw_sel};
assign s_awready = aw_allow && m_awready[aw_sel];
assign m_wvalid  = {s_wvalid && w_go && wr_tgt, s_wvalid && w_go && !wr_tgt};
assign s_wready  = w_go && m_wready[wr_tgt];
assign s_bvalid  = m_bvalid[wr_tgt];
assign s_bid     = m_bid[wr_tgt];
assign s_bresp   = m_bresp[wr_tgt * 2 +: 2];
assign m_bready  = {s_bready && wr_tgt, s_bready && !wr_tgt};

always @(posedge clk) begin
    if (aw_hs) wr_tgt <= aw_sel;
    wr_cnt <= wr_cnt + aw_hs - b_hs;
    wb_cnt <= wb_cnt + aw_hs - w_end;
    if (rst) begin
        wr_cnt <= {CW{1'b0}};
        wb_cnt <= {CW{1'b0}};
    end
end

endmodule

`resetall
