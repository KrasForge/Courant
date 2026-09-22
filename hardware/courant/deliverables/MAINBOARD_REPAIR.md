> **Release synchronization: 2026-09-16.** Current native boards, fabrication-format exports and CAD are indexed in `../../RELEASE_SYNC_STATUS.md`. Earlier statements below about pre-repair exports are historical; electrical/physical validation limitations still apply.

# RADIAN mainboard — native repair, 2026-09-16

## Result
The corrected mainboard passes Backplane KiCad 10.0.6 native DRC with **0 errors, 0 warnings and 0 unconnected items** under the existing project rules. All error/warning/exclusion severities were requested. No check settings were weakened and no new exclusions were added.

This is a PCB geometry/connectivity and library/artwork correction, **not a fabrication release or an electrical design sign-off**.

## Executed changes
- Consolidated 12 groups of overlapping same-net through-vias, removing 13 redundant vias while retaining existing via centres.
- Removed 34 track segments and one additional unused via through native-checked cleanup trials.
- Trimmed/reanchored three branches to their actual intermediate connections: GND to its existing via, V1V8 to C113 pad 1, and adc_cs_n to its existing layer-transition via. Blind whole-segment removal failed checks and was reverted before the accepted localized repairs.
- Restored a local RadianMain.pretty library: 43 variants representing the existing embedded footprint geometry for 202 instances. This is consistency, not manufacturer footprint verification.
- Replaced 45 undersized generic pin labels with 1 mm pin numbers; moved 95 conflicting outline graphics to fabrication layers; repositioned conflicting text. Bottom C100–C137 references now sit horizontally beside their own components instead of being scattered away from them.

Final native board: **2,158 track segments and 299 vias** (formerly 2,192 and 313).

## Independent preservation checks
- All 746 pad definitions retain their original positions, sizes, holes, orientation, layers, attributes and pin/net assignments.
- All 202 footprint instance placements are unchanged.
- The 96 connected pad groups match the original board exactly using native connectivity data.
- Board outline, thickness and enabled layers are unchanged.
- The project .kicad_pro file is byte-identical, including rule limits and severity settings.
- Minimum nominal drill-edge spacing: **0.258511 mm**, against the existing 0.25 mm rule.
- Exported Excellon files: 350 plated + 4 non-plated holes; no coincident centres; minimum exported drill-edge spacing **0.258587 mm** after coordinate rounding.

Original PCB SHA-256: `0683ead4a73049f5a2276b2cd3bf6389199609574a67aab8e27f48040a18deec`.

## Tool provenance
Checks used Backplane_KiCad 10.0.6, source commit `1c193606eddedbf98f8c9af5100b5e8f79da603d`. Editing used the installed KiCad 10.0.6 Python API and narrowly scoped S-expression edits. The Backplane desktop GUI was not automated.

## Files and evidence
- `working/courant.kicad_pcb` and its matching project and `fp-lib-table` form the corrected standalone handoff.
- `reports/06_compact_refs/` contains the final working-copy native result.
- `reports/07_published/` contains the post-copy native check when applied to the repository.
- `reports/invariants.json`, `exported_drill_check.json`, `via_consolidation.json`, `safe_dangling_cleanup.json`, `branch_trimming.json`, `footprint_library_mapping.json` and the artwork logs document the tests and changes.
- `review_exports/` contains refreshed review-only Gerbers, Excellon drills/maps and native SVG/PNG previews. These are NOT an approved manufacturing package.
- `baseline/` preserves the original handoff before editing. Trial reports with nonzero counts are historical experiments, not final results.
- `scripts/` records the repair process; do not blindly rerun destructive generation scripts on a later board revision.

## Scope and remaining release gates
The existing project still ignores missing courtyards, track centering on vias, tuning-profile geometry, footprint filters and footprint-type mismatch checks. Zero findings refers to this unchanged profile.

No native .kicad_sch was supplied for the mainboard, so **mainboard ERC and schematic/PCB parity were not run**. Empty parity arrays in DRC are not a passed schematic comparison. Electrical correctness, FPGA constraints/timing/boot, power integrity, regulator layout adequacy, actual footprint/MPN correctness, thermal/fault behaviour and physical assembly remain separate validations.

A 0.2585 mm nominal drill spacing is not a fabrication-tolerance guarantee; confirm the actual fabricator's requirements. No component positions, values or nets were redesigned to make this result pass.

## Avoid stale outputs
The TypeScript generators, routing intermediates under `hardware/courant/dist`, earlier fab ZIPs, and the older assembly STEP / SVG exports have NOT been regenerated or certified by this repair. The older STEP still represents the original drill/copper artwork. Re-export from the corrected native board for new geometry-sensitive outputs. Keep the recorded repaired board as the baseline until generator output has been reconciled and revalidated.

No commit or push was made. Unrelated dirty files and the separate panel PCB were not changed.
