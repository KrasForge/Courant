# RADIAN sound-engine repair — 2026-09-16

The playable RTL was repaired after the first listening demos exposed uncalibrated pitch and excessive high-frequency/non-linear output.

## Implemented
- Discrete-mesh pitch calibration for NX/NY, OS, sample rate, and fixed/free boundary mode.
- MIDI velocity controls strike only by default; CHAOS is independent.
- Musical strike gain reduced from 0.9 to 0.002; output level is restored after the resonator instead of clipping cells.
- TENSION is a normalized multiplier (0.25 unity, approximately ±1 octave panel range).
- Rate-aware DECAY mapping and a one-LSB decay-pot change threshold.
- Preset pickup coordinates and boundary mode now reach the active voice path.
- Balanced excitation for free-boundary musical voices to avoid the DC translation mode.
- Voice retrigger/steal resets the selected mesh with a 32-frame output crossfade.
- 20 Hz DC blocker and bounded output gain before I2S CDC.
- Spatial and TDM meshes support the same runtime pickup/boundary controls.

## Acceptance
- Published repo: **28/28** NVC RTL testbenches pass.
- Fixed/free spectral probes at MIDI 45/57/69/81: maximum measured pitch error **0.89 cents**.
- Instrumented musical probes, including max CHAOS, complete without internal Q1.23 cell-clipping assertions.
- GHDL synthesis of the published 4-voice 8x8 OS4 TIME_MUX `synth_top` succeeds; current Verilator build has no warnings.
- Native NVC and GHDL→Verilator captures match sample-for-sample for both fixed and free validation cases (12,000 stereo frames each).
- Four-second full MIDI→polyphony→CDC→I2S phrase: 3 active voices max, 99.919% spectral power below 2 kHz, 0.000012% above 5 kHz.

Raw metrics and commands are preserved under `/home/ik/ChatGPT/RADIAN_Sound_Repair_20260916T042905Z`. A pre-apply rollback archive is `/home/ik/ChatGPT/RADIAN_Sound_Repair_20260916T042905Z/repo_before_sound_repair.tar.gz`.

This validates simulation/synthesis behavior, not physical FPGA timing closure or analog hardware sound.
