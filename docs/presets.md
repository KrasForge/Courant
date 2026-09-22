# Presets

Storing and recalling whole instrument setups (milestone M8). A **preset** is one
bundle of coefficients + tap positions + boundary mode; recalling it in a single
operation re-tunes the engine to a different instrument character.
[`src/rtl/preset_bank.vhd`](../src/rtl/preset_bank.vhd) is the preset-capable
register bus (a superset of [`control_bus`](../src/rtl/control_bus.vhd)).

## Preset format (register layout)

Each preset is 16 words of 24 bits (mesh coefficients are Q1.23):

| Addr | Field | Meaning |
| --- | --- | --- |
| 0 | `gamma2` | legacy raw coefficient; in `synth_top` musical mode this is normalized **TENSION** (`0.25` = unity) |
| 1 | `a0` | `1/(1+sigma*k)`: forward damping scale |
| 2 | `sigk1` | `1 - sigma*k`: backward damping (decay time) |
| 3 | `alpha` | chaos coupling: timbre (amplitude stiffening) |
| 4 | `gamma2_max` | CFL-safe clamp ceiling (< 1/2) |
| 5 | `pick_lx` + `RIM` + `STIFFNESS` | low coordinate bits = left pickup X; bits 15..8 = RIM compliance; bits 23..16 = STIFFNESS |
| 6 | `pick_ly` + `STRIKE_SIZE` + `HARDNESS` | low coordinate bits = left pickup Y; bits 15..8 = strike footprint size; bits 23..16 = physical mallet HARDNESS |
| 7 | `pick_rx` + `STRIKE_X` | low coordinate bits = right pickup X; bits 15..8 = full strike-X control |
| 8 | `pick_ry` + `STRIKE_Y` | low coordinate bits = right pickup Y; bits 15..8 = full strike-Y control |
| 9 | `physical_ctrl` | bit 0 legacy boundary; bits 3..1 MATERIAL; 6..4 CHARACTER/EXCITER; 10..7 signed ANISO; 12..11 source mode; 16..15 L pickup X frac; 18..17 L pickup Y frac; 20..19 R pickup X frac; 22..21 R pickup Y frac; remaining bits reserved |
| 10 | `fx_ctrl0` | bit 23 master; bits 22..18 drive/tone/chorus/delay/reverb enables; drive + tone amounts |
| 11 | `fx_ctrl1` | chorus rate / depth / mix (8 bits each) |
| 12 | `fx_ctrl2` | delay timing + mix: legacy raw samples when bit 23=0; tempo-grid encoding when bit 23=1 |
| 13 | `fx_ctrl3` | delay feedback / damping / ping-pong flag / `POLISH` macro in bits 6..0 |
| 14 | `fx_ctrl4` | FDN reverb decay / damping / mix |
| 15 | `fx_ctrl5` | FDN size / diffusion / output trim |

Addresses 0..9 retain the mesh/pickup map; register 9 extends its original boundary bit using previously-unused bits, so old bundles with only bit 0 set remain compatible. Addresses 10..15 are stored in the
same factory/user bundles and feed the post-mesh `fx_chain`. `fx_ctrl3(6..0)`
uses bits that were previously unused, so the new mastering stage requires no
new register, panel control, or PCB signal. `POLISH=0` is an exact bypass;
factory/reset musical presets use `POLISH=64` as a medium finished-output curve.

### Physical-model control encoding

Register 9 keeps boundary mode in bit 0 and uses previously-unused bits for MATERIAL, CHARACTER/EXCITER, ANISO, MIDI/CV source override, and fractional pickup offsets. Registers 5..8 reuse upper bytes for physical controls: register 5 bits 15..8 hold RIM and bits 23..16 hold STIFFNESS; register 6 bits 15..8 holds STRIKE SIZE and bits 23..16 hold HARDNESS; registers 7..8 bits 15..8 hold STRIKE X/Y. This preserves the 16-word preset format and keeps every pre-#86/#87 bundle at `STIFFNESS=0` and `HARDNESS=0`.

`MATERIAL` codes coordinate several physical parameters rather than acting like another post effect: `0=neutral/current`, `1=membrane`, `2=wood`, `3=metal`, `4=glass` (`5..7` currently reserved). They bias anisotropy, high-frequency loss, nonlinearity and the default exciter. Musical factory Drum uses membrane; Gong and Metallic Plate use metal.

`CHARACTER/EXCITER=0` lets MATERIAL/velocity choose the strike behavior. Explicit codes are `1=point`, `2=soft/broad mallet`, `3=pluck/bipolar`, `4=rim/hard`, `5=scrape/bow-burst`; panel CHARACTER saturates above 5. **HARDNESS** is an unsigned byte for the stateful physical mallet. `HARDNESS=0` is an exact legacy-envelope bypass; nonzero HARDNESS activates the bidirectional mallet when CHARACTER is AUTO or MALLET. Velocity initializes hammer momentum independently of HARDNESS. ANISO is signed 4-bit (`-8..+7`). RIM continuously blends edge reflection from fixed toward compliant/free in 1/16-scale shift/add steps. **STIFFNESS** is an unsigned byte with production mapping `mu2 = STIFFNESS / 4096`; zero is the exact legacy membrane path and 255 approaches the pure-plate stability limit. The runtime wave-speed clamp is tightened to `gamma2 <= min(gamma2_max, 0.5 - STIFFNESS/512)`, implementing `(g2x+g2y)+16*mu2 <= 1`. STRIKE SIZE has four contact-footprint bands: fractional point, compact cross, 3x3 weighted contact, and a wider 13-node contact. STRIKE X/Y encode the complete integer+quarter-cell contact position.

Source mode in register 9 bits 12..11 is `00=AUTO`, `01=force MIDI`, `10=force CV`, `11=AUTO`. In AUTO, the newest MIDI note-on or CV gate rising edge claims the performance source and stays selected until the other source produces a new note event. The old external `cv_sel` input remains only as a force-CV/debug compatibility override; the board switch no longer drives it.

### Delay timing encoding

Register 12 keeps the old raw-sample format whenever bit 23 is clear, so all
existing presets remain compatible: bits 23..8 are delay samples and bits 7..0
are wet/dry mix. When bit 23 is set, no new register or panel control is needed:
bits 22..16 encode `BPM-60` (60..187 BPM), bits 15..13 select a musical
division, and bits 7..0 remain wet/dry mix. Division codes are 1/16, 1/8,
dotted 1/8, 1/4, dotted 1/4, 1/2, 1/8-triplet, and 1/4-triplet. Times longer
than the physical 500 ms delay RAM are safely clamped. The conversion is an
elaboration-built ROM, not a runtime divider.

FX parameters are now slewed at the 48 kHz sample rate after initial activation.
Effect enable bits fade their amount/mix toward neutral instead of hard-switching;
the global FX master takes 128 samples (~2.7 ms at 48 kHz) to crossfade against
the latched dry path before returning to exact bit-for-bit bypass. Delay-time
edits move by one RAM tap per audio frame, avoiding large read-pointer jumps.
Preset recall therefore needs no additional PCB or panel hardware to avoid
zipper/click artifacts.

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

`preset_bank` retains its legacy coefficient presets when `MUSICAL_MODE=false`.
The playable `synth_top` enables `MUSICAL_MODE=true`, where register 0 is a
normalized TENSION macro and damping is calculated for the actual `FS_HZ*OS`
mesh-step rate. Current musical factory starting points are:

| # | Name | TENSION | CHAOS | Damping `sigma` | Boundary | Pickup character |
| --- | --- | ---: | ---: | ---: | --- | --- |
| 0 | Drum | 0.25 | 0.00 | 18 | fixed | symmetric membrane pickup |
| 1 | Gong | 0.25 | 0.00 | 2 | free | wide off-centre stereo pickup |
| 2 | Metallic plate | 0.25 | 0.02 | 5 | fixed | interior stereo pickup |

Pitch itself comes from the calibrated MIDI/CV note table; TENSION then retunes
that note. This prevents a preset from silently replacing musical pitch with an
arbitrary raw Courant coefficient. `gamma2_max` remains 0.451 as the base
ceiling; nonzero STIFFNESS automatically reduces the effective per-node ceiling
with the combined stiff-surface CFL bound. Current factory presets retain both
STIFFNESS=0 and HARDNESS=0 for backward compatibility until the MATERIAL edit
page authors explicit stiff-surface / physical-mallet factory voices.

The pickup coordinates, boundary state, STIFFNESS, and HARDNESS are **live in the playable path**.
They are latched into a voice at strike time along with its coefficients, so
changing a preset affects newly struck voices without mutating a tail already
ringing. Free-boundary musical voices use a balanced two-point strike to avoid
exciting the free membrane's DC translation mode.

## Authoring a preset

The MATLAB/Octave helper [`model/preset_gen.m`](../model/preset_gen.m) still
authors **legacy/raw-coefficient** bundles. For the playable musical mode, keep
register 0 as normalized TENSION (0.25 unity) and author damping/CHAOS/taps in
the musical preset table or through the live register interface. The helper is
still useful for explicit raw-coefficient experiments:

```sh
octave-cli --eval "preset_gen('name','gong','c',245,'sigma',0.05,'alpha',0.40,'free',true)"
```

It prints both an `mk(...)` line to paste into the factory table in
`preset_bank.vhd` and the per-register `addr : Q1.23 hex` words to write over the
bus at runtime. Keep `gamma2 < gamma2_max`; the helper warns if the CFL limit is
exceeded (reduce `c` or increase `h`).

## Verification

[`src/tb/preset_bank_tb.vhd`](../src/tb/preset_bank_tb.vhd) checks that reset
gives the linear default with STIFFNESS=0 and HARDNESS=0, each factory preset recalls its full
bundle, a user slot survives an edit / save / clobber / recall round-trip
including both physical-control bytes, factory slots are read-only, and the read-back
port returns the live registers. [`src/tb/stiffness_tb.vhd`](../src/tb/stiffness_tb.vhd)
verifies STIFFNESS reaches the plate operator; [`src/tb/mallet_tb.vhd`](../src/tb/mallet_tb.vhd)
verifies the HARDNESS/contact model, and `musical_controls_tb` proves both controls
reach decoded I2S audio. All pass under GHDL.

## Runtime pickup and boundary mode

Preset tap coordinates and the boundary bit are connected through `synth_top`
to both the spatial and time-multiplexed mesh implementations.
`runtime_mesh_tb` switches them at runtime and requires the two backends to stay
bit-exact. `musical_controls_tb` additionally verifies that changing pickup and
boundary settings changes the decoded I2S audio rather than only a register.
