# docs/

Design documentation for the Courant FDTD engine.

Planned contents:
- `fixed_point_analysis.md` — Q1.23 format derivation, overflow/saturation bounds
- `cfl_derivation.md` — stability proof and safety-margin rationale for `gamma2_max`
- `deviations.md` — log of intentional deviations from the reference model
- `resource_budget.md` — DSP/LUT estimates per target (spatial vs. time-multiplexed)
- `spatial_variation.md` — per-node/region coefficient maps study + go/no-go (issue #32)
- `materials_stiffness.md` — bending-stiffness / anisotropy study + go/no-go (issue #31)
- `presets.md` — preset format, factory presets, and how to author/load them
- `polyphony.md` — voice abstraction, allocation/stealing, and voice-count vs. cost
- `midi.md` — MIDI/CV front-end: note→pitch, velocity→strike/timbre mapping
- `codec_bringup.md` — Pmod I2S2 (CS5343/CS4344) clocking, wiring, and bring-up
