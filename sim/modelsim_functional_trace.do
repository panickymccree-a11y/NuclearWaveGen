onerror {quit -code 1}

file mkdir sim_out

if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

vlog -work work \
    ./rtl/rng_xorshift64.v \
    ./rtl/rng_bank_10mcps.v \
    ./rtl/poisson_time_multievent.v \
    ./rtl/amp_lut_single_port.v \
    ./rtl/amp_lut_multiport.v \
    ./rtl/amplitude_sampler_icdf.v \
    ./rtl/exp_decay_core.v \
    ./rtl/noise_baseline_core.v \
    ./rtl/mixer_saturator_simple.v \
    ./rtl/event_counters_10mcps.v \
    ./rtl/cfg_regfile_10mcps.v \
    ./rtl/nuc_event_gen_10mcps_top.v \
    ./sim/tb_nuc_event_gen_10mcps.v

vsim -voptargs=+acc work.tb_nuc_event_gen_10mcps

vcd file sim_out/functional_io_trace.vcd

# Testbench/top-level final I/O.
vcd add /tb_nuc_event_gen_10mcps/clk
vcd add /tb_nuc_event_gen_10mcps/rst_n
vcd add /tb_nuc_event_gen_10mcps/cfg_valid
vcd add /tb_nuc_event_gen_10mcps/cfg_write
vcd add /tb_nuc_event_gen_10mcps/cfg_addr
vcd add /tb_nuc_event_gen_10mcps/cfg_wdata
vcd add /tb_nuc_event_gen_10mcps/cfg_rdata
vcd add /tb_nuc_event_gen_10mcps/cfg_ready
vcd add /tb_nuc_event_gen_10mcps/amp_lut_we
vcd add /tb_nuc_event_gen_10mcps/amp_lut_addr
vcd add /tb_nuc_event_gen_10mcps/amp_lut_wdata
vcd add /tb_nuc_event_gen_10mcps/dac_sample_vec
vcd add /tb_nuc_event_gen_10mcps/dac_lane0
vcd add /tb_nuc_event_gen_10mcps/dac_lane1
vcd add /tb_nuc_event_gen_10mcps/dac_sample_analog
vcd add /tb_nuc_event_gen_10mcps/pulse_lane0
vcd add /tb_nuc_event_gen_10mcps/pulse_lane1
vcd add /tb_nuc_event_gen_10mcps/pulse_sample_analog
vcd add /tb_nuc_event_gen_10mcps/event_count_lane0
vcd add /tb_nuc_event_gen_10mcps/event_count_lane1
vcd add /tb_nuc_event_gen_10mcps/impulse_count_lane0
vcd add /tb_nuc_event_gen_10mcps/impulse_count_lane1
vcd add /tb_nuc_event_gen_10mcps/impulse_sum_lane0
vcd add /tb_nuc_event_gen_10mcps/impulse_sum_lane1
vcd add /tb_nuc_event_gen_10mcps/noise_lane0
vcd add /tb_nuc_event_gen_10mcps/noise_lane1
vcd add /tb_nuc_event_gen_10mcps/dac_sample_valid
vcd add /tb_nuc_event_gen_10mcps/event_valid_vec
vcd add /tb_nuc_event_gen_10mcps/impulse_valid_vec
vcd add /tb_nuc_event_gen_10mcps/saturation_vec
vcd add /tb_nuc_event_gen_10mcps/status_word
vcd add /tb_nuc_event_gen_10mcps/sample_lo_live
vcd add /tb_nuc_event_gen_10mcps/sample_hi_live
vcd add /tb_nuc_event_gen_10mcps/cand_lo_live
vcd add /tb_nuc_event_gen_10mcps/cand_hi_live
vcd add /tb_nuc_event_gen_10mcps/emit_lo_live
vcd add /tb_nuc_event_gen_10mcps/emit_hi_live
vcd add /tb_nuc_event_gen_10mcps/sat_lo_live
vcd add /tb_nuc_event_gen_10mcps/sat_hi_live
vcd add /tb_nuc_event_gen_10mcps/observed_occupied_lanes
vcd add /tb_nuc_event_gen_10mcps/observed_multi_event_lanes
vcd add /tb_nuc_event_gen_10mcps/observed_event_total

# Intermediate module input/output scopes.
vcd add /tb_nuc_event_gen_10mcps/dut/u_cfg/*
vcd add /tb_nuc_event_gen_10mcps/dut/u_rng/*
vcd add /tb_nuc_event_gen_10mcps/dut/u_timebase/*
vcd add /tb_nuc_event_gen_10mcps/dut/u_amp_lut/clk
vcd add /tb_nuc_event_gen_10mcps/dut/u_amp_lut/wr_en
vcd add /tb_nuc_event_gen_10mcps/dut/u_amp_lut/wr_addr
vcd add /tb_nuc_event_gen_10mcps/dut/u_amp_lut/wr_data
vcd add /tb_nuc_event_gen_10mcps/dut/u_amp_lut/rd_addr_vec
vcd add /tb_nuc_event_gen_10mcps/dut/u_amp_lut/rd_data_vec
vcd add /tb_nuc_event_gen_10mcps/dut/u_amp_sampler/*
vcd add /tb_nuc_event_gen_10mcps/dut/u_decay/*
vcd add /tb_nuc_event_gen_10mcps/dut/u_noise/*
vcd add /tb_nuc_event_gen_10mcps/dut/u_mixer/*
vcd add /tb_nuc_event_gen_10mcps/dut/u_counters/*

run -all
vcd flush

quit -f
