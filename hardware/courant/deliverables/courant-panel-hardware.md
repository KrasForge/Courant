# Courant / RADIAN — current panel hardware

The old Rev-A cable-harness panel interface is retired. Mainboard edge headers
J5 through J15 have been removed from the canonical PCB and are no longer part
of the BOM, fabrication outputs, or product assembly.

The current panel is a PCB assembly that plugs directly onto the mainboard:

- mainboard J17 ↔ panel J100
- mainboard J18 ↔ panel J101
- Samtec IPT1-110-06-L-D ↔ IPS1-110-01-L-D
- 40 physical contacts total
- 19.99 mm fully-mated PCB spacing; ~20.0 mm structural support target

The shared electrical/mechanical source of truth is
`../../stack/panel-stack.json`; `../../stack/direct-stack-validation.json`
records the current 40/40 pin and mechanical checks.

## Panel controls

The panel PCB carries TENSION, DECAY and CHAOS plus DRIVE, DELAY and REVERB,
the push encoder, MODE switch, four LEDs, five 3.5 mm jacks, Eurorack power,
and its panel-side Samtec sockets. The three primary controls use larger knobs;
the FX row uses smaller knobs.
## Connections that still use short leads

Only genuinely off-board/chassis functions need wiring:

- Same Sky **SDS-50J** MIDI DIN → short 2-wire lead → exact Molex **22-27-2021** J306;
- Switchcraft **722A** 12 V chassis inlet → short 2-wire lead → exact Molex **22-27-2021** J201;
- Eurorack bus ribbon → exact Wurth **61201021621** keyed J200.

There is no per-function cable bundle between the panel PCB and mainboard.

## Selected local service parts

JP1 is Wurth **450301014042**, a real SPDT switch rather than a removable header/shunt: pin 1 common is `MOD_IN`, pin 2 is `MOD_BIPOLAR`, and pin 3 is `MOD_RAW`. Panel J202 is exact Molex **22-27-2061** for JTAG service.

## Service access

Mainboard J1–J4 remain service/debug interfaces. They are not panel
connections and are intentionally separate from the production J17/J18 stack.

`courant-panel-interface.csv` is retained only as historical Rev-A reference;
do not use it as the current product interconnect. The current interconnect is
defined by `../../stack/panel-stack.json`.
