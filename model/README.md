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
- `Exciter.m` / `exciter_study.m` — physical mallet + bow exciter front-ends
  study (issue #33); see `docs/exciters.md`.

## Planned
- `impulse_response.m` — generates reference impulse-response data for later
  RTL bit-accuracy comparison.

## Running

Runs in MATLAB or GNU Octave. From this directory:

```matlab
fdtd_ref                  % fixed-boundary impulse response -> outputs/
fdtd_ref('free', true)    % free (Neumann) boundary variant
stability_study           % CFL sweep + gamma2_max recommendation
```

Octave (headless):

```sh
octave-cli --eval "fdtd_ref"
octave-cli --eval "stability_study"
```

Generated `.wav` / `.gif` / `.png` artefacts land in `outputs/` and are
git-ignored.
