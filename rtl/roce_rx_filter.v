// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// Pass RoCE v2 frames (IPv4, UDP destination port 4791) from the CMAC to ERNIC and drop the
// rest. The decision is taken on the first beat (the Ethernet, IPv4 and UDP headers all lie in
// its first 64 bytes); frames go through one register stage, no back-pressure (as the CMAC).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module roce_rx_filter #(
    parameter DW = 512,
    parameter KW = DW / 8
)(
    input  wire          clk,
    input  wire          rst,

    input  wire [DW-1:0] s_tdata,
    input  wire [KW-1:0] s_tkeep,
    input  wire          s_tvalid,
    input  wire          s_tlast,
    input  wire          s_tuser,

    output reg  [DW-1:0] m_tdata = {DW{1'b0}},
    output reg  [KW-1:0] m_tkeep = {KW{1'b0}},
    output reg           m_tvalid = 1'b0,
    output reg           m_tlast = 1'b0,
    output reg           m_tuser = 1'b0,

    output reg           roce_frame = 1'b0,   // one cycle per RoCE frame passed
    output reg           other_frame = 1'b0   // one cycle per frame dropped
);

function [7:0] byte_at(input [DW-1:0] d, input integer i);
    byte_at = d[i*8 +: 8];
endfunction

wire is_roce = {byte_at(s_tdata, 12), byte_at(s_tdata, 13)} == 16'h0800 &&   // IPv4
               s_tdata[14*8+4 +: 4] == 4'd4 &&
               byte_at(s_tdata, 23) == 8'd17 &&                              // UDP
               {byte_at(s_tdata, 36), byte_at(s_tdata, 37)} == 16'd4791;     // RoCE v2 (IHL 5)

reg first = 1'b1;     // the next beat starts a frame
reg keep = 1'b0;      // the frame in progress goes to ERNIC

wire pass = first ? is_roce : keep;

always @(posedge clk) begin
    roce_frame  <= 1'b0;
    other_frame <= 1'b0;
    m_tvalid    <= s_tvalid && pass;
    m_tdata     <= s_tdata;
    m_tkeep     <= s_tkeep;
    m_tlast     <= s_tlast;
    m_tuser     <= s_tuser;
    if (s_tvalid) begin
        if (first) begin
            keep <= is_roce;
            roce_frame  <= is_roce;
            other_frame <= !is_roce;
        end
        first <= s_tlast;
    end
    if (rst) begin
        first <= 1'b1;
        keep <= 1'b0;
        m_tvalid <= 1'b0;
    end
end

endmodule

`resetall
