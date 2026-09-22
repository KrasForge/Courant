# Resource budget (Arty A7 / Artix-7)

Synthesis resource budget for the fully-spatial mesh and the case for
time-multiplexing (README §3 "Parallel vs. time-multiplexed", §6 target board).
Numbers below use the open-source Yosys `synth_xilinx -family xc7` flow. The
historical tables came from [`syn/yosys/report_util.sh`](../syn/yosys/report_util.sh);
post-#86 snapshots explicitly use GHDL 6.0 built-in VHDL->Verilog synthesis into
Yosys 0.68. Reproduce physical sign-off numbers with Vivado
([`syn/vivado/`](../syn/vivado/)).

## Per-node cost (measured)

One `node_element` (the 4-stage non-linear Q1.23 PE) maps to:

| Primitive | Count |
| --- | --- |
| DSP48E1 | **18** |
| Flip-flops (FDRE) | 480 |
| LUTs (LUT1..6) | 1,911 |
| CARRY4 | 391 |

The mesh scales linearly: `grid_mesh` at `NX*NY` nodes uses `NX*NY` PEs plus
negligible glue. At 8x8 (64 nodes), the current refined standalone-PE mapping implies
1152 DSP, ~30.7k FF and ~122.3k LUT before wrapper glue. (A zero-control/legacy build can trim much of the physical-control mux logic, but the fully dynamic figure is the conservative one.) The full `top_resonator`
(I2S + CDC + control bus + decimation around an 8x8 OS=4 mesh) adds **no extra
DSP** (the `1/OS` decimation average folds to a shift) and only ~600 FF /
~500 LUT of I/O and control glue.

### Refined musical physical model

The playable `MUSICAL_VOICES` path now combines curvature/velocity loss with runtime MATERIAL, signed X/Y anisotropy, **STIFFNESS / plate dispersion**, **HARDNESS / stateful physical-mallet contact**, explicit exciter modes, and quarter-cell strike/pickup geometry. The legacy/reference zero-control path remains bit-exact. Directional bias, fractional interpolation, the `mu2*Biharm` stiffness scale, and the mallet contact law are shift/add logic; the fundamental DSP multiplier count is unchanged.

With the runtime physical controls present, standalone XC7 mapping of the current `node_element` is **18 DSP / 1,911 LUT1..6 / 480 FF**. STIFFNESS therefore adds wider shift/add/control logic but no additional DSP multiplier at the PE level.

For the actual 8x8 time-multiplexed mesh after #86, current GHDL 6 built-in synthesis -> Yosys 0.68 XC7 mapping is **18 DSP, 28,575 LUT1..6, 3,615 FF**. This includes the 27-bit per-node curvature history, runtime STIFFNESS/MATERIAL/ANISO, compliant RIM, full-grid quarter-cell STRIKE X/Y, four strike-footprint bands, and fractional stereo pickups. The open-source LUT estimate rises because the wider stencil exposes more multi-read state muxing; the four TDM gather states deliberately limit the extra concurrent plate reads to two per clock.

As a DSP planning bound for the XC7A50T, four such TDM grids account for 72 DSP and the current FX chain accounts for 23, leaving 25 of the device's 120 DSPs for the polyphonic mixer/front-end/glue. The complete four-voice `TIME_MUX=true` `synth_top` synthesizes successfully through GHDL; final LUT packing and timing still require the Vivado A50T implementation because the open-source flow pessimistically expands the TDM memories.

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

## Time-multiplexed: the production architecture

The current `grid_mesh_tdm` folds an entire voice through one shared arithmetic
path, so its DSP count is **18 independent of grid size**. Grid size instead
consumes state storage/read muxing and cycle budget.

At STIFFNESS=0 the 8x8 raster keeps the legacy one-node-per-clock update. For a
stiff surface, the 13-point operator needs eight additional taps; four gather
states read two taps per clock before each node update rather than creating eight
additional simultaneous state-memory read ports. `stiffness_tb` measures
**322 clocks per 8x8 mesh step** when STIFFNESS is nonzero. At OS=4 that is 1288
mesh clocks/frame before small sequencer overhead, still below the ~2083 clocks
available at 100 MHz / 48 kHz.

Thus time multiplexing still removes the O(N^2) DSP blow-up, but grid size is
not free: larger grids, higher OS, and nonzero stiffness must be checked against
[`timing_budget.md`](timing_budget.md). The fully spatial and TDM backends
remain synthesis-time choices through the same `mesh` wrapper.

## The playable synth (synth_top) vs. part (issue #77)

The Arty tables immediately below are retained as historical planning data. The current custom-board configuration is measured separately after them with the repaired musical path, four refined time-mux voices, complete onboard FX, and the shared crossfade multiplier.

Measured utilisation of the full playable design `synth_top` (MIDI ->
polyphony -> I2S, incl. `midi_frontend` / `preset_bank` / `i2s_*` / CDC glue) at
the default 8x8 mesh, OS=4, from the yosys flow (flattened, so the counts are
aggregate primitives, not just the wrapper):

### Time-multiplexed voices (`TIME_MUX=true`)

| Voices | DSP48E1 | LUT | FF |
| --- | --- | --- | --- |
| 1 | 24 | 8.6k | 4.9k |
| 2 | 38 | 15.6k | 8.3k |
| 4 | 74 | 30.4k | 15.1k |
| 8 | 146 | 61.6k | 28.7k |

The trend is **~18 DSP per voice + ~6 DSP of glue** (`DSP ~= 6 + 18*NVOICES`);
LUT/FF add ~7.3k / ~3.4k per voice on ~1.3k / ~1.5k of glue.

### Fully-spatial (`TIME_MUX=false`)

A single spatial 8x8 voice is **1158 DSP** (LUT 39k, FF 17k), so **spatial
polyphony does not fit any Arty** (35T: 90 DSP, 100T: 240). Time-multiplexing is
mandatory for a playable voice count, as issues #24/#29 anticipated.

### Which part, how many voices

| Part | DSP (90/240) | LUT (20.8k/63.4k) | Voices (DSP) | Voices (yosys LUT) |
| --- | --- | --- | --- | --- |
| Arty A7-35T (XC7A35T) | 90 | 20.8k | **4** (74 DSP) | ~2 (15.6k) |
| Arty A7-100T (XC7A100T) | 240 | 63.4k | **~12** (~222) | ~8 (61.6k) |

DSP scales cleanly and says **4 voices on the 35T, ~12 on the 100T**. FF is never
close. The tension is **LUT**, which in yosys binds sooner (~2 voices on the 35T,
~8 on the 100T).

### Caveat: the LUT figure is yosys-pessimistic for time-mux

The LUT count is a conservative upper bound, not the Vivado number.
`grid_mesh_tdm` uses multi-read asynchronous grid state, which GHDL/Yosys expands
into large LUT mux trees instead of the compact distributed-memory structures a
direct Xilinx flow can infer. DSP is therefore the reliable open-source planning
number; LUT/timing must be confirmed by Vivado (`build_synth.tcl`).

### Physical mallet / HARDNESS (#87)

The stateful physical mallet was implemented without DSP multipliers because the
four-voice board already has very little DSP headroom. `physical_mallet.vhd`
uses a leading-bit/shift approximation to compression squared and static
shift/add HARDNESS scaling.

Standalone GHDL 6 -> Yosys 0.68 XC7 mapping:

| Resource | `physical_mallet` |
| --- | ---: |
| DSP48E1 | **0** |
| LUT1..6 | **1,280** |
| FF (FDRE) | **61** |
| CARRY4 | **173** |

There is one mallet state machine per voice. It adds no BRAM and does not add a
mesh sweep state: spatial contact reads the current strike-point interpolation,
while TDM captures those four contact corners during the normal raster. The
binding DSP budget is therefore unchanged by HARDNESS.

### Current custom-board configuration: XC7A50T, four refined voices

The finished `NVOICES=4`, `NX=NY=8`, `OS=4`, `TIME_MUX=true` `synth_top` was
synthesized through GHDL and mapped with Yosys `synth_xilinx -family xc7` after
all 2026-09-18 refinements:

| Resource | Current full top |
| --- | ---: |
| DSP48E1 | **116 / 120 (96.7%)** |
| LUT1..6 | **132,279** *(known Yosys overestimate for multi-read TDM memories; wider #86 stencil magnifies it)* |
| FF (FDRE/FDRE_1/FDSE) | **20,547** |
| RAMB36E1 | **28** |
| RAMB18E1 | **6** |

This `synth_top` figure includes four runtime-STIFFNESS/HARDNESS-capable 18-DSP TDM voices, shared voice-fade path, automatic MIDI/CV arbitration and the complete 23-DSP FX chain. #86/#87 therefore leave the binding DSP count at **116 / 120** and BRAM at 28 RAMB36 + 6 RAMB18. The physical board wrapper also instantiates `panel_ctrl`; its PLAY/EDIT controller maps separately to about **1 DSP**, so board-level DSP planning remains approximately **117 / 120 (97.5%)**, before Vivado optimization/sharing. The open-source LUT number is not a board-fit verdict: the widened 13-point stencil exposes more of the known asynchronous multi-read TDM state as LUT mux trees. **Vivado place/route is mandatory sign-off** given both that pessimism and the small remaining DSP margin.

## Onboard stereo FX chain (2026-09-18)

The current post-mesh `fx_chain` includes drive, tone, BRAM chorus, ping-pong
delay, modulated eight-line FDN, sample-rate parameter smoothing / click-free
master crossfade, optional BPM/division delay timing, and the `POLISH` mastering
bus. Legacy raw delay timing remains compatible. The tempo conversion uses two
128x16 elaboration ROMs; no runtime divider is present.

Current standalone GHDL -> Verilog -> Yosys `synth_xilinx -family xc7` mapping:

| FX chain resource | Standalone count |
| --- | ---: |
| DSP48E1 | **23** |
| RAMB36E1 | **28** |
| RAMB18E1 | **6** |
| LUTs (LUT2..6) | **12,011** |
| FFs (FDRE+FDSE) | **2,072** |

BRAM use is unchanged from the earlier chorus/delay/FDN implementation. The
slow FDN line modulation reuses the existing eight memories and the tempo-grid
feature uses small ROMs rather than another audio delay. The refined
`fx_master_bus` alone maps to **1 DSP48E1, 3,141 LUT2..6, 359 FDRE + 1 FDSE,
and no BRAM**; its EQ/width filters are shift-add and one multiplier is shared
between left/right compressor gain operations.

The complete FX chain remains **23 DSPs**. The current `synth_top`, including runtime bending STIFFNESS and stateful HARDNESS contact, maps to **116/120 DSPs** and the separate PLAY/EDIT `panel_ctrl` maps to **1 DSP**, giving an approximately **117/120** board-level planning total. **Vivado place/route remains the hardware sign-off** because the margin is small and GHDL/Yosys expands the multi-read TDM grid memories pessimistically. No PCB, clock, ADC, connector, pot, or panel signal was added.

## Reproducing

```sh
cd syn/yosys && ./report_util.sh                # open-source estimate (these tables)
# sweep synth_top configs by editing the -gTIME_MUX / -gNVOICES generics there
cd syn/vivado && vivado -mode batch -source build_arty.tcl  -tclargs xc7a35ticsg324-1L 2 2 4
cd syn/vivado && vivado -mode batch -source build_synth.tcl -tclargs xc7a35ticsg324-1L 4 8 8 4 true
```
