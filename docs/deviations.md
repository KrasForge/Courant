# Deviations log

Intentional deviations from the reference model, and an honest record of what
has and has not been validated (README §7, "simulation-first honesty"). If a
claim is backed by simulation but not yet by hardware, it says so here.

## Latency validation (issue #27)

The claim (README §3): latency is **deterministic and sub-sample**, dominated by
the codec framing and the PE pipeline (nanoseconds to microseconds), **not** by
block buffering (milliseconds). Status: **confirmed in simulation; on-board
capture pending hardware.**

### Measured in simulation

[`src/tb/latency_tb.vhd`](../src/tb/latency_tb.vhd) measures both parts a
simulation can measure and prints the numbers:

| Measurement | Result | Notes |
| --- | --- | --- |
| Compute latency (mesh_resonator, OS=4) | **27 system cycles = 270 ns** at 100 MHz | 1% of the ~2083-cycle (100 MHz / 48 kHz) sample budget. This is the OS oversampled mesh steps through the 4-stage PE pipeline plus the decimator. |
| End-to-end latency (top_resonator over I2S) | **2 audio frames** (~42 us at 48 kHz) | I2S input framing (1 frame) + compute + I2S output framing (1 frame) + CDC. No buffering term. |

The end-to-end figure is the key evidence for the claim: it is a small, fixed
number of frames set entirely by the I2S frame structure and the PE pipeline. A
block-buffered design would add its whole block length here (32-256 frames);
this design adds none. `latency_tb` asserts the compute latency stays a fraction
of the sample budget and the end-to-end latency stays within a few frames, so a
regression that introduced buffering would fail the test.

### Not yet done (needs the physical board)

The following acceptance-criteria items from issue #27 require an Arty A7 + Pmod
I2S2 and bench instruments, which are not available in this environment. They
are set up to be turnkey once hardware is in hand, but are **not yet executed**:

- [ ] Strike the mesh on hardware and capture real audio output to a WAV.
- [ ] Confirm recognisable, stable gong/drum/plate tones from the board.
- [ ] Measure end-to-end latency on a scope (excitation edge -> first audio
      output edge) and confirm it matches the ~42 us simulation figure.

To run these when the board is available:

1. Build and flash the master-mode design (see
   [`codec_bringup.md`](codec_bringup.md) for the clocking and wiring).
2. Generate the simulation reference WAV:
   `octave-cli --eval "fdtd_ref"` -> `model/outputs/impulse_fixed.wav`.
3. Strike the mesh and record the board's line-out to a WAV at 48 kHz.
4. Compare: `octave-cli --eval "compare_capture('board_strike.wav')"`
   ([`model/compare_capture.m`](../model/compare_capture.m)). It cross-correlates
   the capture against the reference, prints the measured latency (samples / ms)
   and a normalised error, and PASS/REVIEWs on a loose recognisability gate (the
   analog path is not bit-exact, so this is a similarity check, not a
   bit-for-bit one).
5. Record the measured latency and correlation here, and note any deviation
   from the simulation figures above.

## Model / RTL deviations

None recorded yet. RTL that intentionally diverges from the
[`model/`](../model) reference (e.g. fixed-point rounding choices beyond the
documented Q1.23 behaviour) will be logged here as it arises; to date the RTL is
bit-exact with the Q1.23 reference in every testbench that compares against a
golden trace.
