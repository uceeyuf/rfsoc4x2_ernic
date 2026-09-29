// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// Hardware SEND echo over the ERNIC doorbell handshake ports (QPCONFi[4] = 0). No data moves
// through this module: the send queue of QP is pre-filled with DEPTH SEND WQEs, WQE k pointing
// at receive buffer k with the fixed message length. Two pointers are forwarded:
//
//   RQ producer index (message k received into buffer k)  ->  SQ producer index (post WQE k)
//   send completions (WQE k acknowledged by the peer)      ->  RQ consumer index (free buffer k)
//
// Seen on hardware: the RQ doorbell carries the producer index (cumulative), the CQ doorbell the
// number of new completions (1 per doorbell), and the doorbell address is the low 13 bits of the
// QP's RQWPTRDBADD / CQDBADD register (tests/ernic_config.tcl sets both to end in DB_ADDR).
// The SQ PI / RQ CI doorbells take 1..DEPTH (DEPTH means 0), as in the xlnx_ernic driver. The
// values handed over are cumulative, so a newer one simply replaces one still waiting for its
// handshake.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module send_echo #(
    parameter        QP        = 2,
    parameter        DEPTH     = 16,                                 // power of two
    parameter [31:0] SQPI_ADDR = 32'h5018_0038 + QP * 32'h100,       // SQPIi register
    parameter [31:0] RQCI_ADDR = 32'h501C_0034 + QP * 32'h100        // RQCIi (handshake alias)
)(
    input  wire        clk,
    input  wire        rst,

    // ERNIC -> fabric
    input  wire [31:0] rq_db_data,
    input  wire [12:0] rq_db_addr,
    input  wire        rq_db_valid,
    output wire        rq_db_rdy,
    input  wire [31:0] cq_db_cnt,
    input  wire [12:0] cq_db_addr,
    input  wire        cq_db_valid,
    output wire        cq_db_rdy,

    // fabric -> ERNIC
    output reg  [15:0] sq_pidb = 16'd0,
    output wire [31:0] sq_pidb_addr,
    output reg         sq_pidb_valid = 1'b0,
    input  wire        sq_pidb_rdy,
    output reg  [15:0] rq_cidb = 16'd0,
    output wire [31:0] rq_cidb_addr,
    output reg         rq_cidb_valid = 1'b0,
    input  wire        rq_cidb_rdy,

    // debug, free-running
    output reg  [15:0] n_rq_db = 16'd0,        // RQ doorbells for this QP
    output reg  [15:0] n_cq_db = 16'd0,        // completion doorbells for this QP
    output reg  [15:0] n_other_db = 16'd0,     // doorbells for other QPs (ignored)
    output reg  [15:0] n_sq_pidb = 16'd0,      // SQ PI doorbells accepted by ERNIC
    output reg  [15:0] n_rq_cidb = 16'd0,      // RQ CI doorbells accepted by ERNIC
    output reg  [31:0] last_rq_db = 32'd0,     // {addr[12:0] padded to 16, data[15:0]}
    output reg  [31:0] last_cq_db = 32'd0
);

localparam LW = $clog2(DEPTH);
localparam [12:0] DB_ADDR = 13'h004;           // low bits of RQWPTRDBADD / CQDBADD of this QP

assign rq_db_rdy = 1'b1;
assign cq_db_rdy = 1'b1;
assign sq_pidb_addr = SQPI_ADDR;
assign rq_cidb_addr = RQCI_ADDR;

// index modulo DEPTH, written as 1..DEPTH
function [15:0] db_value(input [31:0] v);
    db_value = (v[LW-1:0] == 0) ? DEPTH : v[LW-1:0];
endfunction

reg [15:0] sq_next = 16'd0, rq_next = 16'd0;
reg        sq_pend = 1'b0,  rq_pend = 1'b0;
reg [LW-1:0] rq_ci = {LW{1'b0}};                // buffers freed so far, modulo DEPTH
wire [LW-1:0] rq_ci_new = rq_ci + cq_db_cnt[LW-1:0];

always @(posedge clk) begin
    // hand the newest pending value to ERNIC when the previous one is taken
    if (sq_pidb_valid && sq_pidb_rdy) begin
        sq_pidb_valid <= 1'b0;
        n_sq_pidb <= n_sq_pidb + 1'b1;
    end
    if (sq_pend && (!sq_pidb_valid || sq_pidb_rdy)) begin
        sq_pidb <= sq_next;
        sq_pidb_valid <= 1'b1;
        sq_pend <= 1'b0;
    end
    if (rq_cidb_valid && rq_cidb_rdy) begin
        rq_cidb_valid <= 1'b0;
        n_rq_cidb <= n_rq_cidb + 1'b1;
    end
    if (rq_pend && (!rq_cidb_valid || rq_cidb_rdy)) begin
        rq_cidb <= rq_next;
        rq_cidb_valid <= 1'b1;
        rq_pend <= 1'b0;
    end

    // new doorbells (rdy is always high): the last assignment wins over the hand-off above
    if (rq_db_valid) begin
        if (rq_db_addr == DB_ADDR) begin
            sq_next <= db_value(rq_db_data);
            sq_pend <= 1'b1;
            n_rq_db <= n_rq_db + 1'b1;
        end else begin
            n_other_db <= n_other_db + 1'b1;
        end
        last_rq_db <= {3'd0, rq_db_addr, rq_db_data[15:0]};
    end
    if (cq_db_valid) begin
        if (cq_db_addr == DB_ADDR) begin
            rq_ci <= rq_ci_new;
            rq_next <= db_value(rq_ci_new);
            rq_pend <= 1'b1;
            n_cq_db <= n_cq_db + 1'b1;
        end else begin
            n_other_db <= n_other_db + 1'b1;
        end
        last_cq_db <= {3'd0, cq_db_addr, cq_db_cnt[15:0]};
    end

    if (rst) begin
        sq_pidb_valid <= 1'b0;
        rq_cidb_valid <= 1'b0;
        sq_pend <= 1'b0;
        rq_pend <= 1'b0;
        rq_ci <= {LW{1'b0}};
        n_rq_db <= 16'd0;
        n_cq_db <= 16'd0;
        n_other_db <= 16'd0;
        n_sq_pidb <= 16'd0;
        n_rq_cidb <= 16'd0;
    end
end

endmodule

`resetall
