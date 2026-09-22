# Active RADIAN hardware synchronized — 2026-09-17

The canonical mainboard is `courant/deliverables/courant.kicad_pcb`; the canonical panel is `panel/design/radian_panel.kicad_pcb`. Both use project-local footprint libraries and are protected by `NATIVE_BASELINE.json`.

This revision adds three dedicated FX pots and replaces the old panel/mainboard header-harness bundle with two direct Samtec mezzanine pairs. J17/J18 on the mainboard are IPT1-110-06-L-D; J100/J101 on the panel are IPS1-110-01-L-D. `stack/panel-stack.json` is the shared pinout/mechanical contract.

Native validation after the final connector-footprint/drill update: mainboard DRC 0 violations / 0 unconnected; panel ERC 0, DRC 0, unconnected 0, schematic/PCB parity 0. The final native connector pads did not move relative to the routed generic stack pads; the exact drill recommendations are 1.02 mm main and 1.04 mm panel.

The two boards were compared in assembled product coordinates: all 40 connector pins have the same net on both ends and matching XY positions. The selected Samtec combination is represented as 19.99 mm fully mated, 20.45 mm maximum PCB spacing, with a nominal ~20.0 mm mechanical support target.

`hardware/refresh_outputs.py --board all` is the required synchronization path for Gerbers, Excellon drills, placement files, BOM/netlist metadata, previews and review ZIPs. These outputs remain engineering/review artifacts rather than a claim of physical production qualification.

Remaining physical gates are first-article connector/support fit, retention, enclosure tolerance, electrical power/thermal/fault tests and actual target-FPGA implementation/timing/bring-up. No Git commit, push or reset was performed by this synchronization.

## Case synchronization
The enclosure/product CAD is now CASE-P2-DIRECT-STACK. Six control openings and labels are modeled, MODE is relocated, the former MODE insert is the REVERB insert, the mainboard is shifted +0.46 mm to the 19.99 mm fully-mated plane, and front/rear support geometry follows that plane. Exported STEP geometry passes independent shaft-hole/support/Samtec-envelope checks. Current case validation is `panel/reports/case_direct_stack_update.json`.
