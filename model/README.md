# model/

MATLAB / Octave reference model and stability study for the 2D FDTD mesh.

## Contents
- `Mesh2D.m` — handle class implementing the explicit centred-difference
  node update (README §1), with fixed (Dirichlet) and free (Neumann) boundaries.
- `NLMesh2D.m` — non-linear mesh: adds the amplitude-dependent stiffening /
  chaos term (README §2, the same non-linearity as the RTL), with the CFL clamp
  and Q1.23-rail saturation. Reduces to `Mesh2D` when `alpha = 0` (issue #71).
- `nl_reference.m` — verifies the non-linear model against the RTL: a Q1.23
  fixed-point emulation regenerates `src/tb/nl_mesh_trace.txt` bit-for-bit, and
  the float `NLMesh2D` is checked bounded + symmetric (issue #71).
- `fdtd_ref.m` — reference driver: strikes the mesh, renders a stereo `.wav`
  impulse response and a displacement animation under `outputs/`.
- `stability_study.m` — CFL / Courant-number sweep; classifies stable vs.
  divergent runs and recommends a `gamma2_max` safety margin for the
  non-linear clamp (README §2). Writes `outputs/cfl_*.png`.
- `Exciter.m` / `exciter_study.m` — physical mallet + bow exciter front-ends
  study (issue #33); see `docs/exciters.md`.
- `StiffMesh2D.m` / `stiffness_study.m` — bending-stiffness + anisotropy study
  (issue #31); see `docs/materials_stiffness.md`.
- `VarMesh2D.m` / `spatial_study.m` — spatially-varying coefficient maps
  (damped rim, tension gradient) study (issue #32); see
  `docs/spatial_variation.md`.
- `compare_capture.m` / `preset_gen.m` — hardware capture comparison (#27) and
  preset authoring (#30) helpers.
- `demo_render.m` — musical, non-linear, polyphonic demo phrases for listening:
  renders `outputs/demo_{gong,plate,drum}.wav` via the shared `NLMesh2D` model
  (alpha chaos term on), overlap-added notes, a DC/rumble high-pass, and
  loudness normalisation.

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
