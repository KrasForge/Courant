# RADIAN Panel P1 — integration status, 2026-09-17

The current panel is the six-pot direct-stack revision. Native KiCad 10.0.6 ERC, DRC, filled-zone connectivity and schematic/PCB parity all pass with zero findings.

The panel no longer connects to the mainboard through individual function harnesses. J100 and J101 are Samtec IPS1-110-01-L-D sockets that mate directly with mainboard J17/J18 Samtec IPT1-110-06-L-D terminal strips. The two 20-pin interfaces carry power, six pot controls, CV/gate, audio, encoder/MODE/LEDs, MIDI and service/JTAG. Only truly off-board functions such as the retained MIDI DIN and desktop inlet still use short leads.

`../stack/panel-stack.json` defines the common pin map, pad geometry and mechanical stack: 19.99 mm fully mated, 20.45 mm maximum and ~20.0 mm nominal support spacing. Standoffs/support hardware, not the connectors, must carry structural load.

Current fabrication-format outputs are in `fab/` and `radian_panel-fab.zip`; current reports are in `reports/native/`. They are engineering outputs. Real connector seating, enclosure tolerances, support hardware, power/load/thermal/fault behaviour and hardware bring-up remain first-article checks.

## Mechanical integration
The reference enclosure CAD is synchronized to STACK-P2: the two-row six-control surface, MODE on its raised insert, shifted mainboard/support planes, and drawing-derived **20-contact Samtec IPT1/IPS1 models** on both boards. `../stack/validate_direct_stack.py` verifies all 40 contacts pin-by-pin for physical XY, pin number, signal net, drill size, board side and attached 3D model. The assembled CAD also checks every modeled panel component/pin envelope against the mainboard assembly and reports no unintended panel↔mainboard clash. Samtec's rounded REF dimensions close the housing interface by 0.01 mm in the reference solids; the official mated-view values independently give 3.82 mm nominal geometric insertion and 0.84 mm contact wipe. Physical first-article tolerance/retention remains required.
