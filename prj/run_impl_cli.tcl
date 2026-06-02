# ═══════════════════════════════════════════════════════════════════════════
# Vivado CLI: Synthesis + Implementation + Timing Check
# Run: vivado -mode batch -source run_impl_cli.tcl
# ═══════════════════════════════════════════════════════════════════════════

set project_path "D:/Project/NuclearWaveGen/prj/NuclearWaveGen.xpr"
set wrapper_path "D:/Project/NuclearWaveGen/rtl/nuc_event_gen_10mcps_io_top.v"
set xdc_path "D:/Project/NuclearWaveGen/prj/nuc_event_gen_10mcps_io.xdc"
set report_dir "D:/Project/NuclearWaveGen/prj/reports"

open_project $project_path

# Ensure latest RTL files are picked up
if {[llength [get_files -quiet $wrapper_path]] == 0} {
    add_files -fileset sources_1 $wrapper_path
}

if {[llength [get_files -quiet $xdc_path]] == 0} {
    add_files -fileset constrs_1 $xdc_path
}

set_property top nuc_event_gen_10mcps_io_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# ── Synthesis: PerformanceOptimized to push for timing ──
reset_run synth_1
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized [get_runs synth_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "synth_1 did not complete: [get_property STATUS [get_runs synth_1]]"
}

# ── Implementation: Explore for best placement/routing ──
reset_run impl_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

launch_runs impl_1 -jobs 8
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "impl_1 did not complete: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1

# ── Generate reports ──
file mkdir $report_dir

# Implementation timing summary (max 100 paths for deep analysis)
report_timing_summary -delay_type max -max_paths 100 -file "$report_dir/impl_timing_summary.rpt"
report_timing_summary -delay_type min_max -max_paths 10 -input_pins -routable_nets -file "$report_dir/timing_report2.txt"

# Clock and utilization reports
report_clock_networks -file "$report_dir/impl_clock_networks.rpt"
report_utilization -file "$report_dir/impl_utilization.rpt"
report_drc -file "$report_dir/impl_drc.rpt"

# ── Check timing convergence ──
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set ths [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
set failing [llength [get_timing_paths -max_paths 100000 -setup -slack_less_than 0.000]]
puts "========================================"
puts "  WNS (Setup):  $wns ns"
puts "  WHS (Hold) :  $ths ns"
puts "  Failing Setup Endpoints: $failing"
puts "========================================"
if {$failing > 0} {
    puts "TIMING NOT MET. $failing failing endpoints remain."
} else {
    puts "TIMING MET! All endpoints pass."
}

# Synth reports for comparison
open_run synth_1
report_utilization -file "$report_dir/synth_utilization.rpt"
report_timing_summary -delay_type max -max_paths 20 -file "$report_dir/synth_timing_summary.rpt"

puts "DONE. Reports written to $report_dir"

exit
