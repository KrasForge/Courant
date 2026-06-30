# model/

MATLAB / Octave reference model and stability study for the 2D FDTD mesh.

## Contents
- `Mesh2D.m` — handle class implementing the explicit centred-difference
  node update (README §1), with fixed (Dirichlet) and free (Neumann) boundaries.
- `fdtd_ref.m` — reference driver: strikes the mesh, renders a stereo `.wav`
  impulse response and a displacement animation under `outputs/`.
- `stability_study.m` — CFL / Courant-number sweep; classifies stable vs.
  divergent runs and recommends a `gamma2_max` safety margin for the
  non-linear clamp (README §2). Writes `outputs/cfl_*.png`.
- `QMesh2D.m` — Q1.23 saturating fixed-point variant of `Mesh2D` modelling
  the RTL datapath (README §4): Q2.46 multiply → `>>23`, 48-bit guard
  accumulator, saturation on store.
- `quantization_study.m` — float vs. Q1.23 error budget (SNR, noise floor,
  decay drift), coefficient-precision sweep, rounding and guard-bit analysis.
  Writes `outputs/quant_*.png`; see `docs/fixed_point_analysis.md`.

## Planned
- `impulse_response.m` — generates reference impulse-response data for later
  RTL bit-accuracy comparison.

## Running

Runs in MATLAB or GNU Octave. From this directory:

```matlab
fdtd_ref                  % fixed-boundary impulse response -> outputs/
fdtd_ref('free', true)    % free (Neumann) boundary variant
stability_study           % CFL sweep + gamma2_max recommendation
quantization_study        % Q1.23 fixed-point error budget
```

Octave (headless):

```sh
octave-cli --eval "fdtd_ref"
octave-cli --eval "stability_study"
octave-cli --eval "quantization_study"
```

Generated `.wav` / `.gif` / `.png` artefacts land in `outputs/` and are
git-ignored.
