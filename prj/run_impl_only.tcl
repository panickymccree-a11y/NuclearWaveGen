# ═══════════════════════════════════════════════════════════════════════════
# Vivado CLI: Implementation + Timing Check (synth already done)
# ═══════════════════════════════════════════════════════════════════════════

set project_path "D:/Project/NuclearWaveGen/prj/NuclearWaveGen.xpr"
set report_dir "D:/Project/NuclearWaveGen/prj/reports"

open_project $project_path

reset_run synth_1
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "synth_1 did not complete: [get_property STATUS [get_runs synth_1]]"
}

# ── Implementation ──
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

report_timing_summary -delay_type max -max_paths 100 -file "$report_dir/impl_timing_summary.rpt"
report_timing_summary -delay_type min_max -max_paths 10 -input_pins -routable_nets -file "$report_dir/timing_report2.txt"
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

puts "DONE. Reports written to $report_dir"
exit
