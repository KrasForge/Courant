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
synthesises `top_resonator` for a chosen part and mesh size and writes
utilisation + timing reports. [`vivado/arty_a7.xdc`](vivado/arty_a7.xdc)
constrains the 100 MHz system clock, the I2S bit clock, and the
async clock-domain crossing.

```sh
# Arty A7-35T, 2x2 mesh, 4x oversampling
vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 2 2 4
# Arty A7-100T, 3x3 mesh
vivado -mode batch -source build_arty.tcl -tclargs xc7a100tcsg324-1 3 3 4
```

This produces `util_<tag>.rpt` and `timing_<tag>.rpt`.
