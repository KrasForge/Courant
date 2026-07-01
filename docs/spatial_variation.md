# Spatial parameter variation (issue #32)

A reference-model exploration of letting the material properties vary *across*
the mesh (milestone M9, stretch): a damped rim, a stiffer/faster centre, a
tension gradient. Instead of one global `gamma0^2` / `sigma` / `alpha`, each node
(or region) gets its own. This note demonstrates the effect, and assesses the
RTL storage/distribution cost. It is a study, not an RTL change; the vehicle is
[`model/VarMesh2D.m`](../model/VarMesh2D.m) +
[`model/spatial_study.m`](../model/spatial_study.m).

## The model

Same explicit lossy-wave update as `Mesh2D`, but the coefficients are per-node
maps (`ny x nx` matrices):

```
u^{n+1}(i,j) = a0(i,j) ( 2u(i,j) - sigk1(i,j) u^{n-1}(i,j) + gamma2(i,j) Lap(u)(i,j) )
```

built from physical maps `gamma2 = (c_map k/h)^2`, `a0 = 1/(1+sigma_map k)`,
`sigk1 = 1 - sigma_map k`. Uniform maps reduce `VarMesh2D` **exactly** to
`Mesh2D` (verified in the study: max difference 0 over 400 steps).

### Stability is local

The CFL bound applies **per node**: the scheme is stable iff
`gamma2(i,j) <= 1/2` everywhere, so the constructor checks `max(gamma2(:))`.
Spatially-varying *damping* (`sigma`) is unconditionally stable, only the
wave-speed map is CFL-constrained. This is the same clamp Courant already has,
just evaluated per node.

## Musical profiles (measured)

`spatial_study.m` renders three profiles from a centre strike and reports decay
time (envelope to 10%) and spectral centroid:

| Profile | Decay (ms) | Centroid (Hz) | Effect |
| --- | --- | --- | --- |
| uniform (baseline) | 693 | 1249 | reference membrane |
| radial damping (damped rim) | **214** | 800 | rim soaks up energy: short, dry, darker tail |
| tension gradient (c rises across x) | 696 | **1782** | modes detune/spread: brighter, richer, bell-like |

Both voices are **unreachable with a single global coefficient set**: the damped
rim needs `sigma` high at the edge and low in the centre; the tension gradient
needs `c` (hence `gamma2`) to ramp across the surface. Audio is written to
`model/outputs/spatial_{uniform,radial_damp,tension_grad}.wav` (git-ignored;
regenerate with `octave-cli --eval "spatial_study"`).

## RTL storage / distribution cost

Per-node coefficients turn the coefficient **bus** into a coefficient
**memory**. Storage is cheap: `gamma2/a0/sigk1` per node = `3 * NX*NY * 24` bits:

| Mesh | Coeff storage | BRAM |
| --- | --- | --- |
| 8x8 | 4.6 kbit | < 1 |
| 16x16 | 18 kbit | ~1 |
| 32x32 | 74 kbit | ~2 |

The real cost is **distribution**, and it splits sharply by architecture:

- **Time-multiplexed mesh (issue #24): near-free.** The PE already sweeps nodes
  by index, so a coefficient RAM addressed by that *same* index is one extra
  read/port and no new arithmetic. Spatial variation is essentially a memory the
  node sweep already has the address for. This is the key finding: the feature
  that is expensive on a spatial mesh is almost incidental on the time-mux mesh.
- **Fully-spatial mesh: costly.** Every node needs its own coefficient
  registers/wires (3 extra Q1.23 regs/node plus routing), only reasonable for
  small grids.
- **Per-region (cheapest):** a small region-id map plus a handful of coefficient
  sets covers most musical cases (rim vs centre, quadrants, radial bands) at a
  fraction of the per-node cost, on either architecture.

## Recommendation

**GO for per-node on the time-multiplexed path; per-region for fully-spatial.**

Spatial variation is one of the cheapest high-impact features on the roadmap
*if* built on the time-mux mesh: it reuses the node sweep index to address a
coefficient RAM (~1 BRAM, one port, no new math), and the per-node CFL clamp is
the stability story, already in hand. A damped rim, a tension gradient, or a
stiffer centre meaningfully widen the palette for the cost of a small memory.

**Gate**: land it after the time-multiplexed mesh (#24) and the core hardware
(#26/#27), since the near-free version depends on the node-sweep architecture
being in place.
