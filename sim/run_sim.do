# ModelSim simulation script for nuc_event_gen_10mcps
# Run with: vsim -c -do run_sim.do

# Create work library
file delete -force work
vlib work

# Compile RTL sources
set rtl_dir "../rtl"

vlog -work work -sv +acc \
    $rtl_dir/rng_xorshift64.v \
    $rtl_dir/rng_bank_10mcps.v \
    $rtl_dir/amp_lut_single_port.v \
    $rtl_dir/amp_lut_multiport.v \
    $rtl_dir/cfg_regfile_10mcps.v \
    $rtl_dir/poisson_time_bernoulli.v \
    $rtl_dir/poisson_time_multievent.v \
    $rtl_dir/event_counters_10mcps.v \
    $rtl_dir/amplitude_sampler_icdf.v \
    $rtl_dir/exp_decay_core.v \
    $rtl_dir/noise_baseline_core.v \
    $rtl_dir/mixer_saturator_simple.v \
    $rtl_dir/nuc_event_gen_10mcps_top.v \
    $rtl_dir/nuc_event_gen_10mcps_io_top.v

# Compile testbench
vlog -work work -sv +acc tb_nuc_event_gen_10mcps.v

# Load and run
vsim -voptargs="+acc" work.tb_nuc_event_gen_10mcps

# Log all signals for debugging
add wave -r /*

# Run for the full test duration (1M cycles @ 4ns = 4ms) + margin
run -all

# Check results
if {[batch_mode]} {
    quit -f
}
