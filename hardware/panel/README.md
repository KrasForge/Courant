# RADIAN / PANEL P1 — direct-stack six-control revision

**One panel/interface PCB for the RADIAN FPGA mainboard. Engineering prototype; native electrical/PCB checks are clean, but physical hardware validation is still required.**

Open `design/radian_panel.kicad_pro` with KiCad 10 and keep the project-local symbols/footprints with it. The authoritative panel PCB passes native ERC, DRC, filled-zone connectivity and schematic/PCB parity with zero findings. Current review fabrication outputs are in `fab/` and `radian_panel-fab.zip`.

## Current architecture
- Four-layer panel PCB, 1.6 mm thick, about 180.5 × 108 mm, with DIN/ventilation reliefs.
- Six Bourns 10 kOhm pots: **TENSION · DECAY · CHAOS · DRIVE · DELAY · REVERB**.
- Push encoder, MODE switch, four LEDs and five vertical mono patch jacks.
- Rack +12 V and desktop 12 V feed the panel converter; the mainboard still receives regulated VIN5.
- Rack input remains a 10-pin module-side Eurorack connector; −12 V is unused.
- Default MOD bypass preserves the original unipolar behavior; the optional bipolar MOD path still requires firmware calibration.
- PITCH scaling and stereo line-level outputs are unchanged.

## Direct panel-to-mainboard connection
The old J101…J116 cable-header bundle is retired. The boards now connect directly through two 2×10, 2.54 mm mezzanine pairs:
- **J17 main ↔ J100 panel:** Samtec IPT1-110-06-L-D ↔ IPS1-110-01-L-D, carrying VIN5/GND/VREF25, six pot wipers, CV/gate and stereo audio.
- **J18 main ↔ J101 panel:** the same Samtec pair, carrying 3V3/GND, encoder, MODE, LEDs, MIDI, PROGRAM/RESET and JTAG.

The shared source of truth is `../stack/panel-stack.json`. It specifies 19.99 mm fully mated spacing, 20.45 mm maximum spacing and a ~20.0 mm support-stack target. Standoffs/supports carry structural load; the connectors are not structural fasteners.

The final native boards have 40/40 mating pins matched by net and assembled XY, with 1.02 mm mainboard drills and 1.04 mm panel drills. Exact connector MPNs are present in both BOMs. Real connector seating, retention and enclosure tolerance still require a physical first article.

## Case / enclosure
The retained desktop/Eurorack enclosure has been revised to match this panel. The old three macro holes are closed, six current control locations are present, MODE moves to (154, 57) mm, and the old raised MODE insert becomes the REVERB insert. The mainboard/support plane is shifted 0.46 mm for the 19.99 mm fully-mated Samtec stack. See `cad/RADIAN_P1_desktop_fit_study.step` and `reports/CASE_UPDATE.md`.
