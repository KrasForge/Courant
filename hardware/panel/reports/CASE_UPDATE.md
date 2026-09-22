# RADIAN case P3 two-row control update — 2026-09-18

The enclosure/product CAD now matches the two-row six-control panel and direct Samtec board stack.

- Primary row: **TENSION · DECAY · CHAOS** with 23 mm reference knobs at **(38,96), (76,96), (114,96) mm**.
- FX row: **DRIVE · DELAY · REVERB** with 14 mm reference knobs at **(66,70), (88,70), (110,70) mm**.
- The engraving reinforces the hierarchy: primary labels sit above the large row; a compact **FX** group mark sits left of the lower row with the three effect labels beneath it.
- All six controls remain standard rear-facing Bourns PTV09A4 potentiometers on the PCB; knob size is an enclosure/assembly choice.
- The three legacy macro holes are closed and six current 6.8 mm shaft openings are modeled in the main faceplate.
- MODE is restored to the original raised insert at **(150.5,84.5) mm**.
- The encoder remains at **(42,43) mm** and the right-side jack/LED layout remains unchanged.
- Mainboard remains shifted **+0.46 mm toward the panel** for the **19.99 mm fully mated** PCB-to-PCB gap.
- Four front supports terminate at **z = -29.54 mm** and the rear spacer set reaches **z = -31.14 mm**; the rear guard remains unchanged.
- The assembly imports the current **exact-part native mainboard STEP**. All 180 BOM placements now carry production MPN metadata and a resolved 3D model; the retired J5–J15 edge headers remain absent. Re-running the full enclosure intersection check with this populated STEP still reports zero panel↔mainboard clashes and zero unintended enclosure intersections. Mainboard IPT1 and panel IPS1 are represented by drawing-derived 20-contact STEP reference models.
- The former generic panel utility headers are now selected parts: J200 Wurth 61201021621; J201/J306 Molex 22-27-2021; J202 Molex 22-27-2061; JP1 Wurth 450301014042 SPDT. The panel CAD imports selected-part Wurth/Molex STEP geometry for these parts and reports no panel↔mainboard clash.
- **The final product CAD no longer uses the old white generic component envelopes.** `RADIAN_actual_parts_full_assembly.step`, `RADIAN_P1_desktop_fit_study.step`, and `RADIAN_P1_case_updated.step` are assembled from component-filtered STEP exports of the **native KiCad panel and mainboard**, so component placement/orientation comes directly from the PCBs.
- Prominent panel hardware now uses real/open or package-accurate geometry: aligned Bourns PTV09A-family CAD for RV1–RV6 (20 mm selected-shaft configuration), PJ398SM/Thonkiconn mechanical CAD with knurled nut for J301–J305, Omron B3F package CAD for SW3/SW4, and a 3 mm green LED package for D10–D13. Standard IC/passive packages and selected Wurth/Molex parts likewise come from the models attached to KiCad.
- The remaining non-vendor-download solids are explicitly **MPN-specific drawing-derived reference models**, not generic boxes: ENC1 PEC11R-4220F-S0024, SW1 E-Switch 100SP1T1B1M2REH, Samtec J100/J101/J17/J18, and mainboard Molex J1–J4. Model provenance is recorded in `stack/actual_parts/actual_parts_report.json`.
- CAD validation reports zero control-hole conflicts, zero panel-component/mainboard clashes and zero unintended enclosure intersections. The rounded Samtec REF dimensions create a 0.01 mm housing-interface closure in the reference solids; the stack is separately checked at 19.99 mm PCB gap, 3.82 mm nominal geometric insertion and 0.84 mm nominal contact wipe.

The selected enclosure endpoints are Switchcraft 722A for desktop 12 V and Same Sky SDS-50J for MIDI; both remain short-harness/chassis parts and require physical case-retention and strain-relief validation. The canonical full-product CAD now uses KiCad-placed actual/package component geometry rather than the former generic white component envelopes. The real/open PTV09A-family, PJ398SM, Omron B3F and LED models plus package-accurate IC/passive geometry are used directly; explicit drawing-derived references remain for PEC11R, the selected E-Switch and vendor-gated Samtec/Molex connectors. `stack/actual_parts/actual_part_collision_report.json` reports zero unintended panel↔mainboard and rear-guard/dock collisions.

The final STEP is exported as individually colored physical solids so CAD viewers no longer substitute default white for component groups. Round-trip validation reports 715 colored children and zero uncolored/default-white children. U8 on the mainboard is separately pin/center-aligned to its native footprint before the assembly export.

This is a checked reference mechanical model, not physical fit certification. The connector CAD is reconstructed from Samtec's official drawings because the vendor STEP download is email-gated. First-article connector seating/retention, knob/nut/washer stack and manufacturing tolerance remain required.
