# syn/ - synthesis flows

Two reproducible synthesis flows for the resonator, targeting the Digilent
Arty A7 (Xilinx Artix-7). Results and the resource budget are in
[`docs/resource_budget.md`](../docs/resource_budget.md).

## yosys (open source, no licence)

[`yosys/report_util.sh`](yosys/report_util.sh) maps the RTL onto Xilinx
7-series primitives (DSP48E1 / LUT / FF) and prints a per-unit utilisation
summary. This is the flow used to produce the numbers in the budget doc; it
runs anywhere.

```sh
sudo apt-get install yosys yosys-plugin-ghdl ghdl
cd syn/yosys && ./report_util.sh
```

(`grid_mesh` / `top_resonator` synthesise at the default `NX=NY=8`; DSP/LUT/FF
scale linearly with `NX*NY`.)

## Vivado (sign-off)

[`vivado/build_arty.tcl`](vivado/build_arty.tcl) is a non-project flow that
synthesises **and implements** (opt / place / route) `top_resonator` for a
chosen part and mesh size, then writes utilisation + post-route timing reports
and exits non-zero on negative slack (a pass/fail timing gate).
[`vivado/arty_a7.xdc`](vivado/arty_a7.xdc) constrains the 100 MHz system clock,
the I2S bit clock, the Pmod I2S2 audio pins, and the async clock-domain crossing
(false path + bounded bus skew on the `cdc_word` handshake). The full timing
closure rationale is in [`../docs/timing_closure.md`](../docs/timing_closure.md).

```sh
# Arty A7-35T, 2x2 mesh, 4x oversampling
vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 2 2 4
# Arty A7-100T, 3x3 mesh
vivado -mode batch -source build_arty.tcl -tclargs xc7a100tcsg324-1 3 3 4
# time-multiplexed build (one PE pool; fits larger grids)
vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 8 8 4 true
```

This produces `util_<tag>.rpt` and `timing_<tag>.rpt`.

## Building the playable synth (synth_top)

[`vivado/build_synth.tcl`](vivado/build_synth.tcl) builds the flagship playable
design, the board wrapper [`vivado/arty_synth.vhd`](vivado/arty_synth.vhd) around
`synth_top` (#68): MIDI in, polyphonic voices, I2S out. The wrapper adds an MMCM
that turns the 100 MHz oscillator into the system clock and the ~12.288 MHz audio
master clock, and maps the buttons/switches/LEDs and the Pmod I2S2 codec pins
([`vivado/arty_synth.xdc`](vivado/arty_synth.xdc)). The MMCM instantiation is a
synthesis-only Xilinx primitive, so `arty_synth.vhd` lives under `syn/` and is
not part of the (vendor-neutral) GHDL simulation flow; `synth_top` itself is
fully simulated in `src/tb/synth_top_tb.vhd`.

```sh
# Arty A7-35T, 4 voices, time-multiplexed (fits the part)
vivado -mode batch -source build_synth.tcl -tclargs xc7a35ticsg324-1L 4 8 8 4 true
# Arty A7-100T, 8 voices
vivado -mode batch -source build_synth.tcl -tclargs xc7a100tcsg324-1  8 8 8 4 true
```

Same opt/place/route + pass/fail timing gate as `build_arty.tcl`. (Quick check:
`synth_top` synthesises under the open-source yosys flow at ~19 DSP per
time-multiplexed voice; see issue #77 for the full voices-vs-part table.)
