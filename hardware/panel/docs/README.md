# RADIAN Panel / Interface P1 — engineering handoff

Revision P1 direct-stack / production-connector update, 2026-09-18. Built around the existing oxide-red 40 HP / 3U RADIAN front panel and the Rev F.1 desktop dock. The mainboard is electrically extended for the direct stack and three FX-pot ADC channels.

## 1. Honest completion status

This is a **signal-routed electrical and mechanical prototype design**, not another set of blank carrier-board rectangles. There is one electrical graph, a native KiCad project with five child schematic sheets, explicit part-to-pad net assignments, actual copper segments/vias, panel drilling references, and a corresponding 3D reference assembly.

It remains an engineering prototype. Native Backplane KiCad 10.0.6 has now loaded and checked the files: ERC, DRC, ground connectivity and schematic/PCB parity have zero findings. The inner GND zones are filled. Electrical function, component selection and physical/thermal/fault performance remain unverified. See `../reports/native/` and `../../REPAIR_STATUS.md`.

The five schematic sheets use named global nets and exact pin-labelled blocks. The current PDF is exported by native KiCad; a signal-flow and circuit-function review is still required.

## 2. What is on this single PCB

**Controls:** RV1–RV6 are 10 kOhm linear Bourns PTV09A-4020F-B103 pots: TENSION, DECAY, CHAOS, DRIVE, DELAY and REVERB. ENC1 is a Bourns PEC11R-4220F-S0024 encoder with push switch. SW1 is an E-Switch 100-series SPDT ON-ON switch and D10–D13 are 3 mm status LEDs. All six pot wipers are filtered at the mainboard ADC inputs.

**Patch connections:** J301 PITCH, J302 MOD, J303 GATE, J304 LINE L, J305 LINE R. All five use vertical WQP518MA/PJ398SM-style mono sockets. Input normal contacts are grounded when unplugged; output normal contacts are left unused. The mandatory under-barrel clearance hole is included in each footprint. The previous right-angle Same Sky jacks are not used in this planar board design.

**MIDI:** J306 is now an exact Molex KK-254 **22-27-2021** 2-circuit friction-lock header rather than generic pins. A short two-wire harness goes to the enclosure-mounted Same Sky **SDS-50J** DIN receptacle, pins 4 and 5 respectively. Those nets reach the mainboard through J101↔J18. Do not connect DIN pin 2/shield to PCB ground: the mainboard optocoupler provides the intended input isolation. The old DIN carrier PCB remains retired; the SDS-50J retainer/case fit still needs first-article verification.

**Power:** J200 is the exact Wurth **61201021621** keyed 2×5 WR-BHD Eurorack header. J201 is an exact Molex KK-254 **22-27-2021** 2-circuit friction-lock header for the short lead to the selected chassis-mounted Switchcraft **722A** 12 V DC inlet. Independent input fuses, diode-OR source combination, transient suppressor and the TPS54302 buck converter follow. Regulated VIN5 reaches the mainboard through J100↔J17.

**Optional modulation conditioning:** OPA2192 buffer/summing/gain stage selected by the exact Wurth **450301014042** SPDT mini slide switch at JP1. The removable 3-pin shunt is gone. JP1 is not the front MODE switch.

**Internal service:** J202 is an exact Molex KK-254 **22-27-2061** 6-circuit friction-lock JTAG header, alongside PROGRAM/RESET switches. These remain behind the panel; access requires removing the module. Their circuitry does not add level translation or new functions to the mainboard.

## 3. Mainboard connection

The former individual panel/mainboard cable headers are retired. Panel J100 mates directly with mainboard J17 and panel J101 mates with mainboard J18. Both are 2×10 2.54 mm Samtec mezzanine pairs defined by the shared `../stack/panel-stack.json` contract.

J17/J100 carries VIN5, GND, VREF25, all six pot wipers, PITCH/MOD/GATE and LINE L/R. J18/J101 carries V3V3/GND, encoder, MODE, four LEDs, MIDI, PROGRAM/RESET and JTAG. The final native boards have all 40 physical pins matched by both net name and assembled XY coordinate.

Mainboard connector MPN: **IPT1-110-06-L-D**. Panel connector MPN: **IPS1-110-01-L-D**. Fully mated PCB spacing is 19.99 mm, maximum specified spacing is 20.45 mm, and the mechanical support target is about 20.0 mm. Standoffs/supports carry structural load. `mainboard_harness.csv` is retained only as a deprecation pointer to `mainboard_stack.csv`.

## 4. Power architecture and important change

**Desktop input for P1 is regulated 12 V, not the earlier direct 5 V inlet proposal.** This choice lets the same protected conversion path serve rack and desktop operation. The selected chassis endpoint is a centre-positive Switchcraft **722A** 2.0 mm DC power jack; it connects to J201 with a short two-wire harness. The case opening/retention and harness strain relief still require first-article verification. The mainboard input remains regulated **5 V**; never connect either external 12 V source directly to main J1.

J200 uses the exact Wurth **61201021621** keyed module-side **10-pin** WR-BHD header:

| Pins | Connection |
|---|---|
| 1, 2 | −12 V position, intentionally NC |
| 3–8 | GND |
| 9, 10 | rack +12 V |

Use a verified **16-pin bus to 10-pin module** ribbon cable. Red stripe identifies the −12 V edge even though this module does not consume that rail. Inspect and continuity-check both ends. The module uses none of the extra bus +5 V/CV/gate signals. A shroud alone is not an assurance that a third-party cable or bus header is wired correctly. This 10-pin choice also avoids bringing the extra 16-pin bus signals into a connector that could be incorrectly reversed.

F1 and F2 precede Schottky OR diodes. Both source grounds are common. The diodes provide positive-rail backfeed blocking in their intended polarity; this is **not galvanic isolation**, not an ideal-diode power mux and not a complete certification against cable faults. The higher effective source voltage will carry the load. Avoid connecting both supplies during initial testing.

The TPS54302 circuit uses the TI 5 V application topology with 10 uH inductance, two 22 uF output capacitors, boot capacitor, enable divider and feedback/feed-forward network. Ideal nominal feedback arithmetic gives about **5.079 V**, before component/IC tolerance and cable losses. The 3 A value is the converter IC's design target, **not a measured RADIAN load or guaranteed board rating**. The actual FPGA current, bus budget, dropout at startup, current-limit behavior, input diode losses, copper temperature and switcher stability require review and measurement.

The default fuse entries are explicitly `SELECT 2 A >=32 V 1206 fuse`. Their final ordering codes, derating, inrush capability and coordination with the SMBJ15A TVS are unresolved. Capacitor rows marked SELECT similarly need exact parts, voltage/DC-bias capacitance checks and purchasing review. Do not treat a nominally correct footprint as selection of a safe part.

## 5. Signal behavior

PITCH keeps the existing mainboard input scaling and the original 0–5 V operating range. It is not silently divided by two or offset, so the existing pitch convention is preserved. Wider voltage/fault behavior still needs verification of the mainboard front end.

JP1 selects MOD with a real SPDT switch:

| JP1 contact | Behavior |
|---|---|
| **pin 1 ↔ pin 3** | `MOD_RAW` directly to `MOD_IN`; original unipolar 0–5 V behavior |
| **pin 1 ↔ pin 2** | `MOD_BIPOLAR` to `MOD_IN`; nominal `Vout = 0.5 × Vin + VREF25` |

Nominal bipolar mapping is −5/0/+5 V → 0/2.5/5 V. The op-amp has finite output swing and the real stage cannot exactly reach its rails under load. The sampled resistor-only tolerance report is not a circuit simulation and does not include op-amp swing, offset, bandwidth, saturation, supply or ADC errors. Firmware must know that zero external modulation maps near ADC midscale. Change JP1 only with power off; calibrate the usable range on hardware.

LINE L/R are the original DAC line outputs, not amplified modular outputs and not headphone drivers. A mono patch plug does not change their electrical level. Gate conditioning and MIDI optoisolation remain on the mainboard; this panel does not duplicate them. Test plug insertion, shorts, back-driven outputs, and powered/unpowered input faults before attaching other equipment.

## 6. Mechanical interface

Panel: 202.8 × 128.5 × 2 mm, current nominal 40 HP format. New board envelope: **180.5 × 108 × 1.6 mm**, with intentional DIN/cradle and ventilation windows and edge reliefs around the mainboard support columns. Board front is at **z = −8 mm** relative to the panel rear; board back is −9.6 mm. Coordinates in `design.json`, the DXF and CSV use x right/y up as seen from the front. Native KiCad uses a reflected y coordinate (`128.5 − y`).

The active controls use two rows: TENSION/DECAY/CHAOS at **(38,96), (76,96), (114,96) mm** with 23 mm reference knobs, and DRIVE/DELAY/REVERB at **(66,70), (88,70), (110,70) mm** with 14 mm reference knobs. MODE is on the retained raised insert at **(150.5,84.5) mm**. The mainboard PCB plane moves 0.46 mm toward the panel so the Samtec pair sits at 19.99 mm fully mated; the four front supports are shortened and the rear spacers extended by the same amount. The rear guard and outer desktop dock body remain unchanged.

**The CAD is a dimensional/reference study.** J200/J201/J306/J202/JP1 now use selected-part 3D geometry in the panel assembly (Wurth/Molex), while the Samtec direct-stack models remain drawing-derived. The enclosure-mounted Switchcraft 722A and SDS-50J interfaces are still case/reference interfaces rather than a claim of vendor-CAD-certified assembly. Cable plugs, thread/retention details, fastener torque, tolerances and insertion loads are not certified. The encoder rear spacer, jack rear shims and mode rear spacer are proposed mounting-stack allowances to be sample-tested. Knobs and nuts are only reference geometry; exact knobs, nuts/washers, screws and tapped/inserted support details are still to be selected.

The dock remains included as the desktop configuration. Switchcraft 722A is now the selected 12 V inlet and Same Sky SDS-50J the selected MIDI DIN endpoint, but their enclosure retention, short-harness strain relief, feet/final hardware and thermal design still need physical first-article validation.

A plain PCB fit-template STL is provided only for a mechanical test print. It is not a conductive PCB, a production drill master, or a substitute for a real board.

## 7. Checks executed and not executed

Executed: explicit graph generation; pad-to-pad placement clearance; geometric copper/pad/via and board-edge checking; native ERC/DRC/parity; direct-stack 40-pin net/XY comparison; independent parsing of emitted PCB pad/net assignments; ideal DC arithmetic; and reference CAD solid/intersection checks for the six controls, shifted support planes and Samtec body envelopes. Current case results are in `../reports/case_direct_stack_update.json` and `../reports/case_export_validation.json`.

Not executed: manufacturer footprint approval, impedance/EMI analysis, power/analog SPICE macro-model simulations, real-component fit, thermal/load/dropout/fault tests, FPGA execution and listening/audio measurements.

The custom checker uses a simplified nominal copper geometry model. It does not check every KiCad/manufacturer rule, soldermask web, drill plating specification, courtyard, silkscreen or thermal relief. Inner GND fills are deliberately missing from its test scope.

## 8. Opening, rebuilding and native validation

Open `design/radian_panel.kicad_pro` in KiCad 10. Keep its root and child schematics, `fp-lib-table`, `sym-lib-table` and sibling `library/`/`cad/` folders together. The embedded symbols make the net graph self-contained, and the local footprint library preserves the draft dimensions.

`source/verify_native.sh` has been executed with Backplane KiCad 10.0.6. ERC and schematic-parity DRC both exit 0. Its current reports are in `reports/native/`. Rerun after edits; do not silence findings to obtain a passing result.

Rebuild the generated draft only before doing manual edits, because generators overwrite their files:

```sh
python source/design_data.py
python source/export_ecad.py
python source/check_placement.py
python source/route_board.py
python source/validate_design.py
python source/render_docs.py
python source/build_cad.py
python source/update_case_direct_stack.py  # active P2 case synchronization; previews render when DISPLAY is available
# Optional case integration with your previous unzipped CAD package:
python source/build_cad.py --previous /path/to/RADIAN_RevF1_Desktop_and_Eurorack
```

Requirements are in `source/requirements.txt`; ReportLab previews also use locally installed DejaVu Sans fonts. No font files are distributed. The generator's net-labelled schematic is intentionally explicit rather than pretending to be a hand-drafted circuit sheet. See `sources.md` for design provenance.

## 9. Before money is spent

Finalize the exact electrical parts and off-board mechanics; run native tools and review the schematic/PCB; print the bare mechanical template and test real switches/jacks/knobs; review input protection, load budget and converter layout with the actual part data. Only then make fabrication exports from a reviewed native KiCad board.

For first electrical tests, keep the expensive mainboard disconnected. Use current-limited low-voltage bench power, prove the panel converter output, polarity, no-load/load behavior and transients with a dummy load, and measure faults only using a planned safe procedure. Then mate the mainboard through the verified J17/J18 direct stack and bring up power, controls and audio one interface at a time. Do not put mains voltage inside this dock.
