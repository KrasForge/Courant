# docs/

Design documentation for the Courant FDTD engine.

Contents:
- `derivation.md` — discretisation derivation: continuous PDE → explicit
  update; maps each symbol to [`model/Mesh2D.m`](../model/Mesh2D.m)
- `cfl_derivation.md` — von Neumann stability proof of `gamma^2 <= 1/2` and the
  chosen `gamma2_max = 0.451` margin; backed by
  [`model/stability_study.m`](../model/stability_study.m)
- `fixed_point_analysis.md` — Q1.23 quantization error budget, coefficient
  precision, rounding, accumulator guard bits, and M1 recommendations; backed
  by [`model/quantization_study.m`](../model/quantization_study.m)
- `deviations.md` — log of intentional deviations from the reference model,
  hardware-validation status, and the M0 fixed-point vs float table
- `synth_top.md` — end-to-end board top (MIDI → polyphony → I2S), datapath + clocking (issue #68)
- `resource_budget.md` — DSP/LUT estimates per target (spatial vs. time-multiplexed)
- `exciters.md` — physical mallet derivation + production HARDNESS/contact RTL; bow remains follow-up (issues #33/#87)
- `spatial_variation.md` — per-node/region coefficient maps study + go/no-go (issue #32)
- `materials_stiffness.md` — bending-stiffness / anisotropy derivation plus production STIFFNESS RTL integration (issues #31/#86)
- `presets.md` — preset format, factory presets, and how to author/load them
- `panel.md` — front-panel PLAY/EDIT controller: six soft-takeover knobs, encoder-selected edit pages and presets (issues #78/#85)
- `polyphony.md` — voice abstraction, allocation/stealing, and voice-count vs. cost
- `midi.md` — calibrated MIDI/CV pitch; velocity→strike; independent CHAOS
- `cv.md` — control-voltage front-end: 1V/oct pitch, gate strike, mod→timbre (issue #70)
- `codec_bringup.md` — Pmod I2S2 (CS5343/CS4344) clocking, wiring, and bring-up
- `board.md` — standalone Rev A instrument PCB: blocks, footprints, routing status
- `finishing_the_route.md` — the six connections left on the routed board, and
  how to close them in KiCad's interactive router
- `sound_engine_repair.md` — 2026-09-16 pitch/strike/CHAOS repair and RTL listening acceptance
- `media/` — README sound demos, spectrograms, board renders and 3D models, plus
  the scripts that regenerate them (`media/scripts/make_media.sh`)
