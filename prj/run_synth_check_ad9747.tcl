set project_path "D:/Project/NuclearWaveGen/prj/NuclearWaveGen.xpr"
set rtl_dir "D:/Project/NuclearWaveGen/rtl"
set xdc_path "D:/Project/NuclearWaveGen/prj/nuc_event_gen_10mcps_io.xdc"

open_project $project_path

foreach rtl_file [list \
    "$rtl_dir/rng_xorshift64.v" \
    "$rtl_dir/rng_bank_10mcps.v" \
    "$rtl_dir/poisson_time_multievent.v" \
    "$rtl_dir/amp_lut_single_port.v" \
    "$rtl_dir/amp_lut_dual_read_port.v" \
    "$rtl_dir/amp_lut_multiport.v" \
    "$rtl_dir/amplitude_sampler_icdf.v" \
    "$rtl_dir/exp_decay_core.v" \
    "$rtl_dir/exp_decay_bi_core.v" \
    "$rtl_dir/noise_baseline_core.v" \
    "$rtl_dir/mixer_saturator_simple.v" \
    "$rtl_dir/event_counters_10mcps.v" \
    "$rtl_dir/cfg_regfile_10mcps.v" \
    "$rtl_dir/nuc_event_gen_10mcps_top.v" \
    "$rtl_dir/nuc_event_gen_dac_channel.v" \
    "$rtl_dir/dac_2x_output_serializer.v" \
    "$rtl_dir/nuc_event_gen_10mcps_io_top.v" \
] {
    if {[llength [get_files -quiet $rtl_file]] == 0} {
        add_files -fileset sources_1 $rtl_file
    }
}

if {[llength [get_files -quiet $xdc_path]] == 0} {
    add_files -fileset constrs_1 $xdc_path
}

set_property top nuc_event_gen_10mcps_io_top [get_filesets sources_1]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "synth_1 did not complete: $synth_status"
}

exit
