# CFL stability: derivation and chosen `gamma2_max`

This note proves the `gamma^2 <= 1/2` stability limit for the explicit 2D
scheme and records the safety margin used downstream. The empirical sweep that
confirms it is [`model/stability_study.m`](../model/stability_study.m); the
update being analysed is derived in [`derivation.md`](derivation.md).

---

## 1. Von Neumann analysis (undamped)

Stability is governed by the undamped scheme (damping is purely dissipative and
only helps — see §3). With `sigma = 0`, `a0 = 1`, `sigk1 = 1`, the update is

$$u_{i,j}^{n+1} = 2u_{i,j}^{n} - u_{i,j}^{n-1} + \gamma^2 L_{i,j}^{n}.$$

Insert a single Fourier mode

$$u_{i,j}^{n} = \xi^{n}\, e^{\,\mathrm{i}(\theta_x i + \theta_y j)},
  \qquad \theta_x, \theta_y \in [-\pi, \pi].$$

The 5-point stencil `L` has the symbol

$$\hat L = e^{\mathrm{i}\theta_x} + e^{-\mathrm{i}\theta_x}
         + e^{\mathrm{i}\theta_y} + e^{-\mathrm{i}\theta_y} - 4
        = 2\cos\theta_x + 2\cos\theta_y - 4
        = -4\left(\sin^2\tfrac{\theta_x}{2} + \sin^2\tfrac{\theta_y}{2}\right).$$

Define

$$s \equiv \sin^2\tfrac{\theta_x}{2} + \sin^2\tfrac{\theta_y}{2} \in [0, 2].$$

Dividing the update by the common mode factor gives the characteristic equation

$$\xi^2 - A\,\xi + 1 = 0, \qquad A = 2 + \gamma^2 \hat L = 2 - 4\gamma^2 s.$$

---

## 2. The stability condition

The product of the two roots is `ξ₁ξ₂ = 1`. The scheme is non-amplifying
(`|ξ| <= 1` for both roots) **iff the roots are complex conjugates on the unit
circle**, which happens exactly when

$$|A| \le 2.$$

If `|A| > 2` the roots are real with one of magnitude `> 1`, i.e. exponential
growth. Expand `|A| <= 2`:

* `A <= 2`:  `2 - 4γ²s <= 2`  →  `γ²s >= 0`, always true.
* `A >= -2`: `2 - 4γ²s >= -2`  →  `γ² s <= 1`.

The binding case is the largest `s`, namely `s = 2` (the checkerboard mode
`θx = θy = π`). Therefore

$$\gamma^2 \cdot 2 \le 1 \quad\Longrightarrow\quad
  \boxed{\;\gamma^2 \le \tfrac12,\qquad \gamma \le \tfrac{1}{\sqrt2}\approx 0.7071\;}$$

This is the Courant–Friedrichs–Lewy (CFL) limit for the explicit 2D scheme
(README §1). Crossing it makes the checkerboard mode grow exponentially — the
mesh does not merely "sound bad", it diverges.

---

## 3. Effect of damping

With `sigma > 0` the characteristic equation gains the `a0` / `sigk1` factors:

$$(1+\sigma k)\,\xi^2 - (2 - 4\gamma^2 s)\,\xi + (1-\sigma k) = 0.$$

The root product is now `ξ₁ξ₂ = (1-σk)/(1+σk) < 1`, so both roots are pulled
*inside* the unit circle: damping is strictly dissipative and cannot
destabilise a scheme that is stable at `sigma = 0`. The `gamma^2 <= 1/2` bound
from §2 is therefore the controlling limit.

---

## 4. Empirical confirmation and `gamma2_max`

[`model/stability_study.m`](../model/stability_study.m) sweeps `gamma^2` across
the boundary on a 24×24 undamped mesh (100 ms per point) and classifies each
run:

| `gamma^2` | Result | Divergence onset |
| --- | --- | --- |
| 0.10 – 0.501 | stable | — |
| 0.510 | divergent | 4.5 ms |
| 0.520 | divergent | 3.0 ms |
| 0.600 | divergent | 1.5 ms |
| 0.700 | divergent | 1.0 ms |

The empirical boundary (stable through 0.501, divergent from 0.510) matches the
theoretical `1/2`, and the time-to-divergence shrinks as `gamma^2` rises — the
signature of exponential growth.

### Chosen safety margin

The non-linear term raises the *effective* local stiffness,
`gamma^2_local = gamma0^2 + alpha*u^2` (README §2), pushing toward the CFL line
exactly on loud transients. We therefore clamp below `1/2` with a 10 % margin
under the empirical limit:

$$\boxed{\;\gamma^2_{\max} = 0.451\;}$$

leaving `0.5 - 0.451 = 0.049` of head-room for the amplitude-dependent
stiffening before the hard clamp engages. This is the value carried into M3
(the non-linear clamp).

---

## References

* README §1 (Stability (CFL)), §2 (the clamp fix).
* Derivation of the update: [`derivation.md`](derivation.md).
* Sweep script: [`model/stability_study.m`](../model/stability_study.m).
