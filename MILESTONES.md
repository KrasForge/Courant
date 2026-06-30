# Milestones

## M0: Numerical reference model & stability study
- [ ] MATLAB/Octave reference model (`model/fdtd_ref.m`)
- [ ] CFL/stability sweep with plots
- [ ] Q1.23 fixed-point quantization study (`docs/fixed_point_analysis.md`)
- [ ] Repository scaffolding: `src/`, `sim/`, `docs/` tree and GHDL CI

## M1: Node PE RTL & unit test
- [ ] `src/rtl/fdtd_pkg.vhd` — Q1.23 types and `node_update` function
- [ ] `src/rtl/node_element.vhd` — single-node processing element
- [ ] `src/tb/node_element_tb.vhd` — unit testbench; passes `make -C sim`

## M2: Full mesh and system testbench
- [ ] `src/rtl/grid_mesh.vhd` — NX×NY structural mesh with boundary wiring
- [ ] `src/tb/top_resonator_tb.vhd` — impulse-response and stability tests

## M3: I/O integration
- [ ] `src/rtl/i2s_transceiver.vhd` — I2S RX/TX + sample-strobe
- [ ] `src/rtl/top_resonator.vhd` — top-level with control bus and CDC

## M4: Board bring-up
- [ ] Synthesis for Digilent Arty A7 (Artix-7 + PMOD I2S2)
- [ ] Resource budget documented in `docs/resource_budget.md`
