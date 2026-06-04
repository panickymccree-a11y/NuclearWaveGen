# AD9747 Dual-Port Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the physical top for AD9747 dual-port output using two independent 250 MSPS DAC channels, each generated as two 125 MHz samples per core cycle and emitted on a 16-bit LVCMOS25 bus.

**Architecture:** Keep the existing event generation pipeline and add a static-configuration path so physical hardware can run without the old external cfg bus. Instantiate two independent channel wrappers at 125 MHz, then bridge their 2-sample-per-cycle outputs into a 250 MHz LVCMOS output register stage. Use `clk_wiz_0` from the existing Vivado IP to generate 125 MHz and 250 MHz from the R4 50 MHz input.

**Tech Stack:** Verilog RTL, Vivado 2020.2 clock wizard IP, Xilinx 7-series `OBUFDS`, ModelSim functional simulation.

---

### Task 1: Static Checks

**Files:**
- Create: `sim/check_ad9747_top.ps1`

- [ ] **Step 1: Write the failing static check**

Create a PowerShell check that asserts:
- `nuc_event_gen_10mcps_io_top` exposes only `clk_50m`, `rst_n`, `dac_clk_p`, `dac_clk_n`, `dac1_data[15:0]`, `dac2_data[15:0]`.
- The physical top instantiates `clk_wiz_0`, two `nuc_event_gen_dac_channel` instances, and one `dac_2x_output_serializer`.
- `rtl/filelist.f` contains the new channel and serializer files.
- XDC assigns R4 to `clk_50m`, R18 to `rst_n`, K18/K19 to `dac_clk_p/n`, and uses `LVCMOS25` for both data buses.

- [ ] **Step 2: Run check to verify it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File sim/check_ad9747_top.ps1`

Expected: FAIL because the new top ports and modules do not exist yet.

### Task 2: Static Core Configuration

**Files:**
- Modify: `rtl/rng_bank_10mcps.v`
- Modify: `rtl/nuc_event_gen_10mcps_top.v`

- [ ] **Step 1: Extend `rng_bank_10mcps`**

Add `SEED_SALT` parameter and XOR it into all default RNG seeds so two channel instances can be decorrelated without runtime seed writes.

- [ ] **Step 2: Add static config mode to `nuc_event_gen_10mcps_top`**

Add `STATIC_CONFIG` and static value parameters. When enabled, bypass `cfg_regfile_10mcps` and drive `run_enable`, `rate_threshold_q32`, amplitude, decay, output shift, baseline, noise, and seed wires from parameters.

- [ ] **Step 3: Run ModelSim compile**

Run: `vsim -c -do _run_func_sim.do` from `sim`.

Expected: compile/elaboration succeeds for the existing testbench with `STATIC_CONFIG=0`.

### Task 3: Channel and Serializer Modules

**Files:**
- Create: `rtl/nuc_event_gen_dac_channel.v`
- Create: `rtl/dac_2x_output_serializer.v`
- Modify: `rtl/filelist.f`

- [ ] **Step 1: Create `nuc_event_gen_dac_channel`**

Wrap `nuc_event_gen_10mcps_top` with `STATIC_CONFIG=1`, `SAMPLES_PER_CLK=2`, `CORE_CLK_HZ=125000000`, no external cfg or LUT write ports, and output a 2-sample vector plus a toggle.

- [ ] **Step 2: Create `dac_2x_output_serializer`**

In the 250 MHz domain, detect the 125 MHz pair toggle, latch both channels' two-sample vectors after they are stable, and output lane 0 then lane 1 on each 16-bit DAC bus.

- [ ] **Step 3: Update file list**

Add the two new RTL files before `nuc_event_gen_10mcps_io_top.v`.

### Task 4: Physical Top and XDC

**Files:**
- Modify: `rtl/nuc_event_gen_10mcps_io_top.v`
- Modify: `prj/nuc_event_gen_10mcps_io.xdc`

- [ ] **Step 1: Rewrite physical top ports**

Expose only `clk_50m`, `rst_n`, `dac_clk_p`, `dac_clk_n`, `dac1_data[15:0]`, and `dac2_data[15:0]`.

- [ ] **Step 2: Instantiate clocks and outputs**

Instantiate `clk_wiz_0`, synchronize reset into 125 MHz and 250 MHz domains, instantiate two channel modules, instantiate serializer, and drive `dac_clk_p/n` through `OBUFDS` for synthesis with a simulation fallback.

- [ ] **Step 3: Rewrite XDC**

Use R4 LVCMOS33 for `clk_50m`, R18 LVCMOS33 for `rst_n`, K18/K19 LVDS_25 for DAC clock, and automatically allocated bank15/bank16 LVCMOS25 pins for `dac1_data`/`dac2_data`.

### Task 5: Simulation

**Files:**
- Create: `sim/clk_wiz_0_model.v`
- Modify: `sim/tb_nuc_event_gen_10mcps.v`
- Modify: `sim/_run_func_sim.do`
- Modify: `sim/run_sim.do`

- [ ] **Step 1: Add simulation clock wizard model**

Create a simple `clk_wiz_0` simulation model that generates 125 MHz and 250 MHz clocks and asserts `locked` after reset.

- [ ] **Step 2: Update testbench for new physical ports**

Drive `clk_50m` and `rst_n`, observe `dac1_data`, `dac2_data`, and `dac_clk_p/n`, and run long enough to confirm nonzero activity.

- [ ] **Step 3: Update ModelSim scripts**

Compile with `+define+SIMULATION`, include `clk_wiz_0_model.v`, and include new RTL files.

- [ ] **Step 4: Run verification**

Run:
- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/check_ad9747_top.ps1`
- `vsim -c -do _run_func_sim.do`

Expected: static check passes, ModelSim compile and run finish with zero errors.
