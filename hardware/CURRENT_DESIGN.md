# RADIAN current hardware baseline — 2026-09-18

The repaired native KiCad boards are authoritative. Do not regenerate them in-place from legacy routing/export writers.

## Canonical native files
- Mainboard: `courant/deliverables/courant.kicad_pcb`
- Mainboard project/library: `courant/deliverables/courant.kicad_pro`, `courant/deliverables/fp-lib-table`, `courant/deliverables/RadianMain.pretty/`
- Panel/interface board: `panel/design/radian_panel.kicad_pcb`
- Panel project/schematic: `panel/design/radian_panel.kicad_pro`, `panel/design/radian_panel.kicad_sch`
- Shared board-stack contract: `stack/panel-stack.json`

## Native validation
- Mainboard Backplane KiCad 10.0.6 DRC: 0 violations, 0 unconnected.
- Panel Backplane KiCad 10.0.6 ERC: 0 violations.
- Panel DRC: 0 violations, 0 unconnected, 0 schematic/PCB parity findings.
- Mainboard has no native `.kicad_sch`, so mainboard ERC/parity cannot be claimed.

## Mainboard exact-part reconciliation
The canonical mainboard is now reconciled to its production BOM rather than carrying generator-era package aliases. All **180 referenced placements** have Manufacturer and MPN fields and a resolved project-local 3D model. Important identities are explicit: **U1 = AMD/Xilinx XC7A50T-1FTG256I (FTG256)**, **U5 = TI REF3125AIDBZR (SOT-23)**, **Y1/Y2 = Abracon ASE 100 MHz / 12.288 MHz 3225 oscillators**, **L1–L3 = Changjiang FNR4030S1R0MT**, **D10–D12 = Nexperia BAT54S,215**, and **D20 = Diodes Incorporated 1N4148W-7-F**. Service connectors are **J1/J3/J4 = Molex 22-23-2021**, **J2 = Molex 22-23-2061**, while J17/J18 remain Samtec IPT1-110-06-L-D.

This reconciliation did **not** move copper, vias, footprints, pads, nets, or component orientations. The only intentional native package change is the Molex J1–J4 through-hole drill correction from **1.00 mm to 1.02 mm** plus their actual connector courtyards. `courant/reports/mainboard_exact_parts.json` records the proof. Mainboard DRC remains 0 violations / 0 unconnected, and the exact-part STEP has been rechecked in the product assembly with zero panel↔mainboard clashes and zero unintended enclosure intersections. Molex J1–J4 and Samtec J17/J18 connector solids are drawing-derived reference models; physical first-article fit remains required.

## Actual-part product CAD
The canonical product assembly is now rendered from **native KiCad-placed component STEP groups**, not the old white envelope/block references. The final assembly is `panel/cad/RADIAN_actual_parts_full_assembly.step`, and `RADIAN_P1_desktop_fit_study.step` / `RADIAN_P1_case_updated.step` are regenerated from the same actual-part assembly.

Prominent panel hardware now uses real/open or package-accurate CAD: the six **Bourns PTV09A-series** potentiometers use aligned real family geometry trimmed to the selected 20 mm shaft; J301–J305 use the **PJ398SM/Thonkiconn** open mechanical model with knurled nut; SW3/SW4 use the maintained **Omron B3F-1000** package model; D10–D13 use a real 3 mm green LED package model. Wurth/Molex production connectors, standard IC/passive packages, and all reconciled mainboard packages are likewise exported from the component models attached to the native KiCad boards.

The remaining non-vendor-download solids are explicitly MPN-specific **drawing-derived reference geometry**, not generic boxes: ENC1 Bourns PEC11R-4220F-S0024, SW1 E-Switch 100SP1T1B1M2REH, Samtec J100/J101/J17/J18, and Molex mainboard J1–J4. `stack/actual_parts/actual_parts_report.json` records this distinction. No generic white component-envelope geometry is used in the final actual-part assembly.

## Front-panel controls and direct stack
The panel has six 10 kOhm macro pots in two rows. **TENSION · DECAY · CHAOS** are the widely spaced primary controls intended for 23 mm knobs at (38,96), (76,96), (114,96) mm; **DRIVE · DELAY · REVERB** are the tighter FX row intended for 14 mm knobs at (66,70), (88,70), (110,70) mm. The PCB uses the same Bourns PTV09A4 rear-facing pot footprint for all six; knob diameter is an enclosure/assembly choice. The push encoder, MODE switch and four LEDs remain. Internal legacy nets POT_PITCH/POT_DECAY/POT_TIMBRE remain unchanged; the three FX controls use POT_DRIVE/POT_DELAY/POT_REVERB.

The former per-function panel harness architecture is retired. The corresponding legacy mainboard edge headers **J5–J15 have now been physically removed from the canonical PCB**, along with their dead-end copper branches; J1–J4 remain as service/debug access. Two 20-pin direct mezzanine sites now mate panel to mainboard: J17↔J100 (power/analog/CV/audio) and J18↔J101 (digital/MIDI/service). The selected pair is Samtec **IPT1-110-06-L-D** on the mainboard and **IPS1-110-01-L-D** on the panel. The shared contract targets 19.99 mm fully mated / 20.45 mm maximum PCB spacing and a nominal 20.0 mm assembly support spacing. `stack/validate_direct_stack.py` now checks all **40/40 physical contacts** pin-by-pin for native-board XY, pin number, net name, recommended drill size, board side and attached 3D reference model. It also checks the published -06/-01 insertion/wipe geometry and panel solder-tail clearance. All 40 contacts pass.

## Exact panel-side service / off-board connector parts
The former generic panel utility headers have been replaced by selected production parts without moving their proven copper endpoints: **J200 = Wurth 61201021621** keyed 2×5 Eurorack power header; **J201 = Molex 22-27-2021** 2-circuit friction-lock desktop-power harness connector; **J306 = Molex 22-27-2021** 2-circuit friction-lock isolated-MIDI harness connector; **J202 = Molex 22-27-2061** 6-circuit JTAG service connector; **JP1 = Wurth 450301014042** SPDT mini slide switch. JP1 uses the real switch numbering: pin 1 common = MOD_IN, pin 2 = MOD_BIPOLAR, pin 3 = MOD_RAW. The selected chassis endpoints are **Switchcraft 722A** for 12 V desktop power and **Same Sky SDS-50J** for MIDI; these remain short off-board harness connections because those parts live in the enclosure rather than between the two PCBs.

## Actual-part CAD assembly
The current product CAD no longer uses the old generic white component envelopes for either PCB. Component placement is exported directly from the native KiCad boards and assembled in `stack/render_actual_part_cad.py`, so the CAD and KiCad placements share one source of truth.

Prominent panel parts now use real/open or package-accurate geometry: the six Bourns PTV09A-family potentiometers use real PTV09A mechanical CAD aligned to the selected **PTV09A-4020F-B103** footprint and trimmed to the selected 20 mm shaft; J301–J305 use PJ398SM/Thonkiconn mechanical CAD including the knurled-nut assembly; SW3/SW4 use the Omron B3F-1000 package model; D10–D13 use 3 mm green LED package geometry; U1/U2/D4 and all R/C/fuse/SMB parts use maintained package STEP geometry. Selected Wurth/Molex models remain in use.

The mainboard is likewise imported as KiCad-placed component groups using its exact/package STEP library rather than rendered as one flat white compound. The remaining non-vendor mechanical references are explicit and documented, not generic placeholders: **ENC1 PEC11R-4220F-S0024** and **SW1 100SP1T1B1M2REH** use drawing-derived full mechanical references; the Samtec direct-stack and mainboard Molex service connector solids are also drawing-derived references because vendor STEP files were unavailable.

Canonical actual-part assembly:
- `panel/cad/RADIAN_actual_parts_full_assembly.step`
- `panel/cad/RADIAN_P1_desktop_fit_study.step` (same current actual-part assembly)
- `panel/cad/RADIAN_direct_stack_mated.step`
- `panel/previews/actual_parts_full_assembly_iso.png`
- `panel/previews/actual_parts_full_assembly_front.png`
- `panel/previews/actual_parts_full_assembly_side.png`

`stack/actual_parts/actual_part_collision_report.json` is PASS: zero unintended panel↔mainboard collisions and zero rear-guard/desktop-dock collisions. Model-only reconciliation was also checked against the pre-edit native panel geometry: copper, tracks/vias, pad positions/sizes/drills/nets, footprint positions/orientations and board sides are unchanged.

The final STEP exporter works at **solid level**, not compound-group level, because STEP compound colors were being dropped by the CAD round trip and appearing as viewer-default white. The current full assembly contains **715 colored STEP children, 0 missing colors and 0 near-white default children**. Light cream is used only for the physical natural-nylon Molex connector bodies. U8/H11L1M is separately proven: the standard DIP-6 geometry is translated **(-3.81,+2.54) mm in STEP coordinates**, which under KiCad's Y inversion maps all six lead centers exactly to the native U8 pads; a placed U8 STEP export centers at **(48.000,-139.000) mm**, exactly matching the native footprint center.

## Current derived files
`hardware/refresh_outputs.py` regenerates current review Gerbers/drills, placement, BOM/netlist metadata, native board copies, 2D views, mechanical PDF/DXF and fabrication ZIPs from the canonical boards. `CURRENT_EXPORTS.json` records source hashes and commands. `NATIVE_BASELINE.json` protects the verified native copper.

These are electrically/geometry-checked engineering outputs, not a claim of physical production qualification. The remaining gates require real hardware: bench-fit the Samtec stack and ~20 mm support stack, verify connector seating/retention and enclosure tolerance, run power/load/fault/thermal measurements, and complete FPGA implementation/timing on the target device.

## Enclosure / case CAD
The product enclosure CAD is synchronized with the two-row six-pot/direct-stack revision. The faceplate carries three large-knob primary controls and three smaller-knob FX controls; primary labels sit above the large row and the lower row is marked as a compact FX group. MODE is restored to its original raised insert at (150.5,84.5) mm. The mainboard/support stack remains shifted 0.46 mm toward the panel for the 19.99 mm fully-mated Samtec PCB gap. Current assembly: `panel/cad/RADIAN_P1_desktop_fit_study.step`; validation: `panel/reports/case_direct_stack_update.json`. The Samtec direct-stack connectors use **drawing-derived IPT1/IPS1 20-contact reference models** attached to the native KiCad footprints, while J200/J201/J306/J202/JP1 use the selected Wurth/Molex part geometry in the panel CAD and native KiCad 3D view. Nominal CAD checks report zero control-hole conflicts, zero panel-component/mainboard clashes and zero unintended enclosure intersections. The published rounded REF dimensions produce a 0.01 mm housing-interface closure in the reference solids; insertion and contact wipe are checked independently against Samtec's mated-view dimensions. Physical first-article tolerance and retention remain release gates.
