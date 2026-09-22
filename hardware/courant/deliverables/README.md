> **Release synchronization: 2026-09-16.** Current native boards, fabrication-format exports and CAD are indexed in `../../RELEASE_SYNC_STATUS.md`. Earlier statements below about pre-repair exports are historical; electrical/physical validation limitations still apply.

# Current native mainboard — 2026-09-16

The PCB in this folder passes Backplane KiCad 10.0.6 DRC: **0 errors, 0 warnings, 0 unconnected**, with unchanged project rules. Current counts: **2,158 track segments and 299 vias**. See `MAINBOARD_REPAIR.md` and `native_checks/drc.json`.

The assembly STEP, mechanical PDF/DXF, `dist/` PCB copies, 2D views, Gerbers, drills, placement data, BOM/netlist metadata and `dist/courant-fab.zip` have been regenerated from the current repaired native board. Use `hardware/refresh_outputs.py` for future review-export refreshes. Legacy route/reconstruction scripts are guarded from overwriting the authoritative native PCB.

**Not a manufacturing approval.** Component/footprint sign-off, FPGA operation/timing, electrical power integrity, thermal/fault behavior and physical assembly remain separate release gates.

The original handoff notes below are preserved as historical information; their old track/via counts are superseded above.

---

# Courant Rev A — handoff package

Standalone Artix-7 instrument board. **160 × 100 mm** on the Edge.Cuts
centreline (160.1 × 100.1 measured over the 0.1 mm stroke), 6 layers, 1.6 mm.
Four NPTH 3.2 mm mounting holes at (25,55), (175,55), (25,145), (175,145) —
150 × 90 mm spacing.
Routed and native-checked: **0 DRC errors, 0 warnings, 0 unconnected**, 2158 track segments,
4386.2 mm of copper, 299 vias, both ground planes uncut.

| File | What it is |
| --- | --- |
| `courant.kicad_pcb` | the board. KiCad 10 |
| `courant.kicad_pro` | project file — **open it alongside the board or you get KiCad's default design rules, not this board's** |
| `courant-assembly.step` | populated assembly, 3D. Board body, copper, silkscreen, soldermask and 183 of 202 component bodies |
| `courant-bom.csv` | bill of materials, 57 line items / 183 placements |
| `courant-netlist.txt` | 96 nets, extracted from the routed board |
| `courant-panel-interface.csv` | pinout of all 15 headers — the spec for building the front panel |
| `courant-mechanical.pdf` | outline, fabrication layer, silkscreen |
| `courant-outline.dxf` | board outline for mechanical CAD |
| `courant-schematic.svg` | schematic — 183 components, 739 pins, 532 wires, 248 net labels, 7038 x 6958 px vector |
| `courant-panel-hardware.md` | off-board parts, with `datasheets/` alongside |
| `courant-eurorack.md` | Eurorack status: what works as built, what changes, with values |
| `courant-source-design.ts` | the design source |

## Design rules

Default 0.15 mm track / 0.15 mm clearance, vias 0.55 / 0.25 mm. Power class
0.40 mm track, Ground 0.30 mm. These are set by the FTG256's 1.0 mm ball pitch:
escaping between two balls needs width + 2 × clearance inside a 0.5 mm gap, and
0.15 + 0.30 = 0.45 mm fits where KiCad's 0.2 mm defaults (0.6 mm) cannot.
0.25 mm drill through 1.6 mm is a 6.4:1 aspect ratio — inside any standard
6-layer process.

## Notes on three of these

**The schematic is rendered by `scripts/schematic.py`, not by tscircuit.**
`tsci export -f schematic-svg` and `-f schematic-pdf` both emit a near-empty
sheet for this design — about ten kilobytes, twenty text elements for two
hundred components — while the circuit JSON behind them holds all 183
components, 739 ports and 532 traces. The data was never missing, only the
drawing, so the drawing is done here. It is complete and to scale; it is not
arranged for signal flow, because tscircuit places symbols in declaration
order and no autolayout turns that into a drafted sheet.

**Every placement has a manufacturer part number**, and each one was checked
against live stock rather than inferred. Two families are covered by one
verified member plus the manufacturer's own value coding, noted on the line:
the Murata C0G run and the Yageo RC0603FR series.

**The panel hardware in `courant-panel-hardware.md` is a proposal.** The design
names no off-board parts and the right ones depend on a panel format that does
not exist yet, so those selections are specified to be electrically correct and
mechanically ordinary — a starting BOM, not a decision already taken. The four
that are sourced have datasheets in `datasheets/`.

## One design fix made while preparing this

R10 was **25 kΩ**, which is on no E-series grid and is not a stocked 1 % part —
a search for it returns 24.9 kΩ. It sets the V1 rail through the TPS62130's
0.8 V reference, so it is now **24.9 kΩ**: 0.8 x (1 + 24.9/100) = 0.9992 V
against a 1.000 V target, nearer than the 1 % resistors can hold. Fixed in
`design.ts` and in the board; `npm run check` passes.

## Before ordering

U1 is **XC7A50T-1FTG256I**, swapped from the XC7A35T-1FTG256C. The pin
compatibility is verified, not assumed: AMD's package files for the two parts
in FTG256 — both kept in `reference/` — are byte-identical from line 2 to the
end. All 256 balls, their banks, I/O types and no-connect flags match; the only
difference in either file is the device name on the header line. That makes the
swap a part number and nothing else, and it is the cheaper part besides
($67.01 against $118.75 at JLCPCB, both in stock) with 57% more logic and an
industrial temperature range.

One check is still worth doing and cannot be done from here: a Vivado synthesis
run against the A50T using the generated `courant_rev_a.xdc`. It will reject
any invalid ball assignment outright, and it confirms timing still closes —
the speed grade is unchanged at -1, so it should.

## Native repair and current files

See `../../REPAIR_STATUS.md` and `../reports/native/`. The local `RadianMain.pretty` snapshots and `fp-lib-table` must travel with the board. Both routed board copies and the manufacturing-format review exports were replaced on 2026-09-16. Native checks are not electrical or physical product validation.
