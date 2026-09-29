// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// Answer ARP requests for LOCAL_IP with LOCAL_MAC, so the host resolves the ERNIC address by
// itself (RoCE v2 uses the kernel neighbour table). An ARP request fits in the first 64-byte
// beat of a frame; the reply is one 60-byte beat (the MAC adds the FCS). One reply is held at a
// time; requests arriving while it waits are ignored (the host retries).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module arp_responder #(
    parameter DW = 512,
    parameter KW = DW / 8
)(
    input  wire          clk,
    input  wire          rst,

    input  wire [47:0]   local_mac,
    input  wire [31:0]   local_ip,

    input  wire [DW-1:0] s_tdata,
    input  wire          s_tvalid,
    input  wire          s_tlast,

    output reg  [DW-1:0] m_tdata = {DW{1'b0}},
    output wire [KW-1:0] m_tkeep,
    output reg           m_tvalid = 1'b0,
    input  wire          m_tready,
    output wire          m_tlast,

    output reg           reply_sent = 1'b0    // one cycle per reply handed over
);

assign m_tkeep = {{(KW-60){1'b0}}, {60{1'b1}}};
assign m_tlast = 1'b1;

function [7:0] b(input integer i);
    b = s_tdata[i*8 +: 8];
endfunction

wire [47:0] dst_mac = {b(0), b(1), b(2), b(3), b(4), b(5)};
wire [47:0] sha     = {b(22), b(23), b(24), b(25), b(26), b(27)};
wire [31:0] spa     = {b(28), b(29), b(30), b(31)};
wire [31:0] tpa     = {b(38), b(39), b(40), b(41)};

wire is_request = (dst_mac == 48'hFFFFFFFFFFFF || dst_mac == local_mac) &&
                  {b(12), b(13)} == 16'h0806 &&                     // ARP
                  {b(14), b(15)} == 16'h0001 && {b(16), b(17)} == 16'h0800 &&
                  b(18) == 8'd6 && b(19) == 8'd4 &&
                  {b(20), b(21)} == 16'h0001 &&                     // request
                  tpa == local_ip;

reg first = 1'b1;
integer i;

always @(posedge clk) begin
    reply_sent <= 1'b0;
    if (m_tvalid && m_tready) begin
        m_tvalid <= 1'b0;
        reply_sent <= 1'b1;
    end
    if (s_tvalid) begin
        first <= s_tlast;
        if (first && is_request && !m_tvalid) begin
            m_tdata <= {DW{1'b0}};
            for (i = 0; i < 6; i = i + 1) begin
                m_tdata[(0 + i)*8 +: 8]  <= sha[(5 - i)*8 +: 8];       // destination: the asker
                m_tdata[(6 + i)*8 +: 8]  <= local_mac[(5 - i)*8 +: 8];
                m_tdata[(22 + i)*8 +: 8] <= local_mac[(5 - i)*8 +: 8]; // sender hardware address
                m_tdata[(32 + i)*8 +: 8] <= sha[(5 - i)*8 +: 8];       // target hardware address
            end
            for (i = 0; i < 4; i = i + 1) begin
                m_tdata[(28 + i)*8 +: 8] <= local_ip[(3 - i)*8 +: 8];  // sender protocol address
                m_tdata[(38 + i)*8 +: 8] <= spa[(3 - i)*8 +: 8];       // target protocol address
            end
            m_tdata[12*8 +: 8] <= 8'h08; m_tdata[13*8 +: 8] <= 8'h06;
            m_tdata[14*8 +: 8] <= 8'h00; m_tdata[15*8 +: 8] <= 8'h01;
            m_tdata[16*8 +: 8] <= 8'h08; m_tdata[17*8 +: 8] <= 8'h00;
            m_tdata[18*8 +: 8] <= 8'd6;  m_tdata[19*8 +: 8] <= 8'd4;
            m_tdata[20*8 +: 8] <= 8'h00; m_tdata[21*8 +: 8] <= 8'h02;  // reply
            m_tvalid <= 1'b1;
        end
    end
    if (rst) begin
        first <= 1'b1;
        m_tvalid <= 1'b0;
    end
end

endmodule

`resetall
