# docs/

Design documentation for the Courant FDTD engine.

Planned contents:
- `fixed_point_analysis.md` — Q1.23 format derivation, overflow/saturation bounds
- `cfl_derivation.md` — stability proof and safety-margin rationale for `gamma2_max`
- `deviations.md` — log of intentional deviations from the reference model
- `synth_top.md` — end-to-end board top (MIDI → polyphony → I2S), datapath + clocking (issue #68)
- `resource_budget.md` — DSP/LUT estimates per target (spatial vs. time-multiplexed)
- `exciters.md` — physical mallet/bow exciter front-ends study + recommendation (issue #33)
- `spatial_variation.md` — per-node/region coefficient maps study + go/no-go (issue #32)
- `materials_stiffness.md` — bending-stiffness / anisotropy study + go/no-go (issue #31)
- `presets.md` — preset format, factory presets, and how to author/load them
- `polyphony.md` — voice abstraction, allocation/stealing, and voice-count vs. cost
- `midi.md` — MIDI/CV front-end: note→pitch, velocity→strike/timbre mapping
- `cv.md` — control-voltage front-end: 1V/oct pitch, gate strike, mod→timbre (issue #70)
- `codec_bringup.md` — Pmod I2S2 (CS5343/CS4344) clocking, wiring, and bring-up
