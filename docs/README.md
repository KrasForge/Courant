# docs/

Design documentation for the Courant FDTD engine.

Planned contents:
- `fixed_point_analysis.md` — Q1.23 format derivation, overflow/saturation bounds
- `cfl_derivation.md` — stability proof and safety-margin rationale for `gamma2_max`
- `deviations.md` — log of intentional deviations from the reference model
- `resource_budget.md` — DSP/LUT estimates per target (spatial vs. time-multiplexed)
- `spatial_variation.md` — per-node/region coefficient maps study + go/no-go (issue #32)
