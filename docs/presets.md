# Presets

Storing and recalling whole instrument setups (milestone M8). A **preset** is one
bundle of coefficients + tap positions + boundary mode; recalling it in a single
operation re-tunes the engine to a different instrument character.
[`src/rtl/preset_bank.vhd`](../src/rtl/preset_bank.vhd) is the preset-capable
register bus (a superset of [`control_bus`](../src/rtl/control_bus.vhd)).

## Preset format (register layout)

Each preset is 10 words of 24 bits (coefficients are Q1.23):

| Addr | Field | Meaning |
| --- | --- | --- |
| 0 | `gamma2` | `gamma0^2 = (c*k/h)^2`: pitch / tension |
| 1 | `a0` | `1/(1+sigma*k)`: forward damping scale |
| 2 | `sigk1` | `1 - sigma*k`: backward damping (decay time) |
| 3 | `alpha` | chaos coupling: timbre (amplitude stiffening) |
| 4 | `gamma2_max` | CFL-safe clamp ceiling (< 1/2) |
| 5..8 | `pick_lx/ly/rx/ry` | stereo pickup tap coordinates |
| 9 | `boundary` | bit 0: 0 = fixed (Dirichlet), 1 = free (Neumann) |

This is the `control_bus` map (0..8) plus the boundary bit (9). The live
registers drive the mesh continuously and are sampled when it strobes.

## Storing and recalling

Presets live in one index space:

- `0 .. N_FACTORY-1` : **factory** presets, in ROM, read-only;
- `N_FACTORY .. N_FACTORY+N_USER-1` : **user** slots, in RAM, save + recall.

Operations (one-cycle strobes on the bus, all in the system-clock domain):

- **edit a register** : `wr_en` / `wr_addr` / `wr_data` (as `control_bus`);
- **recall a preset** : set `preset_index`, pulse `recall`. The whole bundle
  loads into the live registers in one cycle (recall takes priority over a write
  the same cycle);
- **save a preset** : set `preset_index` to a user slot, pulse `save`. The live
  registers are copied into that slot. Saving to a factory index is ignored
  (factory presets are read-only).

A typical patch-edit flow: recall a factory preset as a starting point, tweak
individual registers, then save into a user slot.

## Factory presets

Three are included ([`preset_bank.vhd`](../src/rtl/preset_bank.vhd)); they differ
in pitch (`gamma2`), decay (`sigk1`/`a0`), timbre (`alpha`), taps, and boundary,
so recalling them audibly changes the instrument:

| # | Name | `gamma2` | `alpha` | Decay | Boundary | Character |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Drum | 0.180 | 0.10 | short (`sigk1` 0.995) | fixed | membrane, quick decay, mild non-linearity |
| 1 | Gong | 0.300 | 0.40 | very long (`sigk1` 0.99999) | free | big, shimmering, strongly non-linear |
| 2 | Metallic plate | 0.400 | 0.30 | long (`sigk1` 0.9998) | free | bright, stiff, sustained metallic |

The damping pairs are consistent (`a0 = 1/(1+x)`, `sigk1 = 1-x`, `x = sigma*k`),
and every `gamma2` stays below `gamma2_max = 0.451` so the base scheme is
CFL-stable; the clamp keeps it stable under the non-linear term at any amplitude.

## Authoring a preset

Author from physical units with the MATLAB/Octave helper
[`model/preset_gen.m`](../model/preset_gen.m), which computes the Q1.23 register
words from wave speed, damping, chaos coupling, and tap positions:

```sh
octave-cli --eval "preset_gen('name','gong','c',245,'sigma',0.05,'alpha',0.40,'free',true)"
```

It prints both an `mk(...)` line to paste into the factory table in
`preset_bank.vhd` and the per-register `addr : Q1.23 hex` words to write over the
bus at runtime. Keep `gamma2 < gamma2_max`; the helper warns if the CFL limit is
exceeded (reduce `c` or increase `h`).

## Verification

[`src/tb/preset_bank_tb.vhd`](../src/tb/preset_bank_tb.vhd) checks that reset
gives the linear default, each factory preset recalls its full bundle and the
three are mutually distinct, a user slot survives an edit / save / clobber /
recall round-trip bit-for-bit, factory slots are read-only, and the read-back
port returns the live registers. All pass under GHDL.

## Note on boundary mode

The boundary bit is carried in the preset and exposed as `free_boundary` for
observability, but the mesh's boundary is still a build-time generic
(`FREE_BOUNDARY`) today, so recalling the boundary bit is advisory until a
runtime-selectable boundary lands. The coefficient, tap, and timbre fields are
fully live.
