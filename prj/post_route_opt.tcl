# Post-route optimization script
# Opens the existing impl_1 run and performs phys_opt + re-route
set project_path "D:/Project/NuclearWaveGen/prj/NuclearWaveGen.xpr"
set report_dir "D:/Project/NuclearWaveGen/prj/reports"

open_project $project_path
open_run impl_1

puts "=== Post-route physical optimization ==="
phys_opt_design -directive Explore
place_design -post_place_opt
route_design -directive Explore
phys_opt_design -directive AggressiveExplore

# Save optimized result
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
write_checkpoint -force "$impl_dir/nuc_event_gen_10mcps_io_top_routed.dcp"

puts "=== Generating timing report ==="
file mkdir $report_dir
report_timing_summary -delay_type max -max_paths 20 -file "$report_dir/impl_timing_summary.rpt"
report_utilization -file "$report_dir/impl_utilization.rpt"
report_drc -file "$report_dir/impl_drc.rpt"

puts "=== Done ==="
exit
