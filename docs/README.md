# docs/

Design documentation for the Courant FDTD engine.

Contents:
- `fixed_point_analysis.md` — Q1.23 quantization error budget, coefficient
  precision, rounding, accumulator guard bits, and M1 recommendations

Planned contents:
- `cfl_derivation.md` — stability proof and safety-margin rationale for `gamma2_max`
- `deviations.md` — log of intentional deviations from the reference model
- `resource_budget.md` — DSP/LUT estimates per target (spatial vs. time-multiplexed)
