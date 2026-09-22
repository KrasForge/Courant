# RADIAN Panel P1 — integration status, 2026-09-18

The current panel is the six-pot, two-row direct-stack revision. Native KiCad 10.0.6 ERC, DRC, filled-zone connectivity and schematic/PCB parity all pass with zero findings.

The performance controls now have a visual hierarchy: **TENSION / DECAY / CHAOS** form a widely spaced primary row intended for 23 mm knobs; **DRIVE / DELAY / REVERB** form a tighter FX row intended for 14 mm knobs. The PCB still uses the same six Bourns PTV09A4 rear-facing potentiometer footprints. MODE is restored to the original raised insert.

The panel no longer connects to the mainboard through individual function harnesses. J100 and J101 are Samtec IPS1-110-01-L-D sockets mating mainboard J17/J18 Samtec IPT1-110-06-L-D terminal strips. The two 20-pin interfaces carry power, six pot controls, CV/gate, audio, encoder/MODE/LEDs, MIDI and service/JTAG. Only truly off-board functions such as the retained MIDI DIN and desktop inlet still use short leads.

`../stack/panel-stack.json` defines the common pin map, pad geometry and mechanical stack: 19.99 mm fully mated, 20.45 mm maximum and ~20.0 mm nominal support spacing. Standoffs/support hardware, not the connectors, must carry structural load.

Current fabrication-format outputs are in `fab/` and `radian_panel-fab.zip`; current reports are in `reports/native/`. They are engineering outputs. Real connector seating, enclosure tolerances, support hardware, power/load/thermal/fault behaviour and hardware bring-up remain first-article checks.

## Mechanical integration
The reference enclosure CAD is synchronized to the two-row layout: three large primary knob references, three smaller FX knob references, MODE on its original raised insert, shifted mainboard/support planes and Samtec body envelopes. Independent validation reports zero control-hole conflicts, zero panel-component/mainboard clashes and zero Samtec body-envelope overlap. Physical first-article tolerance/retention remains required.
