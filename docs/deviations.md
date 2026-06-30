# Deviations log

A living record of places where the RTL (or the fixed-point model) **diverges
from the floating-point reference model** ([`model/Mesh2D.m`](../model/Mesh2D.m),
[`model/fdtd_ref.m`](../model/fdtd_ref.m)), and of known gaps in the reference
model itself. Each entry says *what* differs, *why* it is acceptable, and where
it is characterised or tracked.

Status legend: **characterised** (measured, within budget) · **intended**
(deliberate design choice) · **gap** (reference model not yet complete) ·
**open** (needs work / decision).

---

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

---

## How to use this log

* When RTL is written (M1+) and a unit/system testbench shows a difference from
  the reference, add a row here before "fixing" it — some differences are
  expected (D1–D4) and the test tolerance should reflect them.
* Promote a **gap** to a characterised/intended row once the corresponding model
  or RTL lands.
* Cross-link the script, testbench, or doc that quantifies each deviation.
