# Create the Vivado project (Vivado 2023.2; the ERNIC and CMAC need licenses).
#   vivado -mode batch -source scripts/create_project.tcl
set repo_dir [file normalize [file join [file dirname [info script]] ..]]
set proj_dir [file join $repo_dir build rfsoc4x2_ernic]
create_project rfsoc4x2_ernic $proj_dir -part xczu48dr-ffvg1517-2-e -force
set_property target_language Verilog [current_project]

set ve [file join $repo_dir third_party verilog-ethernet]
add_files -norecurse -fileset sources_1 [concat [glob [file join $repo_dir rtl *.v]] \
    [file join $ve lib axis rtl axis_fifo.v] [file join $ve lib axis rtl axis_async_fifo.v] \
    [file join $ve lib axis rtl axis_arb_mux.v] [file join $ve lib axis rtl arbiter.v] \
    [file join $ve lib axis rtl priority_encoder.v] \
    [file join $ve lib axis rtl sync_reset.v]]

import_ip [file join $repo_dir ip ddr4_0 ddr4_0.xci]
upgrade_ip -quiet [get_ips ddr4_0]
set_property CONFIG.C0.DDR4_AxiNarrowBurst {true} [get_ips ddr4_0]
foreach t {cmac_usplus_0 ernic_0 axi_ic_0 jtag_axi vio_0} { source [file join $repo_dir ip $t.tcl] }
set_property top ernic_top [get_filesets sources_1]

add_files -norecurse -fileset constrs_1 [list [file join $repo_dir constraints fpga.xdc] \
    [file join $repo_dir constraints 4x2_PL_DDR4.xdc]]
set_property target_constrs_file [file join $repo_dir constraints fpga.xdc] [get_filesets constrs_1]
foreach t {sync_reset.tcl axis_async_fifo.tcl} {
    set f [file join $ve lib axis syn vivado $t]
    add_files -norecurse -fileset constrs_1 $f
    set_property file_type TCL [get_files $f]
    set_property used_in_synthesis false [get_files $f]
    set_property processing_order LATE [get_files $f]
}

set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
update_compile_order -fileset sources_1
generate_target all [get_ips]
puts "Project created: [file join $proj_dir rfsoc4x2_ernic.xpr]"
