# Configure ERNIC over JTAG for the memory loopback or the SEND echo, then dump its state.
#
#   vivado -mode batch -source tests/ernic_config.tcl -tclargs <host params file> [program]
#   vivado -mode batch -source tests/ernic_config.tcl -tclargs status
#
# The params file comes from host/rdma_loopback (host QPN, MAC, PSN, mode); when ERNIC is
# configured the script creates "<file>.ready" and the host program connects. program = 1 loads
# build/ernic.bit.
#
# Echo mode (params "mode echo", message size "msg"): QP2 uses the doorbell handshake ports
# (QPCONF[4] = 0), which rtl/send_echo.v connects: its send queue is pre-filled with 16 SEND WQEs,
# WQE k sending receive buffer k back, so every received message is sent back without the CPU.
#
# PL DDR4 layout (ERNIC AXI addresses):
#   0x0010_0000 error buffer         0x0014_0000 response error buffer   0x0050_0000 data buffers
#   0x0020_0000 doorbells: QP i CQ doorbell at +0x10*i, RQ write pointer at +0x10*i+8
#   0x0030_0000 QP1 RQ / +0x1_0000 SQ / +0x2_0000 CQ     0x0040_0000 QP2 RQ / SQ / CQ
#   0x1000_0000 256 MB memory region (MR 0, R_Key 0x12, VA 0x1000_0000) for RDMA WRITE / READ

set repo_dir [file normalize [file join [file dirname [info script]] ..]]
set arg0 [expr {$argc > 0 ? [lindex $argv 0] : "status"}]
set prog [expr {$argc > 1 ? [lindex $argv 1] : 0}]

# ---------------------------------------------------------------- local side
set FPGA_MAC  0x020000000001
set FPGA_IP   0xC0A86401              ;# 192.168.100.1
set MR_BASE   0x10000000
set MR_LEN    0x10000000
set MR_KEY    0x12
set UDP_SPORT 0xC000
set NUM_QP    8

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xczu48dr*] 0]
current_hw_device $dev
set bitf [expr {[info exists ::env(BIT)] ? $::env(BIT) : [file join $repo_dir build ernic.bit]}]
set ltxf [file rootname $bitf].ltx
set_property PROBES.FILE $ltxf $dev
set_property FULL_PROBES.FILE $ltxf $dev
if {$prog} {
    set_property PROGRAM.FILE $bitf $dev
    program_hw_devices $dev
    after 3000
}
refresh_hw_device $dev

set LITE ""; set MEM ""
foreach a [get_hw_axis] {
    if {[string match *jtag_lite* [get_property CELL_NAME $a]]} { set LITE $a } else { set MEM $a }
}
puts "AXI masters: lite $LITE ([get_property CELL_NAME $LITE]), mem $MEM ([get_property CELL_NAME $MEM])"
set vio ""; set evio ""
foreach v [get_hw_vios -of_objects $dev] {
    if {[string match *vio_echo* [get_property CELL_NAME $v]]} { set evio $v } else { set vio $v }
}
# hold the echo engine (rtl/send_echo.v) in reset: its pointers restart with the QP
proc echo_reset {v on} {
    if {$v eq ""} { return }
    set p [get_hw_probes -of_objects $v -filter {NAME =~ *echo_rst*}]
    if {$p eq ""} { return }
    set_property OUTPUT_VALUE $on $p
    commit_hw_vio $p
}

set ::txn 0
proc wr {axi addr data} {
    set t [create_hw_axi_txn t[incr ::txn] $axi -type write -address [format %08x $addr] \
        -data [format %08x [expr {$data & 0xFFFFFFFF}]] -len 1]
    run_hw_axi -quiet $t
    delete_hw_axi_txn $t
}
proc rd {axi addr} {
    set t [create_hw_axi_txn t[incr ::txn] $axi -type read -address [format %08x $addr] -len 1]
    run_hw_axi -quiet $t
    set v [get_property DATA $t]
    delete_hw_axi_txn $t
    return [expr {"0x$v"}]
}
proc zero {axi addr words} {
    for {set i 0} {$i < $words} {incr i 64} {
        set len [expr {min(64, $words - $i)}]
        set t [create_hw_axi_txn t[incr ::txn] $axi -type write -address [format %08x [expr {$addr + 4*$i}]] \
            -data [string repeat 00000000 $len] -len $len]
        run_hw_axi -quiet $t
        delete_hw_axi_txn $t
    }
}
proc reg  {addr val} { wr $::LITE $addr $val }
# MAC / IPv4 register layout: default as the xlnx_ernic driver (MSB register = first two MAC
# bytes, IPv4 as a number); ADDR_ORDER=rev writes both byte-reversed
set REV [expr {[info exists ::env(ADDR_ORDER)] && $::env(ADDR_ORDER) eq "rev"}]
proc bswap {v n} { set r 0; for {set i 0} {$i < $n} {incr i} { set r [expr {($r << 8) | (($v >> (8*$i)) & 0xFF)}] }; return $r }
proc mac_regs {mac} {
    if {$::REV} { set mac [bswap $mac 6] }
    return [list [expr {$mac & 0xFFFFFFFF}] [expr {($mac >> 32) & 0xFFFF}]]
}
proc ip_reg {ip} { return [expr {$::REV ? [bswap $ip 4] : $ip}] }
proc qreg {qp off val} { wr $::LITE [expr {0x180000 + $qp * 0x100 + $off}] $val }   ;# QP i at 0x18_0000 + i x 0x100 (ERNIC v4.0)
proc qget {qp off} { return [rd $::LITE [expr {0x180000 + $qp * 0x100 + $off}]] }

proc dump {} {
    set g {XRNICCONF 0x100000 XRNICADCONF 0x100004 MACLSB 0x100010 MACMSB 0x100014 IPv4 0x100070 ERRBUFWPTR 0x10006C
           LSTINPKT 0x100110 LSTOUTPKT 0x100114 ININVDUP 0x100118 INALLDRP 0x100130 OUTACKMAD 0x10010C}
    foreach {n a} $g { puts [format "  %-12s 0x%08x" $n [rd $::LITE $a]] }
    foreach qp {1 2} {
        puts "  QP$qp:"
        foreach {n o} {QPCONF 0x00 SQPSN 0x40 LSTRQREQ 0x44 DESTQP 0x48 CQHEAD 0x30 SQPI 0x38 RQCI 0x34 \
                       STATSSN 0x80 STATMSN 0x84 STATQP 0x88 STATCURSQPTR 0x8C STATRESPSN 0x90 STATWQE 0x98 STATRQPIDB 0x9C} {
            puts [format "    %-13s 0x%08x" $n [qget $qp $o]]
        }
    }
}

if {$arg0 eq "status"} {
    dump
    close_hw_manager
    return
}

# ---------------------------------------------------------------- host side (from rdma_loopback)
set f [open $arg0 r]
while {[gets $f line] >= 0} {
    lassign $line k v
    set host($k) $v
}
close $f
set hmac 0x[string map {: ""} $host(mac)]
set ECHO [expr {[info exists host(mode)] && $host(mode) eq "echo"}]
set MSG  [expr {[info exists host(msg)] ? $host(msg) : 4096}]
set HOST_IP 0xC0A86402                ;# 192.168.100.2
puts [format "host: QPN %d  MAC %012x  PSN 0x%x  %s" $host(qpn) $hmac $host(psn) \
    [expr {$ECHO ? "echo, $MSG B messages" : "memory loopback"}]]

# ---------------------------------------------------------------- DDR: clear doorbells and queues
zero $MEM 0x00200000 64
zero $MEM 0x00202000 64
zero $MEM 0x00100000 128                                    ;# error buffer, first entries
foreach b {0x00310000 0x00320000 0x00410000 0x00420000} { zero $MEM $b 256 }

# ---------------------------------------------------------------- global
reg 0x100000 0                                             ;# disabled while configuring
echo_reset $evio 1
reg 0x100004 [expr {10 << 16}]                             ;# base count width for 200 MHz
reg 0x100044 [expr {$NUM_QP - 1}]                         ;# XRNIC_CONF_QP_EN: highest QP enabled (v4.0; the example writes 7 for 8 QPs)
lassign [mac_regs $FPGA_MAC] ml mh
reg 0x100010 $ml
reg 0x100014 $mh
reg 0x100070 [ip_reg $FPGA_IP]
reg 0x100060 0x00100000 ; reg 0x100064 0 ; reg 0x100068 [expr {(256 << 16) | 64}]   ;# error buffer
reg 0x1000B0 0x00140000 ; reg 0x1000B4 0 ; reg 0x1000B8 [expr {(256 << 16) | 64}]   ;# response errors
reg 0x1000A0 0x00500000 ; reg 0x1000A4 0 ; reg 0x1000A8 [expr {(4096 << 16) | 64}]  ;# data buffers
reg 0x100180 0                                             ;# no interrupts

# ---------------------------------------------------------------- memory region 0
reg 0x00 0                                                 ;# PD 0
reg 0x04 $MR_BASE ; reg 0x08 0                             ;# virtual address = physical
reg 0x0C $MR_BASE ; reg 0x10 0
reg 0x14 $MR_KEY
reg 0x18 $MR_LEN
reg 0x1C 2                                                 ;# read and write

# ---------------------------------------------------------------- QP1 (management datagrams)
set QPEN [expr {1 | (1 << 4) | (1 << 5)}]                  ;# enable, doorbells to memory, CQE writes
qreg 1 0x08 0x00300000 ; qreg 1 0x10 0x00310000 ; qreg 1 0x18 0x00320000
qreg 1 0x20 [expr {0x00200000 + 0x10 + 8}] ; qreg 1 0x28 [expr {0x00200000 + 0x10}]
qreg 1 0x3C [expr {(16 << 16) | 16}]
qreg 1 0x00 [expr {$QPEN | (1 << 16)}]                     ;# RQ buffers of 256 B

# ---------------------------------------------------------------- QP2 (RC, connected to the host)
qreg 2 0x04 [expr {(0xFFFF << 16) | (64 << 8)}]            ;# P_Key, TTL
qreg 2 0x08 0x00400000 ; qreg 2 0x10 0x00410000 ; qreg 2 0x18 0x00420000
if {$ECHO} {
    # the handshake ports carry the low 13 bits of these addresses as the doorbell address;
    # rtl/send_echo.v listens for 0x004 on both (the addresses must still differ in memory)
    qreg 2 0x20 0x00200004 ; qreg 2 0x28 0x00202004
} else {
    qreg 2 0x20 [expr {0x00200000 + 0x20 + 8}] ; qreg 2 0x28 [expr {0x00200000 + 0x20}]
}
qreg 2 0x3C [expr {(16 << 16) | 16}]
qreg 2 0x40 $host(psn)                                     ;# our SQ PSN = the host's RQ PSN
qreg 2 0x44 [expr {(($host(psn) - 1) & 0xFFFFFF) | (4 << 24)}]   ;# last received = host SQ PSN - 1
qreg 2 0x48 $host(qpn)
set RNR [expr {[info exists ::env(RNR_TIMER)] ? $::env(RNR_TIMER) : 1}]      ;# RNR NAK timer, IB code: 1 = 0.01 ms (0x1F = 491 ms stalls the echo)
qreg 2 0x4C [expr {18 | (7 << 8) | (7 << 11) | ($RNR << 16)}]     ;# timeout, retries, RNR retries, RNR timer
lassign [mac_regs $hmac] ml mh
qreg 2 0x50 $ml ; qreg 2 0x54 $mh
qreg 2 0x60 [ip_reg $HOST_IP]
qreg 2 0xB0 0                                              ;# PD 0
if {$ECHO} {
    # send WQE k: SEND of MSG bytes from receive buffer k (64 B WQE: WRID, local address,
    # length, opcode 0x02; the write data string starts with the highest-address word)
    for {set k 0} {$k < 16} {incr k} {
        set w [lrepeat 16 0]
        lset w 0 $k
        lset w 1 [expr {0x00400000 + $k * 4096}]
        lset w 3 $MSG
        lset w 4 0x02
        set d ""
        for {set i 15} {$i >= 0} {incr i -1} { append d [format %08x [lindex $w $i]] }
        set t [create_hw_axi_txn w[incr ::txn] $MEM -type write -address [format %08x [expr {0x00410000 + $k * 64}]] -data $d -len 16]
        run_hw_axi -quiet $t
        delete_hw_axi_txn $t
    }
    qreg 2 0x00 [expr {1 | (1 << 5) | (4 << 8) | (16 << 16)}]   ;# HW handshake doorbells, PMTU 4096, RQ buffers of 4 KB
} else {
    qreg 2 0x00 [expr {$QPEN | (4 << 8) | (16 << 16)}]         ;# PMTU 4096, RQ buffers of 4 KB
}

echo_reset $evio 0
reg 0x100000 [expr {1 | (1 << 5) | ($UDP_SPORT << 8)}]    ;# enable ERNIC, error buffer, UDP source port [23:8]

dump
set rf [open "$arg0.ready" w]; close $rf
puts "ERNIC configured; $arg0.ready written"

# watch the traffic for a few seconds (per-second VIO counters), then the error buffer
set names {c_mac_rx c_roce_rx c_other_rx c_mac_rx_bad c_rxq_drop c_mac_tx}
# echo engine: {RQ doorbells, CQ doorbells, SQ PI accepted, RQ CI accepted}, other QPs, last RQ / CQ
proc echo_line {v} {
    if {$v eq ""} { return "" }
    refresh_hw_vio $v
    set out ""
    foreach p [lsort [get_hw_probes -of_objects $v -filter {NAME !~ *echo_rst*}]] {
        set_property INPUT_VALUE_RADIX HEX $p
        append out " [get_property INPUT_VALUE $p]"
    }
    return "  echo$out"
}
set secs [expr {[info exists ::env(WATCH)] ? $::env(WATCH) : 3}]
for {set t 1} {$t <= $secs} {incr t} {
    after 1000
    refresh_hw_vio $vio
    set line "  t$t"
    foreach n $names {
        set p [get_hw_probes $n -of_objects $vio]
        set_property INPUT_VALUE_RADIX UNSIGNED $p
        append line "  $n [get_property INPUT_VALUE $p]"
    }
    puts $line
    if {$ECHO} { puts [echo_line $evio] }
}
dump
# the error buffer (ERRBUFWPTR does not move on this core; read the first entries directly):
# syndrome word, then the packet header
for {set e 0} {$e < 2} {incr e} {
    set t [create_hw_axi_txn e[incr ::txn] $MEM -type read -address [format %08x [expr {0x00100000 + $e * 256}]] -len 16]
    run_hw_axi -quiet $t
    set d [get_property DATA $t]
    delete_hw_axi_txn $t
    set bytes ""
    for {set k 15} {$k >= 0} {incr k -1} {
        set w [string range $d [expr {$k * 8}] [expr {$k * 8 + 7}]]
        append bytes [string range $w 6 7][string range $w 4 5][string range $w 2 3][string range $w 0 1]
    }
    set syn 0x[string range $bytes 6 7][string range $bytes 4 5][string range $bytes 2 3][string range $bytes 0 1]
    set bits {}
    for {set i 0} {$i < 32} {incr i} { if {($syn >> $i) & 1} { lappend bits $i } }
    puts "  err\[$e\]: syndrome $syn bits {$bits}  frame [string range $bytes 8 end]"
}
close_hw_manager
