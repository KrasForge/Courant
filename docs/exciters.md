# Exciter front-ends: physical mallet and bow (issues #33 / #87)

Issue #33 studied stateful physical exciters. Issue #87 integrates the mallet
into the production RTL; the bow remains a follow-up study.

The important change is that a mallet is no longer just a short envelope. It is
a state machine coupled to the modeled surface:

```
eta = hammer_x - surface_u
F   ~= HARDNESS * [eta]_+^2
hammer_v' = hammer_v - reaction(F)
hammer_x' = hammer_x + hammer_v'
```

Every mesh step the mallet reads the **actual quarter-cell strike-point surface
displacement**, computes contact force, applies it through the existing strike
footprint, and receives the reaction back into its own velocity. Contact can
therefore end early or late depending on both hammer state and surface motion.

## Production HARDNESS control

HARDNESS is an unsigned 8-bit preset/control value stored in register 6 bits
23..16. Zero is an exact pre-#87 bypass. Nonzero values activate the physical
mallet when CHARACTER is **AUTO** or **MALLET**; explicit Point, Pluck, Rim and
Scrape modes keep their existing shaped-envelope behavior.

Strike velocity and HARDNESS are independent: velocity initializes hammer
momentum, while HARDNESS changes the contact spring law.

The production contact curve is a multiplier-free piecewise approximation to
`eta^2`. The leading bit of positive compression selects a shift approximating
the second power, then the 8-bit HARDNESS value continuously scales that result
with static shift/add terms. The normalized gain is:

```
contact_gain = (32 + HARDNESS) / 64
```

The contact force that reacts on the hammer and the force injected into the mesh
use separate fixed unit-conversion scales. This mirrors the study model's
separate mechanical mass/contact and mesh coupling units without adding a
runtime divider.

## Measured contact behavior

`model/mallet_reference.py` independently mirrors the fixed-point production
mapping at the 192 kHz mesh-step rate used by OS=4 / 48 kHz audio:

| Setting | HARDNESS | Contact steps | Contact time |
| --- | ---: | ---: | ---: |
| soft | `0x20` | 180 | **0.938 ms** |
| medium | `0x80` | 133 | **0.693 ms** |
| hard | `0xFF` | 105 | **0.547 ms** |

At medium HARDNESS, changing strike velocity from 0.20 to 0.85 shortens contact
from 185 to 108 mesh steps. Thus the two contact-duration trends from the #33
floating-point study survive the production normalization: **harder -> shorter
contact**, and **higher velocity -> shorter contact**. Shorter contact is the
physical mechanism expected to broaden/brighten the excitation; the automated
acceptance claim here is the measured contact duration rather than an invented
spectral score.

The original SI-scale `Exciter.m` study measured 2.29 / 1.08 / 0.69 ms for its
soft / medium / hard examples. The exact milliseconds differ because the
production engine uses normalized fixed-point state and a deliberately
DSP-free contact approximation, but the physical ordering and sub-ms-to-ms
contact regime are preserved.

## RTL architecture

`physical_mallet.vhd` owns per-voice hammer position, velocity, contact history
and a bounded lifetime. It is instantiated inside both `grid_mesh` and
`grid_mesh_tdm`, where the actual strike-point surface state is available.

- **Spatial mesh:** the contact displacement is bilinearly interpolated directly
  from the live grid.
- **TDM mesh:** the four strike interpolation corners are captured during the
  normal raster and become the next-step contact displacement at `FINISH`.
- The one-cycle note trigger only initializes the hammer. Force continues across
  later oversample steps and audio frames until first separation.
- First separation terminates the contact episode; it cannot leave a stuck DC
  force or enter an accidental uncontrolled re-contact/rattle loop.
- The existing balanced-free strike rule still applies when required.

The TDM implementation latches the mallet force at the beginning of a sweep
before the hammer state advances on that same strobe. This preserves the same
update ordering as the spatial backend and is verified bit-for-bit.

## FPGA cost

The original study estimated ~3-4 DSPs for a literal power-law/contact
multiplier implementation. That is not acceptable on the current XC7A50T,
because the four-voice synth already uses 116/120 DSPs.

The production implementation therefore uses no multiplier for the contact
curve. Open-source XC7 mapping of `physical_mallet` is:

| Resource | Count |
| --- | ---: |
| DSP48E1 | **0** |
| LUT1..6 | **1,280** |
| FF | **61** |
| CARRY4 | **173** |

This is per mallet instance before flattening/optimization with the surrounding
mesh. The binding resource remains the existing mesh/FX DSP budget.

## Verification

`mallet_tb` checks:

- independent Python golden force, contact, active, position and velocity state;
- soft > medium > hard contact duration;
- higher strike velocity shortens contact;
- changing `surface_u` changes contact force (the feedback path is real);
- clean release with zero force after separation;
- bit-exact spatial/TDM mesh response under the stateful mallet.

`preset_bank_tb` round-trips HARDNESS through user presets, and
`musical_controls_tb` writes HARDNESS through the real register interface and
requires the decoded I2S audio to change.

## Bow status

The #33 bow/friction model remains reference-only. It uses a velocity-weakening
friction curve and can provide sustained drive, but the simple study coupling
does not yet produce a robust impedance-matched stick-slip regime. That should
remain a separate follow-up rather than being hidden inside the completed
mallet issue.

The original models remain in `model/Exciter.m` and `model/exciter_study.m`;
`model/mallet_reference.py` is the exact production fixed-point reference.
