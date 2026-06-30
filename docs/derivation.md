# Discretisation derivation: continuous PDE → explicit update

This note derives the explicit finite-difference update used by the reference
model and the RTL, starting from the continuous lossy 2D wave equation
(README §1). The result is implemented in
[`model/Mesh2D.m`](../model/Mesh2D.m) (`step`) and exercised by
[`model/fdtd_ref.m`](../model/fdtd_ref.m).

---

## 1. Continuous equation

The transverse displacement `u(x, y, t)` of the surface obeys a lossy 2D wave
equation:

$$\frac{\partial^2 u}{\partial t^2}
  = c^2\left(\frac{\partial^2 u}{\partial x^2}
           + \frac{\partial^2 u}{\partial y^2}\right)
  - 2\sigma\frac{\partial u}{\partial t}$$

* `c` — wave propagation speed (sets pitch / tension)
* `sigma` — frequency-independent damping (sets decay time)

---

## 2. Finite-difference operators

On a uniform grid with spacing `h` and time step `k = 1/f_s`, write
`u_{i,j}^n ≈ u(ih, jh, nk)` and replace each derivative by a centred difference.

**Second time derivative** (centred, 3-point):

$$\frac{\partial^2 u}{\partial t^2}\bigg|_{i,j}^{n}
  \approx \frac{u_{i,j}^{n+1} - 2u_{i,j}^{n} + u_{i,j}^{n-1}}{k^2}$$

**First time derivative** (centred, for the damping term — this choice is what
keeps the scheme explicit *and* second-order accurate in time):

$$\frac{\partial u}{\partial t}\bigg|_{i,j}^{n}
  \approx \frac{u_{i,j}^{n+1} - u_{i,j}^{n-1}}{2k}$$

**Spatial Laplacian** (5-point stencil):

$$\nabla^2 u\big|_{i,j}^{n}
  \approx \frac{1}{h^2}\big(u_{i+1,j}^{n} + u_{i-1,j}^{n}
                          + u_{i,j+1}^{n} + u_{i,j-1}^{n}
                          - 4u_{i,j}^{n}\big)
  \equiv \frac{L_{i,j}^{n}}{h^2}$$

where `L` is the integer-coefficient stencil

$$L_{i,j}^{n} = u_{i+1,j}^{n} + u_{i-1,j}^{n}
             + u_{i,j+1}^{n} + u_{i,j-1}^{n} - 4u_{i,j}^{n}.$$

---

## 3. Substitution and solving for `u^{n+1}`

Insert the three operators into the PDE:

$$\frac{u_{i,j}^{n+1} - 2u_{i,j}^{n} + u_{i,j}^{n-1}}{k^2}
  = \frac{c^2}{h^2} L_{i,j}^{n}
  - 2\sigma\,\frac{u_{i,j}^{n+1} - u_{i,j}^{n-1}}{2k}.$$

Multiply through by `k²` and introduce the **Courant number** `gamma = ck/h`
(so `gamma^2 = c^2 k^2 / h^2`):

$$u_{i,j}^{n+1} - 2u_{i,j}^{n} + u_{i,j}^{n-1}
  = \gamma^2 L_{i,j}^{n} - \sigma k\,(u_{i,j}^{n+1} - u_{i,j}^{n-1}).$$

Collect the `u^{n+1}` terms on the left:

$$(1 + \sigma k)\,u_{i,j}^{n+1}
  = 2u_{i,j}^{n} - (1 - \sigma k)\,u_{i,j}^{n-1} + \gamma^2 L_{i,j}^{n}.$$

Divide by `(1 + σk)` to get the **explicit update**:

$$\boxed{\,u_{i,j}^{n+1}
  = a_0\Big[\,2u_{i,j}^{n} - \mathrm{sigk1}\,u_{i,j}^{n-1}
             + \gamma^2 L_{i,j}^{n}\Big]\,}$$

with the two precomputed coefficients

$$a_0 = \frac{1}{1 + \sigma k}, \qquad \mathrm{sigk1} = 1 - \sigma k.$$

This matches README §1. Both coefficients are computed once on the control bus,
so there is **no per-node division** (README §4).

---

## 4. Mapping to the implementation

| Symbol | Code (`Mesh2D.m`) | Notes |
| --- | --- | --- |
| `gamma^2` | `obj.gamma2` | `(c*k/h)^2`; CFL-checked at construction |
| `a0` | `obj.a0` | `1/(1+sigma*k)` |
| `sigk1` | `obj.sigk1` | `1 - sigma*k` |
| `L` | `lap` in `step()` | 5-point stencil via padded ghost cells |
| `u^n`, `u^{n-1}` | `obj.u`, `obj.u1` | state registers |

Boundaries enter only through the ghost cells used to evaluate `L` at the edge:

* **Fixed (Dirichlet, `u=0`)** — ghost cells are zero.
* **Free (Neumann, `∂u/∂n=0`)** — ghost mirrors the first interior cell.

See [`Mesh2D.m`](../model/Mesh2D.m) `step()` for the exact ghost construction.

---

## 5. Non-linear extension (chaos injection)

The engine makes the local stiffness amplitude-dependent (README §2):

$$\gamma_{i,j}^2 = \gamma_0^2 + \alpha\,(u_{i,j}^{n})^2,
  \qquad
  \gamma^2_{\text{local}} = \mathrm{clamp}(\gamma_0^2 + \alpha u^2,\,0,\,\gamma^2_{\max}).$$

Only `gamma^2` in the boxed update becomes node- and time-local; the rest of the
derivation is unchanged. The clamp `gamma2_max < 1/2` keeps the scheme inside
the stable region derived in [`cfl_derivation.md`](cfl_derivation.md). The
non-linear term is **not yet** in the reference model — see
[`deviations.md`](deviations.md).

---

## References

* README §1 (Mathematical foundation), §2 (non-linear term), §4 (numerics).
* Stability of this scheme: [`cfl_derivation.md`](cfl_derivation.md).
* Fixed-point realisation: [`fixed_point_analysis.md`](fixed_point_analysis.md).
