# Resource budget (Arty A7 / Artix-7)

Synthesis resource budget for the fully-spatial mesh and the case for
time-multiplexing (README §3 "Parallel vs. time-multiplexed", §6 target board).
Numbers below are from the open-source yosys `synth_xilinx -family xc7` flow
([`syn/yosys/report_util.sh`](../syn/yosys/report_util.sh)); reproduce sign-off
numbers with Vivado ([`syn/vivado/`](../syn/vivado/)).

## Per-node cost (measured)

One `node_element` (the 4-stage non-linear Q1.23 PE) maps to:

| Primitive | Count |
| --- | --- |
| DSP48E1 | **18** |
| Flip-flops (FDRE) | 412 |
| LUTs (LUT2..6) | 702 |
| CARRY4 | 157 |

The mesh scales linearly: `grid_mesh` at `NX*NY` nodes uses `NX*NY` PEs plus
negligible glue. Measured 8x8 `grid_mesh` (64 nodes): 1152 DSP, 26.4k FF,
45.0k LUT - i.e. exactly 64 x the per-node cost. The full `top_resonator`
(I2S + CDC + control bus + decimation around an 8x8 OS=4 mesh) adds **no extra
DSP** (the `1/OS` decimation average folds to a shift) and only ~600 FF /
~500 LUT of I/O and control glue.

### Why 18 DSP per node

The PE has five Q1.23 multiplies (`u^2`, `alpha*u^2`, `gamma2_local*lap`,
`sigk1*u^{n-1}`, `a0*acc`). The two `q_mul` (24x24) take ~2 DSP each; the three
`mul_coeff` multiply a 24-bit coefficient by the 48-bit guard accumuland and
take ~3-4 DSP each. Narrowing the accumuland to its real range (~27 bits for the
Laplacian, ~26 for the bracket) would roughly halve the per-node DSP - a worth-
while optimisation, but the budget below uses the as-built **18 DSP/node**.

## Arty A7 capacity vs. the O(N^2) DSP ceiling

| Part | DSP48E1 | LUTs | FFs |
| --- | --- | --- | --- |
| Arty A7-35T (XC7A35T) | 90 | 20,800 | 41,600 |
| Arty A7-100T (XC7A100T) | 240 | 63,400 | 126,800 |

A fully-spatial mesh needs `18 * NX * NY` DSPs, so **DSP is the binding
resource** (LUT/FF are far from full at the DSP limit). The largest square mesh
that fits:

| Mesh | Nodes | DSP needed | Fits 35T (90)? | Fits 100T (240)? |
| --- | --- | --- | --- | --- |
| 2x2 | 4 | 72 | yes (80%) | yes |
| 3x3 | 9 | 162 | no | yes (68%) |
| 4x4 | 16 | 288 | no | no |
| 8x8 | 64 | 1152 | no (13x over) | no (5x over) |
| 16x16 | 256 | 4608 | no | no |
| 32x32 | 1024 | 18432 | no | no |

So **fully-spatial tops out at 2x2 on the A7-35T and 3x3 on the A7-100T**. Even
the largest Artix-7 (XC7A200T, 740 DSP) only reaches ~6x6. This is exactly the
`O(N^2)` DSP ceiling README §3 warns about - a musically useful mesh (16x16,
32x32) is nowhere near a fully-spatial fit.

At the 2x2 fit on the 35T: 72/90 DSP (80%), 2.8k/20.8k LUT (13%), 1.6k/41.6k FF
(4%) - comfortably DSP-bound.

## Time-multiplexed: the way to a real mesh

Folding the grid through a pool of `P` shared PEs makes the cost **independent
of mesh size**: `18 * P` DSPs. The grid is swept through the pool in
`ceil(NX*NY / P)` passes per oversampled step, which fits the per-frame cycle
budget (~2083 clocks at 100 MHz / 48 kHz; see
[`timing_budget.md`](timing_budget.md)).

| Pool P | DSP (18*P) | Fits 35T? | Sweep for 32x32 (1024 nodes) |
| --- | --- | --- | --- |
| 4 | 72 | yes | 256 passes / step |
| 8 | 144 | no (35T) / yes (100T) | 128 passes / step |
| 16 | 288 | 100T only | 64 passes / step |

A `P=4` pool fits the cheap A7-35T and can sweep a 32x32 mesh at OS=4 in roughly
`4 * 256 * (pipeline) ~ 1024` clocks/frame, well under the 2083-clock budget.
So **time-multiplexing trades latency headroom for the O(N^2) area blow-up**,
and is the route to a full-size mesh on a low-cost board. The same RTL builds
either way (`grid_mesh` is parameterisable); the choice is per-target.

## Reproducing

```sh
cd syn/yosys && ./report_util.sh                # open-source estimate (this table)
cd syn/vivado && vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 2 2 4
```
