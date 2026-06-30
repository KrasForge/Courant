# Oversampling and decimation

The squaring non-linearity (`alpha*u^2`, README §2) generates harmonics above
Nyquist that fold back into the audio band as aliasing. The mitigation is
oversampling: run the mesh at `OS` times the audio rate and decimate on output.
Implemented in [`src/rtl/mesh_resonator.vhd`](../src/rtl/mesh_resonator.vhd),
validated by [`src/tb/mesh_resonator_tb.vhd`](../src/tb/mesh_resonator_tb.vhd),
measured by `model/` (os_gen).

## How it works

Per audio frame (`frame` pulse), `mesh_resonator`:

1. issues `OS` mesh strobes, advancing `grid_mesh` `OS` time-steps at `OS x f_s`
   (each step waits for the mesh's `valid`);
2. injects the excitation on the first oversampled step;
3. accumulates the stereo pickups over the `OS` steps and outputs their average,
   a boxcar / CIC-1 decimation low-pass, as one audio sample (`out_valid`).

The average is a multiply by the compile-time constant `1/OS` (`to_q123`), so no
runtime divider is instantiated. The coefficients on `coeffs` are precomputed
for the oversampled rate: `gamma2 = (c*(k/OS)/h)^2`, `a0 = 1/(1+sigma*k/OS)`,
`sigk1 = 1 - sigma*k/OS`, with the non-linear coupling scaled to match.

## Measured aliasing reduction

Spectral SNR of the decimated output against a 16x ground truth (9x9 mesh,
non-linear, hard centred strike), from `model/` (os_gen):

| OS | spectral SNR vs 16x |
| --- | --- |
| 1x | -8.7 dB |
| 2x | -5.0 dB |
| 4x | +0.3 dB |
| 8x | +10.0 dB |

The SNR rises monotonically with `OS`: measurable aliasing reduction versus 1x,
roughly doubling-the-rate buys several dB.

## Cost per factor (the quality/area knob)

`OS` is a documented quality/area knob, not magic:

- **Throughput**: each oversampled step costs about 7 system clocks (mesh
  pipeline latency plus sequencer handshake), so a frame costs ~`7 * OS` clocks.
  At 100 MHz over 48 kHz there are ~2083 clocks per audio frame, so `OS` up to
  ~250-300 fits within one sample period. Practical range is `OS` = 1..16.
- **Area**: oversampling reuses the *same* `grid_mesh` (no extra PEs). The only
  added hardware is fixed and independent of `OS`: two 48-bit accumulators, two
  multiplies for the `1/OS` averaging, and a small sequencer FSM.

So higher `OS` trades audio-frame timing headroom (throughput) for lower
aliasing, at negligible extra area. The decimation filter is a first-order
boxcar; a higher-order CIC or FIR would improve stopband attenuation at the cost
of a few more adders, a further quality knob if needed.
