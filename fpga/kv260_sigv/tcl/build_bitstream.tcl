set project_dir [lindex $argv 0]
if {$project_dir eq ""} {
    set project_dir [file normalize [file join [pwd] build vivado]]
}

set project_name [lindex $argv 1]
if {$project_name eq ""} {
    set project_name kv260_sigv
}

set hw_dir [lindex $argv 2]
if {$hw_dir eq ""} {
    set hw_dir [file normalize [file join [pwd] build hw]]
}

set xpr_path [file join $project_dir ${project_name}.xpr]
if {![file exists $xpr_path]} {
    error "project file not found: $xpr_path"
}

file mkdir $hw_dir
set report_dir [file join $hw_dir reports]
file mkdir $report_dir

if {[info exists ::env(KV260_SIGV_HW_MODE)] && $::env(KV260_SIGV_HW_MODE) ne ""} {
    set hw_mode [string tolower $::env(KV260_SIGV_HW_MODE)]
} else {
    set hw_mode "full"
}
if {($hw_mode ne "full") && ($hw_mode ne "bringup")} {
    error "unsupported KV260_SIGV_HW_MODE '$hw_mode'; expected 'full' or 'bringup'"
}

open_project $xpr_path

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]

reset_run synth_1
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs [exec nproc]
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {$impl_status ne "write_bitstream Complete!"} {
    error "implementation did not complete bitstream generation; impl_1 status is '$impl_status'"
}

set bit_candidates [glob -nocomplain [file join $project_dir ${project_name}.runs impl_1 *.bit]]
if {[llength $bit_candidates] != 1} {
    error "expected exactly one implemented bitstream in impl_1, found [llength $bit_candidates]"
}
set bit_path [lindex $bit_candidates 0]
if {![file exists $bit_path] || [file size $bit_path] == 0} {
    error "implemented bitstream is missing or empty: $bit_path"
}

open_run impl_1
report_utilization -hierarchical -file [file join $report_dir utilization.rpt]
report_timing_summary -max_paths 20 -routable_nets -report_unconstrained -file [file join $report_dir timing_summary.rpt]
set worst_setup_path [get_timing_paths -setup -max_paths 1 -nworst 1]
if {[llength $worst_setup_path] == 0} {
    error "unable to determine worst setup slack for implemented design"
}
set worst_hold_path [get_timing_paths -hold -max_paths 1 -nworst 1]
if {[llength $worst_hold_path] == 0} {
    error "unable to determine worst hold slack for implemented design"
}
set worst_setup_slack [get_property SLACK [lindex $worst_setup_path 0]]
set worst_hold_slack [get_property SLACK [lindex $worst_hold_path 0]]
if {($worst_setup_slack < 0.0) || ($worst_hold_slack < 0.0)} {
    error "implemented design failed timing closure: setup slack ${worst_setup_slack} ns, hold slack ${worst_hold_slack} ns"
}
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $hw_dir ${project_name}.xsa]
file copy -force $bit_path [file join $hw_dir system.bit]
file copy -force $bit_path [file join $hw_dir ${project_name}.bit]

set mode_file [open [file join $hw_dir hw_mode.txt] w]
puts $mode_file $hw_mode
close $mode_file
