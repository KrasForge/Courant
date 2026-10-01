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

## Fixed-point vs floating-point reference (M0 study)

Recorded during the M0 quantization study (June 2026), against the
floating-point reference ([`model/Mesh2D.m`](../model/Mesh2D.m),
[`model/fdtd_ref.m`](../model/fdtd_ref.m)). Statuses reflect that study;
the D5/D6 "gap" rows predate the non-linear model (`NLMesh2D`).

Status legend: **characterised** (measured, within budget) · **intended**
(deliberate design choice) · **gap** (reference model not yet complete) ·
**open** (needs work / decision).

| ID | Area | Reference behaviour | Deviation | Rationale | Status | Ref |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | Arithmetic | IEEE double | Signed **Q1.23** saturating fixed point | Hardware cost; ~66.6 dB SNR, −85.6 dBFS noise floor, 0 saturations at head-room | characterised | [fixed_point_analysis.md](fixed_point_analysis.md) |
| D2 | Rounding | Exact | Round-to-nearest on every `>>23` rescale | Truncation adds a DC bias the recursion integrates (+4.2e-5 vs 4.7e-8) and costs SNR | intended | [fixed_point_analysis.md](fixed_point_analysis.md) §3 |
| D3 | Coefficients | Exact `a0`, `sigk1` | Finite-precision, precomputed on the control bus | Avoids per-node division; must stay ≥ ~20 frac bits or `sigk1 → 1.0` and damping vanishes | characterised | [fixed_point_analysis.md](fixed_point_analysis.md) §2 |
| D4 | Accumulator | Exact sum | 48-bit guard at Q.23, saturate on store | 25 integer guard bits ≫ the ~4 needed; overflow only soft-clips | characterised | [fixed_point_analysis.md](fixed_point_analysis.md) §4 |
| D5 | Non-linearity | Linear mesh only | `alpha*u^2` chaos term + `gamma2_max` clamp **not yet modelled** | Deferred to a later milestone; reference model is currently linear | gap | README §2, [derivation.md](derivation.md) §5 |
| D6 | Oversampling | Base rate `f_s` | Squaring non-linearity aliases; oversample/decimate not yet modelled | Mitigation is an area/quality knob, added with the non-linear term | gap | README §2 (Aliasing) |
| D7 | Input scaling | Unit strike | Excitation must be pre-attenuated (~5–6× head-room) | Strike-to-peak gain ~5.4× would otherwise saturate Q1.23 internal state | intended | [fixed_point_analysis.md](fixed_point_analysis.md) §5 |
| D8 | Free boundary | numpy/Octave `reflect` ghost (mirrors first interior cell) | RTL edge wiring must reproduce the same ghost choice | Bit-accuracy vs the reference depends on matching the boundary exactly | open | [Mesh2D.m](../model/Mesh2D.m) `step()` |

### How to use this table

* When RTL is written (M1+) and a unit/system testbench shows a difference from
  the reference, add a row here before "fixing" it — some differences are
  expected (D1–D4) and the test tolerance should reflect them.
* Promote a **gap** to a characterised/intended row once the corresponding model
  or RTL lands.
* Cross-link the script, testbench, or doc that quantifies each deviation.
