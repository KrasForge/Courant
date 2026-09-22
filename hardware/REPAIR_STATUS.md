# RADIAN hardware status — 2026-09-18

The active hardware is the six-control, direct-stack revision. The native KiCad boards are authoritative engineering prototypes; the old panel/mainboard cable-harness topology is retired.

| Native check (KiCad 10.0.6) | Mainboard | Panel |
|---|---:|---:|
| DRC violations | 0 | 0 |
| Unconnected items | 0 | 0 |
| Schematic ERC violations | N/A: no native mainboard schematic | 0 |
| Schematic/PCB parity findings | N/A | 0 |

## Current revision
- Panel controls: TENSION, DECAY, CHAOS, DRIVE, DELAY, REVERB; push encoder; MODE; four LEDs.
- MCP3208 uses all eight channels. DRIVE/DELAY/REVERB use the three formerly grounded ADC channels through 1 kOhm / 10 nF input filters.
- FX macros are handled by read-modify-write in `panel_ctrl.vhd`, preserving the other packed FX-register fields.
- Mainboard/panel mate directly with two 2×10 2.54 mm connectors. There is no per-function panel-to-mainboard cable bundle.
- Legacy panel edge headers **J5–J15 have been removed from the mainboard**, and the now-unused copper stubs were pruned. J1–J4 remain for service/debug access.
- Main J17/J18: Samtec IPT1-110-06-L-D. Panel J100/J101: Samtec IPS1-110-01-L-D.
- Shared stack contract: `stack/panel-stack.json`, 19.99 mm fully mated, 20.45 mm maximum, nominal 20.0 mm support spacing.
- Final native pin proof: 40/40 mating pins match both net name and assembled XY; maximum computed XY delta is floating-point noise (<2e-14 mm).
- Generic panel utility headers are retired: J200 = Wurth 61201021621, J201/J306 = Molex 22-27-2021, J202 = Molex 22-27-2061, and JP1 = Wurth 450301014042 SPDT. Their routed endpoints were preserved, so this is a selected-component/footprint change rather than a wholesale reroute.
- Final CAD visualization no longer uses generic white component envelopes: both boards are exported from native KiCad component placements into `RADIAN_actual_parts_full_assembly.step`; actual/open PTV09A, PJ398SM, Omron B3F and LED geometry plus package-accurate production models are rendered. Remaining MPN-specific drawing-derived solids are explicitly documented.
- Mainboard production-part reconciliation is complete: all 180 referenced placements now carry Manufacturer + MPN and a resolved 3D model. U1/U5/Y1/Y2 and the service connectors now use semantic package identities matching the BOM; J1/J3/J4 are Molex 22-23-2021, J2 is 22-23-2061. No copper/pad/net/placement routing changed; only the selected Molex service connectors' finished-hole drills changed from 1.00 to 1.02 mm and their courtyards/models were corrected.
- Final CAD fidelity pass is complete. The old generic white PCB-component envelopes are no longer used by the canonical product assembly. Both boards are assembled from KiCad-placed component STEP groups. Panel pots/jacks/service switches/LEDs and small packages use real/open or maintained package geometry; ENC1/SW1 and vendor-gated connector models are explicitly drawing-derived mechanical references. Actual-part collision validation passes with zero unintended board-to-board or rear-guard/dock clashes.
- The remaining white-render artifact was traced to STEP **compound colors being discarded**. The canonical exporter now emits each physical solid as a colored child; round-trip audit reports **715/715 colored children, 0 missing colors, 0 default-white children**. Only actual natural-nylon Molex housings remain light cream.
- U8/H11L1M alignment is now mathematically locked: six model lead centers exactly match six native pads after KiCad Y inversion; placed U8 STEP center is exactly (48.000,-139.000) mm versus the native (48.000,139.000) PCB center.

## Current outputs
Mainboard: `courant/deliverables/courant.kicad_pcb` and derived `courant/dist/` outputs. Panel: `panel/design/radian_panel.kicad_pcb` and derived `panel/fab/` / `panel/radian_panel-fab.zip`. `hardware/refresh_outputs.py` regenerates review/fabrication-format outputs only after native checks pass.

The regenerated main manufacturer BOM now contains **180 placements** after removal of J5–J15; J17/J18 are the exact Samtec IPT1 part. The panel BOM contains the exact IPS1 mate at J100/J101 plus the selected Wurth/Molex utility connectors and JP1 switch listed above.

## Validation still requiring physical hardware
KiCad/RTL checks do not prove connector seating under real tolerances, enclosure/support fit, insertion/retention force, power integrity, current/thermal/fault behaviour or actual FPGA timing on silicon. Build a first article with a ~20.0 mm board support stack, inspect full connector seating, and bench-test power/audio/control behaviour before ordering production quantity.

No Git reset/revert/commit was used for this revision; pre-existing worktree changes were preserved. Backups from the direct-stack and connector-finalization work are under `hardware/_backups/`.

## Current case
The case CAD is updated for the active six-pot/direct-stack hardware. The old three-macro front geometry is retired; the Samtec stack is modeled at 19.99 mm PCB spacing with ~20.0 mm support geometry. `panel/cad/RADIAN_P1_desktop_fit_study.step` is the current product assembly and `panel/reports/CASE_UPDATE.md` summarizes the mechanical changes. Physical first-article fit/retention remains unverified.
