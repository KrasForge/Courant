# MIDI / CV input front-end

The playable RADIAN path maps MIDI/CV notes to the **actual discrete mesh** rather
than treating `gamma2` as an arbitrary pitch knob. RTL lives in
[`midi_frontend.vhd`](../src/rtl/midi_frontend.vhd),
[`cv_frontend.vhd`](../src/rtl/cv_frontend.vhd), and
[`musical_pkg.vhd`](../src/rtl/musical_pkg.vhd).

## Pitch calibration

For a requested note frequency `f`, `note_gamma2` solves the discrete 2-D mesh
dispersion relation at the configured `NX`, `NY`, oversampling factor `OS`,
audio rate, and boundary mode:

```
gamma2 = 4*sin(pi*f/(fs*OS))^2 / lambda_mode
```

`lambda_mode` is the lowest non-DC eigenvalue for the selected fixed or free
boundary. The 128-entry fixed/free tables are evaluated at elaboration, so no
real-valued arithmetic is synthesized. The old raw `GAMMA2_REF` mapping remains
available with `CALIBRATED_PITCH=false` for explicit coefficient experiments.

The acceptance sweep checks notes 45/57/69/81 (110/220/440/880 Hz), 8x8 and
16x16 meshes, OS=1/2/4, 48/96 kHz, and fixed/free boundaries. Analytic error is
required below 5 cents; native RTL spectral probes on the production 8x8/OS4
configuration measured the four fixed/free notes within about 1 cent.

## Strike and CHAOS

MIDI velocity now controls **strike energy only** by default:

```
exc_in = STRIKE_GAIN * velocity / 128
```

`STRIKE_GAIN` defaults to `0.002`, chosen to keep musical acceptance probes away
from Q1.23 cell clipping. `ALPHA_MAX` defaults to zero on the MIDI front end, so
a harder key no longer silently increases CHAOS.

CHAOS is an independent control. The panel/preset register and CV modulation
feed it separately; `synth_top` scales the non-linear coefficient with the
current tuned `gamma2` so its audible strength remains useful across pitch.
The CFL ceiling remains 0.451.

## TENSION and body controls

The note table establishes concert pitch. Preset register 0 is then a normalized
**TENSION** multiplier: `0.25` is unity, the panel default range 0.0625..~1.0
covers approximately -1 to +1 octave around the played note. DECAY (`a0` /
`sigk1`), CHAOS, pickup positions, and boundary mode come from the live preset
registers and are captured into a voice when it is struck.

## MIDI parser

The UART remains 31,250 baud, 8N1. The parser handles Note On/Off, running
status, and Note-On velocity zero as Note Off. Other channel/system bytes are
ignored without corrupting running status. A strike is delivered on the next
audio frame; Note Off releases allocation and leaves the resonator tail to
decay naturally.

## CV path

Pitch CV quantizes to the same calibrated note table. Gate produces a strike;
mod CV controls CHAOS independently. The fixed/free table is selected from the
current preset boundary mode, exactly as for MIDI.

## Verification

`midi_frontend_tb`, `cv_frontend_tb`, `pitch_calibration_tb`,
`musical_controls_tb`, `runtime_mesh_tb`, and `synth_top_tb` cover parsing,
calibrated pitch, independent CHAOS, runtime pickup/boundary routing, the panel
macros reaching audio, and the complete MIDI/CV -> polyphony -> I2S path.
The final repair regression passes all 28 RTL testbenches under NVC.
