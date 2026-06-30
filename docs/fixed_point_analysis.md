# Fixed-point (Q1.23) quantization analysis

Quantified error budget for the signed Q1.23 saturating datapath (README §4),
measured by comparing the floating-point golden reference (`model/Mesh2D.m`)
against the bit-faithful fixed-point model (`model/QMesh2D.m`). Reproduce with:

```sh
octave-cli --eval "quantization_study"     # or run quantization_study in MATLAB
```

All numbers below are for the reference operating point: 32×32 fixed-boundary
mesh, `fs = 48 kHz`, `c = 144 m/s`, `sigma = 1.5`, 0.8 s analysis, strike
scaled to `AMP = 0.15` (see *Input head-room*).

---

## 1. Q1.23 error budget

| Metric | Value | Notes |
| --- | --- | --- |
| SNR (round-to-nearest) | **66.6 dB** | ≈ 11 effective bits at the pickup after recursive accumulation |
| Noise floor (RMS error) | **−85.6 dBFS** | well below the audio noise floor |
| State saturations | **0** / 39.3 M updates | no overflow at this head-room |
| Decay-time drift (T60) | **+0.05 %** | 4.61 s float vs 4.61 s Q1.23 — negligible |

**Conclusion:** Q1.23 is justified. The dominant quantization noise enters
through the recursive `>>23` rescales, not the state storage, and it sits
~86 dB below full scale.

---

## 2. Coefficient precision — the dominant risk

`a0 = 1/(1+σk)` and `sigk1 = 1−σk` both sit *just below 1.0*: with
`σk = 1.5/48000 = 3.125e-5 = 2⁻¹⁴·⁹⁷`, the entire damping behaviour lives in
bits 15 and below. Quantizing the coefficients too coarsely destroys the
physics:

| Coeff frac bits | SNR (dB) | T60 (s) | Damping |
| --- | --- | --- | --- |
| 10 | −1.8 | 1404 | **collapsed** (`sigk1 → 1.0`) |
| 12 | −0.2 | 512 | **collapsed** |
| 14 | 9.0 | 2.36 | wrong (over-damped) |
| 15 | 31.8 | 4.72 | captured |
| 16 | 31.8 | 4.72 | captured |
| 18 | 38.7 | 4.72 | captured |
| 20 | 48.8 | 4.57 | good |
| 23 | 66.6 | 4.61 | matches float (4.61) |

There is a sharp cliff at ~14–15 bits, exactly where `σk ≈ 2⁻¹⁵` predicts.
Below it `sigk1` rounds to exactly 1.0, the loss term disappears, and the mesh
rings forever (T60 → hundreds of seconds).

**Conclusion:** carry `a0` and `sigk1` at full Q1.23 (≥ 20 fractional bits) and
precompute them on the control bus. This is more important than state width.

---

## 3. Rounding strategy

| Strategy | SNR (dB) | DC bias |
| --- | --- | --- |
| Round-to-nearest | 66.6 | +4.7e-8 |
| Truncate (arithmetic `>>`) | 63.3 | +4.2e-5 |

A bare arithmetic shift truncates toward −∞, injecting a per-multiply DC bias
that the recursion integrates (≈ 1000× the rounded bias) and costing ~3 dB SNR
here (up to ~7 dB at shorter horizons).

**Conclusion:** round-to-nearest on every `>>23` rescale.

---

## 4. Accumulator guard budget

The update accumulates `2u − sigk1·u^{n-1} + γ²·lap` before the final `a0`
scale. Each product is rescaled (`>>23`) to Q.23 *before* accumulating, so the
accumulator holds Q.23 values with integer guard bits.

- Peak `|accumulator|` observed: **0.817** (real units) → 1 integer guard bit
  at this head-room.
- A 48-bit accumulator at Q.23 scale provides **25 integer guard bits** — far
  more than required, even for full-scale transients (the `2u` term and a
  worst-case Laplacian of ±8 need only ~4 bits).

**Conclusion:** keep the 48-bit guard accumulator at Q.23, saturate **only on
store** back to Q1.23.

---

## 5. Input head-room

The explicit scheme has a strike-to-peak gain of **~5.4×** for the reference
strike: a unit-amplitude excitation drives the internal state to `|u| ≈ 5.4`,
far outside Q1.23's `[−1, 1)`. Without input scaling this is pure
saturation-driven distortion, not quantization.

**Conclusion:** pre-attenuate the mallet/excitation input (or budget explicit
head-room) so the internal state stays within `[−1, 1)`.

---

## Recommendations carried into M1 (`fdtd_pkg`)

1. **State / datapath:** Q1.23 (24-bit two's complement), saturating on store.
2. **Multiply:** Q1.23 × Q1.23 → Q2.46 → **round**-to-nearest `>>23` (not truncate).
3. **Coefficients:** `a0`, `sigk1` precomputed at full Q1.23 width on the
   control bus; never let `sigk1` round to 1.0.
4. **Accumulator:** 48-bit guard at Q.23 scale; saturate only on final store.
5. **Excitation:** scale the input for ~5–6× head-room to avoid saturation.
