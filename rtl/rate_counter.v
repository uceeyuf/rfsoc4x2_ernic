// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// Per-second event counter for throughput measurements: adds `inc` every clock cycle and
// latches the sum once per second (CLK_HZ cycles). `rate` is stable for a whole second, so
// it can be sampled from another clock domain (VIO) without a synchronizer.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rate_counter #(
    parameter CLK_HZ = 200000000,
    parameter INC_WIDTH = 1,
    parameter WIDTH = 32
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire [INC_WIDTH-1:0] inc,
    output reg  [WIDTH-1:0]     rate = {WIDTH{1'b0}}    // events in the last full second
);

reg [31:0]      tick = 32'd0;
reg [WIDTH-1:0] acc = {WIDTH{1'b0}};

always @(posedge clk) begin
    if (rst) begin
        tick <= 32'd0;
        acc  <= {WIDTH{1'b0}};
        rate <= {WIDTH{1'b0}};
    end else if (tick == CLK_HZ - 1) begin
        tick <= 32'd0;
        rate <= acc + inc;
        acc  <= {WIDTH{1'b0}};
    end else begin
        tick <= tick + 32'd1;
        acc  <= acc + inc;
    end
end

endmodule

`resetall
