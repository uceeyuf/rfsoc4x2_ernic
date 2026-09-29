# Synthesize, implement and write the bitstream: build/ernic.bit, build/ernic.ltx
#   vivado -mode batch -source scripts/build.tcl [-tclargs <jobs>]
set repo_root [file normalize [file join [file dirname [info script]] ..]]
set xpr  [file join $repo_root build rfsoc4x2_ernic rfsoc4x2_ernic.xpr]
set jobs [expr {$argc > 0 ? [lindex $argv 0] : 8}]
if {![file exists $xpr]} { source [file join $repo_root scripts create_project.tcl] } else { open_project $xpr }

set synth [get_runs synth_1]
if {[get_property PROGRESS $synth] ne "100%" || [get_property NEEDS_REFRESH $synth]} {
    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    if {[get_property PROGRESS $synth] ne "100%"} { error "synth_1 failed" }
}
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "impl_1 failed" }

open_run impl_1
report_timing_summary -file [file join $repo_root build timing_summary.rpt]
report_utilization    -file [file join $repo_root build utilization.rpt]
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
file copy -force [file join $impl_dir ernic_top.bit] [file join $repo_root build ernic.bit]
file copy -force [file join $impl_dir ernic_top.ltx] [file join $repo_root build ernic.ltx]
puts "Bitstream: [file join $repo_root build ernic.bit]"
