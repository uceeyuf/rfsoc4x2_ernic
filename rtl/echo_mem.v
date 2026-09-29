// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// On-chip receive buffers for the hardware SEND echo, so that echoed messages never touch PL
// DDR4: buffer k at BASE + k * BUF_BYTES (ERNIC AXI address), behind two axi_split2.
//
// Port a (ERNIC rx_pkt_hndler_ddr) writes the receive buffers; port b (ERNIC wqe_proc_top) reads
// the message data back for the SENDs. Each port serves one direction at a full beat per cycle;
// the other direction of each port is answered (reads return zeros, writes are discarded) but
// not used. ERNIC reads a message as one burst and waits for it before the next, so the read
// latency counts: the first beat is on R one cycle after AR. INCR bursts; narrow transfers step
// the address by their size.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module echo_mem #(
    parameter        DEPTH      = 64,              // receive buffers / WQEs, power of two
    parameter        BUF_BYTES  = 4096,
    parameter [31:0] BASE       = 32'h8000_0000
)(
    input  wire         clk,
    input  wire         rst,

    // port a: writes
    input  wire         a_awid,
    input  wire [31:0]  a_awaddr,
    input  wire [7:0]   a_awlen,
    input  wire [2:0]   a_awsize,
    input  wire         a_awvalid,
    output wire         a_awready,
    input  wire [511:0] a_wdata,
    input  wire [63:0]  a_wstrb,
    input  wire         a_wlast,
    input  wire         a_wvalid,
    output wire         a_wready,
    output wire         a_bid,
    output wire [1:0]   a_bresp,
    output wire         a_bvalid,
    input  wire         a_bready,
    input  wire         a_arid,
    input  wire [7:0]   a_arlen,
    input  wire         a_arvalid,
    output wire         a_arready,
    output reg          a_rid = 1'b0,
    output wire [511:0] a_rdata,
    output wire [1:0]   a_rresp,
    output wire         a_rlast,
    output wire         a_rvalid,
    input  wire         a_rready,

    // port b: reads
    input  wire         b_arid,
    input  wire [31:0]  b_araddr,
    input  wire [7:0]   b_arlen,
    input  wire [2:0]   b_arsize,
    input  wire         b_arvalid,
    output wire         b_arready,
    output reg          b_rid = 1'b0,
    output reg  [511:0] b_rdata = 512'd0,
    output wire [1:0]   b_rresp,
    output reg          b_rlast = 1'b0,
    output reg          b_rvalid = 1'b0,
    input  wire         b_rready,
    input  wire         b_awid,
    input  wire         b_awvalid,
    output wire         b_awready,
    input  wire         b_wlast,
    input  wire         b_wvalid,
    output wire         b_wready,
    output reg          b_bid = 1'b0,
    output wire [1:0]   b_bresp,
    output reg          b_bvalid = 1'b0,
    input  wire         b_bready
);

localparam WORDS = DEPTH * BUF_BYTES / 64;
localparam AW    = $clog2(WORDS);

(* ram_style = "ultra" *) reg [511:0] mem [0:WORDS-1];

// -------------------------------------------------------------------- port a: write bursts
reg        w_act = 1'b0, n_val = 1'b0;
reg [31:0] w_addr = 32'd0, n_addr = 32'd0;
reg [2:0]  w_size = 3'd0, n_size = 3'd0;
reg        w_id = 1'b0, n_id = 1'b0;
reg [7:0]  bq = 8'd0;                            // B response ids, in order
reg [3:0]  bcnt = 4'd0;

wire w_beat = a_wvalid && a_wready;
wire w_done = w_beat && a_wlast;
wire b_pop  = a_bvalid && a_bready;
wire w_ram  = (w_addr - BASE) < WORDS * 64;      // outside the buffers: discarded

assign a_awready = !n_val;
assign a_wready  = w_act && bcnt < 4'd7;
assign a_bid     = bq[0];
assign a_bresp   = 2'b00;
assign a_bvalid  = bcnt != 4'd0;

integer i;
always @(posedge clk) begin
    if (w_beat && w_ram)
        for (i = 0; i < 64; i = i + 1)
            if (a_wstrb[i]) mem[w_addr[AW+5:6]][i*8 +: 8] <= a_wdata[i*8 +: 8];
end

always @(posedge clk) begin
    if (w_beat) w_addr <= w_addr + (32'd1 << w_size);
    if (w_done) w_act <= 1'b0;
    if (n_val && (!w_act || w_done)) begin
        w_act <= 1'b1; w_addr <= n_addr; w_size <= n_size; w_id <= n_id;
        n_val <= 1'b0;
    end
    // a new burst goes straight to the active slot when that is free, else it waits in n_*
    if (a_awvalid && a_awready) begin
        if (!w_act || w_done) begin
            w_act <= 1'b1; w_addr <= a_awaddr; w_size <= a_awsize; w_id <= a_awid;
        end else begin
            n_val <= 1'b1; n_addr <= a_awaddr; n_size <= a_awsize; n_id <= a_awid;
        end
    end
    // response queue: push on the last beat, pop on the handshake
    if (w_done && !b_pop) begin
        bq[bcnt] <= w_id; bcnt <= bcnt + 1'b1;
    end else if (!w_done && b_pop) begin
        bq <= bq >> 1; bcnt <= bcnt - 1'b1;
    end else if (w_done && b_pop) begin
        bq <= bq >> 1; bq[bcnt - 1'b1] <= w_id;
    end
    if (rst) begin
        w_act <= 1'b0; n_val <= 1'b0; bcnt <= 4'd0;
    end
end

// port a reads (unused): zeros
reg       ad_act = 1'b0;
reg [7:0] ad_left = 8'd0;
assign a_arready = !ad_act;
assign a_rvalid  = ad_act;
assign a_rdata   = 512'd0;
assign a_rresp   = 2'b00;
assign a_rlast   = ad_left == 8'd0;
always @(posedge clk) begin
    if (a_arvalid && a_arready) begin
        ad_act <= 1'b1; ad_left <= a_arlen; a_rid <= a_arid;
    end
    if (a_rvalid && a_rready) begin
        ad_left <= ad_left - 1'b1;
        if (a_rlast) ad_act <= 1'b0;
    end
    if (rst) ad_act <= 1'b0;
end

// -------------------------------------------------------------------- port b: read bursts
// the first beat is read in the AR cycle (URAM latency 1, its output register is b_rdata);
// everything holds while R is stalled. One burst at a time: ERNIC waits for each anyway.
reg        r_act = 1'b0;                        // beats after the first still to issue
reg [31:0] r_addr = 32'd0;
reg [2:0]  r_size = 3'd0;
reg [7:0]  r_left = 8'd0;
reg        r_id = 1'b0;

wire        stall   = b_rvalid && !b_rready;
wire        start   = b_arvalid && b_arready;
wire        issue   = start || (r_act && !stall);
wire [31:0] rd_addr = start ? b_araddr : r_addr;

assign b_arready = !r_act && !stall;
assign b_rresp   = 2'b00;

always @(posedge clk) begin
    if (!stall) begin
        b_rvalid <= issue;
        if (issue) begin
            b_rdata <= mem[rd_addr[AW+5:6]];
            b_rlast <= start ? b_arlen == 8'd0 : r_left == 8'd0;
            b_rid   <= start ? b_arid : r_id;
        end
    end
    if (start) begin
        r_act  <= b_arlen != 8'd0;
        r_addr <= b_araddr + (32'd1 << b_arsize);
        r_size <= b_arsize;
        r_left <= b_arlen - 1'b1;
        r_id   <= b_arid;
    end else if (issue) begin
        r_addr <= r_addr + (32'd1 << r_size);
        r_left <= r_left - 1'b1;
        if (r_left == 8'd0) r_act <= 1'b0;
    end
    if (rst) begin
        r_act <= 1'b0; b_rvalid <= 1'b0;
    end
end

// port b writes (unused): discarded
reg bd_act = 1'b0;
assign b_awready = !bd_act && !b_bvalid;
assign b_wready  = bd_act;
assign b_bresp   = 2'b00;
always @(posedge clk) begin
    if (b_awvalid && b_awready) begin
        bd_act <= 1'b1; b_bid <= b_awid;
    end
    if (b_wvalid && b_wready && b_wlast) begin
        bd_act <= 1'b0; b_bvalid <= 1'b1;
    end
    if (b_bvalid && b_bready) b_bvalid <= 1'b0;
    if (rst) begin
        bd_act <= 1'b0; b_bvalid <= 1'b0;
    end
end

endmodule

`resetall
