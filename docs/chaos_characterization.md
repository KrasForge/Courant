# Aliasing and chaos characterisation

Characterises the non-linear regime (README §2): spectral content / THD, the
aliasing floor vs oversampling, and the period-doubling route into chaos, all
under the same Q1.23 saturating arithmetic as the RTL. Reproduce with:

```sh
octave-cli --eval "chaos_study"          # or run chaos_study in MATLAB
```

Script: [`model/chaos_study.m`](../model/chaos_study.m). Base parameters:
`gamma0^2 = 0.09`, `gamma2_max = 0.451` (the CFL-safe clamp from issue #3).

---

## 1. THD vs alpha and drive amplitude

THD of a period-1 driven node (the squaring non-linearity makes harmonics):

| drive amp \ alpha | 0.1 | 0.2 | 0.3 | 0.4 | 0.5 |
| --- | --- | --- | --- | --- | --- |
| 0.2 | 1.9% | 2.3% | 2.6% | 2.8% | 3.0% |
| 0.4 | 2.8% | 3.5% | 4.0% | 4.3% | 4.7% |
| 0.6 | 3.9% | 4.5% | 5.2% | 5.7% | 18.2% |

THD grows smoothly with both `alpha` and drive amplitude, then jumps once the
combination enters the bifurcation band (broadband content, last cell). The
mallet level is as important as `alpha` for brightness.

---

## 2. Aliasing floor vs oversampling

Spectral SNR of the decimated output against a 16x ground truth (9x9 mesh,
non-linear, hard centred strike):

| OS | SNR vs 16x |
| --- | --- |
| 1x | -8.7 dB |
| 2x | -5.0 dB |
| 4x | +0.3 dB |
| 8x | +10.0 dB |

Each doubling of the oversampling factor cuts the aliasing floor by several dB.
See also `docs/oversampling.md` (issue #15) for the decimation path itself.

---

## 3. Period-doubling / route to chaos

Driven-node bifurcation via a stroboscopic Poincare section (sample once per
drive period, `T = 10`, drive `0.7`), sweeping `alpha`:

- `alpha < 0.55`: **locked period-1** (the forced response tracks the drive).
- `alpha in [0.55, 0.90]`: **route to chaos**, periods of 2, 3, 4, 6 and chaotic
  bands (the hardening `alpha*u^2` stiffness destabilises the locked orbit).
- `alpha > 0.90`: **re-locks to period-1** as the `gamma2_max` clamp saturates
  the local stiffness and removes the amplitude dependence.

This is the Duffing-style hardening-oscillator cascade: rich and genuinely
chaotic, but the clamp plus saturating state keep it bounded (next section).

---

## 4. Bounded output (no divergence)

Across the entire `alpha` x amplitude sweep the output stays inside the Q1.23
range and never pins to a rail: **bounded = true everywhere**. The two
structural guards do their job (README §2):

- `gamma2_local = clamp(..., 0, gamma2_max)` with `gamma2_max = 0.451 < 1/2`
  keeps the scheme inside the stable region (issue #3);
- saturating Q1.23 state arithmetic turns any blow-up energy into soft
  saturation rather than wrap-around or Nyquist buzz.

---

## Operating envelope

| Knob | Recommendation |
| --- | --- |
| `alpha` | `< 0.2` near-linear / clean; `0.2..0.5` musical brightening; `~0.55..0.9` bounded chaos; clamp re-locks above |
| drive amplitude | primary brightness/chaos control alongside `alpha`; THD rises with level |
| oversampling | 4x sensible default; raise to 8x for hard or chaotic patches |
| `gamma2_max` | `0.451` (issue #3); do not raise to/above `0.5` or the clamp stops protecting the CFL limit |

Plots (`model/outputs/chaos_characterization.png`: aliasing floor, THD map,
bifurcation diagram) are produced by `chaos_study` when a graphics toolkit is
available.
