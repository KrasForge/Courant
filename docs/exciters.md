# Exciter front-ends: mallet and bow (issue #33)

A reference-model exploration of replacing the raw single-sample strike with
**physical exciter models** (milestone M9, stretch): a mallet whose hardness and
velocity shape the attack, and a bow/friction driver for sustained voices. This
note prototypes both, defines how they couple to the mesh, assesses RTL cost, and
recommends one for integration. Study only; the vehicle is
[`model/Exciter.m`](../model/Exciter.m) +
[`model/exciter_study.m`](../model/exciter_study.m).

## Coupling: a stateful, bidirectional exciter on one node

Courant's excitation today is a raw sample added at one node (`exc_in`, one-way).
A physical exciter is **bidirectional and stateful**: each step it *reads* the
surface displacement at the excitation node, computes a force from its own
internal state, and *adds that force back* at the node. Mechanically it is a
small state machine hanging off the existing `exc_in` node, the change is to make
`exc_in` dynamic and state-dependent rather than a fixed sample.

## Mallet (lumped mass-spring contact)

A piano-hammer / Chaigne-Askenfelt style contact. With hammer displacement `uh`
and surface displacement `us`, compression `eta = uh - us`:

```
F = k * [eta]_+^p        (force only while in contact, eta > 0)
m * d2uh/dt2 = -F        (the surface reaction decelerates the hammer)
```

**Hardness = `k`** (spring stiffness): a stiffer spring gives a shorter contact
and a broader, brighter attack; softer gives a longer, duller one. Contact time
also shortens with strike velocity, so brightness tracks how hard you hit, the
expressive core of a struck instrument, and exactly what a raw impulse cannot do.

### Measured (from `exciter_study.m`)

| Mallet | `k` | Contact time | Spectral centroid |
| --- | --- | --- | --- |
| soft | 1e5 | 2.29 ms | 422 Hz |
| medium | 1e6 | 1.08 ms | 668 Hz |
| hard | 1e7 | 0.69 ms | 1029 Hz |

Harder -> shorter contact -> brighter, monotonic and confirmed, with contact
times in the physically plausible sub-millisecond-to-few-millisecond range.
Audio: `model/outputs/exc_{soft,hard}.wav`.

## Bow (friction / stick-slip driver)

A continuous friction force from the relative velocity `vrel = vbow - vs`
(`vs` = surface velocity):

```
F = Fn * sign(vrel) * (muD + (muS - muD) * exp(-|vrel| / vc))
```

The velocity-weakening (negative-slope) region is what sustains self-oscillation
(bowed metal / plate). The friction force is applied for the whole stroke, so
unlike a strike the excitation never stops.

**Honest status**: in the simple lumped coupling used here the surface velocity
stays well below bow speed, so `vrel ~ vbow` (near-constant) and the drive is
closer to a quasi-static push than true stick-slip. A clean self-oscillating
Helmholtz motion needs the coupling **impedance-matched** so the surface velocity
reaches bow-speed scale and actually traverses the negative-slope region. Tuning
that loop (and its fixed-point limit-cycle stability) is real work, which is why
the bow is the **riskier, follow-up** exciter. The model, friction curve, and
coupling are in place as the starting point; `model/outputs/exc_bow.wav` is the
driven response.

## RTL feasibility / cost

Both exciters are a few operations on one node, reusing the node read the mesh
already exposes:

- **Mallet**: hammer state (`uh`, `vh`), one `[eta]_+^p` (a compare + a square
  for `p=2`), one constant `1/m` multiply, two integrator adds. **~3-4 DSP** and
  a handful of registers, per voice. Cheap, self-contained, drops onto the
  existing `exc_in` node with no mesh changes.
- **Bow**: the friction curve `mu(vrel)` is best a small **LUT (ROM)** + 1-2
  multiplies, plus a one-subtract surface-velocity estimate. Also cheap in gates,
  but the stick-slip feedback loop needs care (impedance match + limit-cycle
  stability in fixed point).

## Recommendation: GO, mallet first; bow as a follow-up

The mallet is the highest expressivity-per-gate feature on the roadmap: ~3-4 DSP
on one node turns the raw strike into a hardness- and velocity-sensitive contact,
most of what makes a struck instrument feel alive, and it needs no mesh changes.
Build it first. The bow (LUT friction) is the natural second exciter for
sustained voices once the mallet is proven and the friction feedback loop is
tuned.

**Gate**: land exciters after the core is validated on real hardware (#26/#27);
they sit on the excitation node, so they want the baseline strike path proven in
silicon first.
