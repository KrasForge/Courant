# Panel controller

Wires the physical front panel to the engine (issue #78): macro knobs set the
live coefficients and a rotary encoder + button select and recall presets, all
through the `preset_bank` register / preset interface (#30, #69). RTL:
[`src/rtl/panel_ctrl.vhd`](../src/rtl/panel_ctrl.vhd).

## Control map

| Control | Target | Register | Range (default) |
| --- | --- | --- | --- |
| `pot_pitch` | `gamma2` (pitch / tension) | 0 | 0.02 .. 0.44 |
| `pot_decay` | `sigk1` **and** `a0` (decay) | 2, 1 | 0.9950 .. 0.99999 |
| `pot_timbre` | `alpha` (chaos / timbre) | 3 | 0.0 .. 0.40 |
| encoder turn | `preset_index` | - | 0 .. N_PRESETS-1 |
| encoder button, short press | `recall` | - | load selected preset |
| encoder button, long press | `save` | - | store into a user slot |

The pot ranges, ADC width, dead-band, and long-press threshold are all generics.

## Behaviour

- **Pots -> coefficients.** Each pot is scaled from its ADC range into the
  register's Q1.23 range and written on **change only**: a scanner cycles the
  four macro registers one per clock, and a register is rewritten only when its
  pot moved past the `DEADBAND` (rejecting ADC LSB jitter), so the single-port
  register bus is never flooded. The decay knob drives both `sigk1` and `a0`
  with the same value (`a0 ~= sigk1` over the small `sigma*k` a knob spans - a
  documented macro approximation).
- **Encoder.** One `preset_index` step per rising edge of channel A, direction
  from channel B, saturating at the ends. Turning only *selects*; it does not
  auto-recall.
- **Button.** A short press pulses `recall` (load the selected preset); holding
  past the long-press threshold pulses `save` (store the live registers into the
  selected user slot; `preset_bank` ignores saves aimed at factory slots).
- **Recall vs. live knobs ("pickup").** After a recall the live registers hold
  the recalled preset. The panel only writes a register when its pot *moves*
  (the pot target then differs from the panel's last write), so the recalled
  sound stays until you actually turn a knob, which then takes over that
  parameter. Simple pickup behaviour, no knob-jump on recall.

## Inputs

The pot ADC samples are assumed synchronous to `clk`; the encoder (A/B) and the
button are asynchronous and are brought in through two-flop synchronisers inside
the block. Drop `panel_ctrl` alongside `synth_top` and connect its `cfg_*` /
`preset_*` outputs to the `preset_bank` control ports (the same ports
`synth_top` already exposes).

## Verification

[`src/tb/panel_ctrl_tb.vhd`](../src/tb/panel_ctrl_tb.vhd) wires `panel_ctrl` into
a real `preset_bank` and checks the panel reaches the coefficients: moving the
pitch/timbre/decay pots writes and updates `gamma2` / `alpha` / `sigk1`+`a0` on
`preset_bank.coeffs`; stable pots produce no further writes (dead-band); the
encoder steps `preset_index`; a short button press recalls the selected preset
(coeffs load the gong factory values) and a long press emits save. Passes under
GHDL.
