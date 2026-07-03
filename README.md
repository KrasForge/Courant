# Courant

A 2D finite-difference physical-modeling synthesis engine in structural VHDL.

Instead of sampling an instrument, Courant solves the 2D acoustic wave equation
in real time on an FPGA mesh of arithmetic cells and streams the result out as
stereo audio, a vibrating drum head, plate, or sheet of metal, computed rather
than recorded. An amplitude-dependent non-linear term makes the mesh stiffen
under load, so hard hits bend pitch upward and bloom into inharmonic, metallic
partials before decaying. It is playable polyphonically over MIDI or CV, with
recallable presets.

> **Status: simulation-first, feature-complete in sim, pre-hardware.** The
> engine, a Q1.23 reference model that is *bit-exact* to the RTL, and a full
> playable top (MIDI/CV -> polyphony -> I2S) are developed and verified in GHDL
> (23 testbenches). Board bring-up (Arty A7 + Pmod I2S2) is the next step;
> nothing is claimed to work on hardware until it does.

## Why an FPGA

A 2D mesh is embarrassingly parallel: every node runs the same small update each
time step, reading only its four neighbours. That maps onto FPGA fabric, where
nodes update concurrently and the per-sample cost does not grow with grid size
the way a sequential CPU loop does. The honest trade:

| | Software (CPU / plugin) | This FPGA engine |
| --- | --- | --- |
| **Grid scaling** | cost grows per node | concurrent; one mesh step per sample, up to the DSP/LUT budget |
| **Latency** | host audio buffer (~0.7-6 ms) | deterministic, sub-sample; no block buffering |
| **Per-node non-linearity** | often dropped to save CPU | evaluated every node, every step |
| **Iteration / cost** | recompile in seconds; runs on hardware you own | re-synthesis (minutes); needs an FPGA + codec |

FPGAs win on deterministic parallelism and latency; software wins on flexibility
and cost. This project is about the former.

## The model

A lossy 2D wave equation for the surface displacement `u(x,y,t)`, discretised
with centred finite differences (spacing `h`, time step `k = 1/f_s`):

$$u_{i,j}^{n+1} = a_0\left[\,2u_{i,j}^{n} - \mathrm{sigk1}\,u_{i,j}^{n-1} + \gamma^2\left(u_{i+1,j}^{n} + u_{i-1,j}^{n} + u_{i,j+1}^{n} + u_{i,j-1}^{n} - 4u_{i,j}^{n}\right)\right]$$

where `gamma = ck/h` is the **Courant number**, `a0 = 1/(1+sigma*k)` and
`sigk1 = 1-sigma*k` are precomputed damping coefficients (no per-node division),
and the Laplacian stencil is the only inter-node coupling. `c` sets pitch,
`sigma` sets decay.

**Stability is the whole game.** The explicit scheme is stable only for
`gamma^2 <= 1/2`; cross that line and it diverges exponentially.

### The non-linear twist

Courant makes the local Courant term amplitude-dependent, so the mesh stiffens
where it moves hardest:

$$\gamma_{i,j}^2 = \gamma_0^2 + \alpha\,(u_{i,j}^{n})^2$$

This is the "tension modulation" of struck plates and gongs (pitch glide,
inharmonic bloom, genuine routes into chaos). But `alpha*u^2` only *raises*
`gamma^2`, hardest exactly when the sound is loudest, pushing toward the CFL
cliff. Output saturation alone does not save you (the state pins to the rails and
buzzes at Nyquist). The structural fix, treated as first-class here:

1. **Clamp the local term** to `gamma2_max < 1/2` (a CFL safety margin), bounding
   the instability into a rich but convergent limit-cycle regime.
2. **Saturating Q1.23 state arithmetic**, turning blow-up into musical soft-clip.
3. **Guaranteed decay** via the `sigma` damping term.

A squaring non-linearity aliases above Nyquist; the mitigation is **oversampling
+ decimation** (a documented quality/area knob), not a "zero aliasing" claim.

## Architecture

```
 MIDI / CV --> note mapping --.                     .--> I2S TX --> codec (DAC)
                              v                     |
   preset bank --> coeffs --> poly voices (N meshes + mix) --> CDC --> (audio clk)
                              ^                     |
        panel knobs/encoder --'   sample strobe <--'  (I2S word clock -> frame)
```

- **Node PE** (`node_element`): state registers `u^n`/`u^{n-1}` and a pipelined
  Q1.23 datapath (Laplacian, `alpha*u^2`, the `gamma2_local` clamp, `a0` scale)
  on DSP slices, with N/S/E/W wiring and fixed (Dirichlet) or free (Neumann)
  edges.
- **Spatial vs. time-multiplexed** (`mesh` selector): one PE per node is
  `O(N^2)` DSP and tops out fast; the time-mux mesh folds the grid through one
  PE (~18 DSP/voice, independent of grid size). Same RTL, a synthesis-time
  choice, this is what makes polyphony fit a small part.
- **Playability**: MIDI and CV front-ends map note/velocity (or 1V/oct + gate +
  mod) to pitch/strike/timbre; `poly_voices` allocates voices and mixes them;
  `preset_bank` recalls instrument setups; `panel_ctrl` maps knobs/encoder to
  the engine.
- **`synth_top` / `arty_synth`**: the flashable design tying it together, FPGA
  as I2S master.

## What's here

```text
src/rtl/   engine (node/mesh/nonlinear, time-mux), I2S + CDC + master clocks,
           preset bank, MIDI + CV front-ends, polyphony, panel, synth_top
src/tb/    23 GHDL testbenches (unit -> bit-exact golden -> end-to-end audio)
model/     MATLAB/Octave reference model (bit-exact to the RTL) + studies + demos
sim/       GHDL Makefile (`make -C sim` runs the whole suite)
syn/       yosys (open-source estimate) + Vivado (sign-off) flows for the Arty A7
docs/      derivations, fixed-point + CFL analysis, resource budget, per-feature notes
```

## Build & simulate

Open-source flow, GHDL (VHDL-2008):

```sh
make -C sim                      # analyse + run all testbenches
octave-cli --eval "demo_render"  # render nonlinear polyphonic demo audio (model/)
cd syn/yosys && ./report_util.sh # DSP/LUT/FF resource estimate
```

Synthesis targets a **Digilent Arty A7** (Artix-7) + **Pmod I2S2** codec. A
4-voice time-multiplexed build fits the low-cost A7-35T (~18 DSP/voice); see
`docs/resource_budget.md`.

## What this is and is not

- It **is** a deterministic, low-latency, parallel physical-modeling engine and
  an honest study of non-linear FDTD on FPGA, simulation-first.
- It is **not** zero-latency, zero-aliasing, or single-clock-cycle. Those are
  marketing; this document avoids them.
- It is **not** yet a hardware product: the RTL is complete and verified in
  simulation, but board bring-up and the analog front-end remain.

## License

MIT.
