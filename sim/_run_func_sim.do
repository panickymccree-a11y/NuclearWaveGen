vlib work
vmap work work
vlog -work work -sv +acc +define+SIMULATION multi_threshold_model.v
vlog -work work -sv +acc +define+SIMULATION clk_wiz_0_model.v
vlog -work work -sv +acc +define+SIMULATION ../rtl/rng_xorshift64.v ../rtl/rng_bank_10mcps.v ../rtl/amp_lut_single_port.v ../rtl/amp_lut_dual_read_port.v ../rtl/amp_lut_multiport.v ../rtl/cfg_regfile_10mcps.v ../rtl/poisson_time_bernoulli.v ../rtl/poisson_time_multievent.v ../rtl/event_counters_10mcps.v ../rtl/amplitude_sampler_icdf.v ../rtl/exp_decay_core.v ../rtl/exp_decay_bi_core.v ../rtl/noise_baseline_core.v ../rtl/mixer_saturator_simple.v ../rtl/nuc_event_gen_10mcps_top.v ../rtl/nuc_event_gen_dac_channel.v ../rtl/dac_2x_output_serializer.v ../rtl/nuc_event_gen_10mcps_io_top.v
vlog -work work -sv +acc +define+SIMULATION tb_nuc_event_gen_10mcps.v
vsim -voptargs=+acc -c work.tb_nuc_event_gen_10mcps
run -all
quit -f
