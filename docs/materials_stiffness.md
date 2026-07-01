# Advanced materials: bending stiffness and anisotropy (issue #31)

A reference-model exploration of richer physics beyond the ideal membrane
(milestone M9, stretch): a 4th-order **bending-stiffness** term (bars, plates,
bells) and **anisotropic** propagation (direction-dependent wave speed). This
note derives the scheme, its stability condition, confirms it against the model,
estimates the RTL cost, and gives a go/no-go. It is a study, not an RTL change;
the vehicle is [`model/StiffMesh2D.m`](../model/StiffMesh2D.m) +
[`model/stiffness_study.m`](../model/stiffness_study.m).

## The equation

The ideal membrane (what Courant ships) is `u_tt = c^2 ∇^2 u`. Adding bending
stiffness and anisotropy:

```
u_tt = cx^2 u_xx + cy^2 u_yy  -  kappa^2 (u_xxxx + 2 u_xxyy + u_yyyy)  - 2 sigma u_t
```

- `cx, cy` : wave speeds along x / y. `cx = cy` is isotropic; `cx != cy` is an
  anisotropic membrane (an "oval drum": the mode frequencies split).
- `kappa` : bending-stiffness coefficient. The biharmonic term `∇^4 u` is the
  thin-plate / stiff-bar operator; it makes the medium **dispersive** (higher
  spatial frequencies travel faster), which stretches the partials sharp of a
  harmonic series, the inharmonic bar/bell character.

## Discretisation

Second differences (existing) plus the biharmonic. With `k = 1/fs` the time step
and `h` the spatial step, the explicit centred update is

```
u^{n+1} = a0 ( 2u - sigk1 u^{n-1} + g2x Dxx(u) + g2y Dyy(u) - mu2 Biharm(u) )
```

with the dimensionless coefficients

```
g2x = (cx k / h)^2      g2y = (cy k / h)^2      mu2 = (kappa k / h^2)^2
```

and the stencils (`1/h^4` folded into `mu2`):

```
Dxx = uE + uW - 2u                              (3-point)
Dyy = uN + uS - 2u                              (3-point)
Biharm = 20u - 8(N+S+E+W) + 2(NE+NW+SE+SW) + (NN+SS+EE+WW)   (13-point)
```

`Biharm` is the discrete `(∇^2)^2`: a **13-point** stencil that reaches two cells
out (the second ring `NN/SS/EE/WW`) and to the diagonals. Setting `mu2 = 0` and
`g2x = g2y` recovers the current 5-point membrane exactly.

## Stability (von Neumann)

Substitute `u ~ z^n e^{i(bx x + by y)}` and let `sx = sin^2(bx h/2)`,
`sy = sin^2(by h/2)`, each in `[0,1]`. The stencil Fourier symbols are

```
Dxx -> -4 sx     Dyy -> -4 sy     Biharm -> +16 (sx + sy)^2
```

(the biharmonic symbol is the square of the Laplacian symbol, since it is
`(∇^2)^2`). The update's characteristic equation is `z^2 - (2 - Q) z + 1 = 0`
with

```
Q = 4 (g2x sx + g2y sy) + 16 mu2 (sx + sy)^2   >= 0
```

Roots stay on the unit circle (stable, non-growing) iff `0 <= Q <= 4` for all
`sx, sy`. `Q` is maximised at `sx = sy = 1`:

```
Q_max = 4 (g2x + g2y) + 64 mu2   <=  4
```

giving the **stability condition**

```
(g2x + g2y) + 16 mu2  <=  1
```

Sanity checks:
- membrane (`mu2 = 0`, `g2x = g2y = g^2`): `2 g^2 <= 1`, i.e. `g^2 <= 1/2`,
  exactly the CFL limit Courant already uses (`gamma2_max = 0.451`, issue #3);
- pure plate (`g2x = g2y = 0`): `mu2 <= 1/16`.

**The stiffness term tightens CFL**: every unit of `16 mu2` is stolen from the
wave headroom `(g2x + g2y)`, so a stiffer medium must run a lower wave speed for
the same grid.

### Confirmed against the model

`stiffness_study.m` sweeps `mu2` at fixed `g2x = g2y = g^2` and compares the
empirical stable maximum to the predicted `mu2 = (1 - 2 g^2)/16`:

| `g^2` (each axis) | predicted `mu2_max` | empirical `mu2_max` | match |
| --- | --- | --- | --- |
| 0.05 | 0.05625 | 0.05625 | yes |
| 0.10 | 0.05000 | 0.05000 | yes |
| 0.20 | 0.03750 | 0.03750 | yes |

The closed-form boundary is exact to the sweep resolution.

### Timbre (audio)

`stiffness_study.m` renders `model/outputs/{membrane,stiff_plate,anisotropic}.wav`.
The measured low partials show the expected behaviour: adding stiffness stretches
the partial ratios sharp (dispersion -> inharmonic bar/bell), and anisotropy
(`cx != cy`) splits the degenerate membrane modes into distinct frequencies (the
"oval drum"). The wavs are git-ignored artefacts; regenerate with
`octave-cli --eval "stiffness_study"`.

## RTL cost of the wider stencil

The scheme stays **linear and explicit** (same class of update), so the only
changes are stencil width and one coefficient:

- **Arithmetic**: neighbour taps grow `4 -> 12` (`~+8` adds in the accumulate);
  `+1` coefficient multiply for `mu2*Biharm`; anisotropy splits the single
  `gamma2*lap` multiply into `g2x*Dxx + g2y*Dyy` (`+1` multiply). Net roughly
  **+1..2 DSP per node** over the 18-DSP membrane PE (~10%).
- **Memory / routing is the real cost**: the second ring needs `+-2` rows, so
  the time-multiplexed mesh (issue #24) needs **two row line-buffers instead of
  one**, and the fully-spatial mesh needs a wider neighbour fabric (diagonals +
  second ring). Boundaries need a **2-cell ghost margin** and, for a properly
  clamped plate, an extra edge condition (`u = 0` and `du/dn = 0`); the study
  uses the simply-supported case (`u = 0`).
- **Stability** folds in for free: the existing compile-time CFL clamp just uses
  the new closed-form bound `(g2x + g2y) + 16 mu2 <= 1`.

## Recommendation: GO (conditional)

The extension is modest and well-understood: one extra coefficient, a wider but
still-linear stencil, and a tighter but closed-form stability bound that drops
straight into the existing clamp. DSP cost is small; the line-buffer and
ghost-margin work is the real integration effort. It meaningfully widens the
palette (bars, plates, bells, anisotropic "oval" drums), which is exactly the
kind of distinctive voice worth having.

**Gate**: land it *after* the core is validated on real hardware (issues
#26/#27), because it widens both the datapath and the memory subsystem, changes
best made once the baseline mesh is proven in silicon.
