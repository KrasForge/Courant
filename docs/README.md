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
- `deviations.md` — living log of where the RTL / fixed-point model diverges
  from the floating-point reference

Planned contents:
- `resource_budget.md` — DSP/LUT estimates per target (spatial vs. time-multiplexed)
