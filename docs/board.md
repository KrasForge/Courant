# Courant standalone board (Rev A)

The Arty A7 + Pmod I2S2 target in [`syn/vivado/`](../syn/vivado/) is a bring-up
rig: it proves the RTL on hardware someone can buy for $130, but it is a
dev board with a synth bolted to it. This is the instrument version — a single
160 x 100 mm board carrying the FPGA, its configuration flash, both clocks, a
stereo DAC, and the whole analog front end the Arty build leaves off.

The design lives in [`hardware/courant/`](../hardware/courant/) and is written in
[tscircuit](https://tscircuit.com): React/TypeScript that evaluates to Circuit
JSON, from which SVGs, Gerbers, a netlist, KiCad files and a Specctra DSN are
generated. `design.ts` is the netlist, `footprints.tsx` holds the few custom land
patterns, `courant.circuit.tsx` is the board.

> **Current status (2026-09-16): routed, native DRC 0 errors / 0 warnings / 0 unconnected; not physically validated.**
> 2158 track segments, 4386.2 mm of track, 299 vias. Overlapping via holes and dangling copper were repaired.
> See [`hardware/REPAIR_STATUS.md`](../hardware/REPAIR_STATUS.md) and the current native JSON reports.
> The routing-development narrative below describes earlier stages, not the current outstanding work.

---

## 1. Blocks

| Block | Parts | Notes |
| --- | --- | --- |
| Power | U11–U13 TPS62130A, L1–L3 1 µH | 5 V in → 1.0 V / 1.8 V / 3.3 V, cascaded |
| FPGA | U1 XC7A50T-1FTG256I | 256-ball BGA, 1.0 mm pitch |
| Config | U2 W25Q64JVSSIQ | master SPI, 64 Mbit |
| Clocks | Y1 100 MHz, Y2 12.288 MHz | separate parts, see §3 |
| Audio | U3 PCM5102A | I2S, FPGA is master |
| Controls | U4 MCP3208, U5 REF3125 | 3 pots over SPI, 2.5 V reference |
| CV | U6 MCP6002, U7 MCP6561, D10–D12 BAT54S | pitch/mod in, gate comparator |
| MIDI | U8 H11L1M | opto-isolated, 31250 baud |

### Power

Three TPS62130A buck converters in a chain, each enabled by the previous one's
power-good pin: 5 V → 1.0 V (`VCCINT`/`VCCBRAM`) → 1.8 V (`VCCAUX`) → 3.3 V
(all `VCCO` banks). The A suffix matters — on the plain TPS62130 the power-good
pin is high-impedance while the part is disabled, so the chain would not start;
on the TPS62130A it is actively low, which is what makes the cascade a sequencer.
The last stage's power-good drives `PROGRAM_B`, holding the FPGA in reset until
3.3 V is up.

Feedback dividers set 0.8 V x (1 + Rtop/Rbot): 24.9k/100k = 0.9992 V, 124k/100k =
1.79 V, 316k/100k = 3.33 V. `FSW` and `DEF` are tied low on all three, selecting
2.5 MHz and the nominal (not +5 %) output, which is what makes the 1 µH / 22 µF
output filter the right size.

### FPGA and configuration

Mode pins are strapped M[2:0] = 001 for master SPI (`M0` high, `M1`/`M2` low).
`CFGBVS` is tied to 3.3 V for a 3.3 V configuration bank. The XADC is unused, so
`VREFP` and `VREFN` are grounded and `VCCADC` sits on the 1.8 V rail, per UG480's
unused-XADC configuration. `PUDC_B` is pulled high so the I/O pull-ups are off
during configuration.

The flash clock comes out of the dedicated `CCLK` ball (E8), not a user I/O — in
master SPI mode the STARTUPE2 primitive drives it.

Decoupling is 38 x 100 nF 0201 on the back side directly under the BGA, distributed beneath the FPGA, plus bulk 47 µF/4.7 µF per rail.

### Clocks

Two oscillators rather than one, deliberately. A single 100 MHz source would
have to reach 12.288 MHz through an MMCM, and 12.288 does not divide cleanly
from 100 — the closest ratio leaves a residual frequency error that shows up as
audio sample-rate drift. A second 12.288 MHz part costs about a dollar and makes
the audio clock exact. Both land on clock-capable balls (D4 is MRCC, E3 is SRCC).

### Audio

PCM5102A in hardware mode: `FMT` low for I2S, `DEMP` low, `FLT` low for normal
latency, `XSMT` driven by the FPGA so the output can be muted before the mesh is
excited. Its analog 3.3 V comes through a series 1 Ω and its own bulk rather than
a separate LDO, which would cost output headroom for no measurable noise gain at
this level. Outputs are 470 Ω + 2.2 nF into the line jack.

### Controls, CV and MIDI

Three panel pots and both CV inputs are sampled by one MCP3208 over SPI, against
a REF3125 2.5 V reference. CV inputs are 0–5 V into a 20k/20k divider (so 0–2.5 V
at the ADC) with BAT54S rail clamps. The gate input is a comparator with a
divider-set threshold of about 2.0 V at the jack. MIDI is the standard
opto-isolated DIN input; DIN pin 2 is deliberately *not* connected to board
ground, which is the entire point of the isolation.

---

## 2. Footprints

Standard packages use [footprinter](https://github.com/tscircuit/footprinter)
strings, which are library-maintained and IPC-derived. Three are custom, each for
a reason recorded in `footprints.tsx`:

- **`ftg256`** — footprinter's `bga256_…` numbers pin 1 from the lower left. The
  design maps AMD's ball names (A1…T16) onto `pin(row*16 + col)` with A1 upper
  left, so using the string would mirror every ball on the package vertically.
- **`qfn16`** — `qfn16_w3_h3_p0.5mm_thermalpad` places the signal pads' inner
  edges 0.525 mm from centre against a 1.75 mm thermal pad that reaches 0.875 mm,
  overlapping them by 0.35 mm and shorting all sixteen pins to the pad. TI's
  RGT0016C exposed pad is 1.68 mm and its leads reach 1.5 mm from centre, so the
  custom pattern uses 1.68 mm with the pads spanning 1.10–1.80 mm.
- **`soic8w208`** — the W25Q64JV's `SS` package is 208-mil SOIC-8, and
  footprinter silently ignores the width modifier in `soic8_w5.3mm_p1.27mm`,
  returning the 150-mil pattern. Derived from Winbond's package table with
  IPC-7351 nominal fillets.

The 3.2 x 2.5 mm oscillators and the 4 x 4 mm inductors have no footprinter
family and are spelled out.

---

## 3. Routing

tscircuit places this board and owns its netlist; it does not cut the copper.
That is done by [Freerouting](https://freerouting.org), through KiCad, and the
result comes back into the same board file the placement came out of:

```sh
npm run export   # dist/courant.kicad_pcb -- placed, no copper
npm run route    # -> dist/courant.routed.kicad_pcb
npm run fab      # -> DRC report, Gerbers, drill, placement, BOM, previews
```

`scripts/route.py` drives that loop end to end: it writes the design rules, has
KiCad write the Specctra DSN, runs the router headless, imports the session file
back and refills the ground planes. `scripts/fab.py` then runs KiCad's DRC and
plots the fabrication outputs. Both need tools npm cannot install -- KiCad 9+
with its `pcbnew` Python module, a JRE, and `freerouting.jar` (point
`$FREEROUTING_JAR` at it) -- and both say so plainly if they are missing.

Five things about that path are not obvious, and each one is a trap.

### tscircuit's own autorouter does not converge

tscircuit's bundled `capacity-autorouter` fails on this board with

```
Pipeline9 route "source_net_25_mst41" changes layers from z=5 to z=0
without an explicit via (capacity-autorouter@0.0.900)
```

and emits no copper at all, leaving every port unrouted. That is a router defect
on a 256-ball BGA escape across six layers, not a netlist problem -- the same
netlist passes `tsci check netlist` and builds cleanly with routing disabled.
The board therefore carries `autorouter="none"`, which keeps every build fast
instead of spending about seventeen minutes to produce nothing.

### tscircuit's Specctra export cannot be used either

`tsci export -f specctra-dsn` is the advertised handoff to an external router,
and it is not usable here. It fails two ways, one loud and one silent:

- **It crashes.** `convertCircuitJsonToDsnJson` groups pads by
  `pcb_component_id` and then dereferences the resulting `pcbComponent.center`
  without checking that the lookup found anything. This board's three fiducials
  emit `pcb_smtpad` elements whose `pcb_component_id` is null, so the export
  dies with `TypeError: undefined is not an object (evaluating
  'pcbComponent.center')` and writes no file.
- **It would be wrong if it did not crash.** The converter writes
  `side: "front"` for every component regardless of the layer it is on. All 38
  decoupling capacitors on this board are on the back, directly under the BGA.
  A DSN from that converter puts them on top, and nothing downstream would
  catch it.

KiCad's exporter gets both right, so `scripts/route.py` loads
`dist/courant.kicad_pcb` and calls `pcbnew.ExportSpecctraDSN`. That has a second
benefit: the router, the DRC and the Gerber plot then all read the same board
file and the same rules, so they cannot disagree about the board.

### Net names must be distinct with case ignored

Specctra folds net names to a single case. tscircuit and KiCad do not: `led0`
and `LED0` are two nets to them, and the DSN written from the board contains
both. Freerouting reads them as one, and the session file it writes back
mentions only `led0` -- so the four 1 kOhm LED series resistors R147-R150 came
back shorted across, as twelve `shorting_items` in DRC.

The panel-side nets are therefore `LED0_A`..`LED3_A`, and `scripts/check.ts`
now fails the build if any two nets differ only by case. This is not a
theoretical hazard; it cost a routing run.

### Keeping signals off the planes is a net-class rule, not a layer type

This is the mistake worth reading before changing anything about the handoff.

The obvious way to stop the router cutting up the ground planes is to declare
those layers `(type power)` in the DSN. It does not do that. Freerouting treats
a `power` layer as unavailable for connections altogether -- including the GND
pins that need to reach their own pour. The symptom is not an error; it is a
board that comes back with 55 to 60 connections unrouted, about fifty of them
GND, which reads exactly like a board too dense to route.

It was misread that way here for three consecutive routing runs, and the
conclusion drawn was that the design needed eight layers. It did not. The
evidence was already visible and pointing elsewhere: fanout escape dropped from
94% to 69% the moment the planes were reserved, the via count *fell* while
routing layers were being added, and the new inner layers sat nearly empty
while the router "could not finish". All three say connections are being
refused, not that there is nowhere to put them.

The mechanism that does what is wanted is a per-net-class `use_layer` clause.
Every layer stays `signal`, so vias and plane connections work normally, and
each class except the ground class is restricted to the non-plane layers.
`scripts/route.py` derives that from the board's own zones: layers carrying a
pour whose net is in `RETURN_NETS` are reserved, everything else is routable.
GND keeps the whole stackup.

Measured on this board, all other settings equal:

| Reserved | Unrouted | Signal segments cut through the planes |
| --- | --- | --- |
| nothing | 8 | 166 (1301 mm) |
| both ground planes, via `(type power)` | 56 | 0 |
| ditto, plus a V3V3 plane | ~90 | 0 |
| **both ground planes, via `use_layer`** | **9** | **0** |

Eight layers with the broken mechanism gave 14; six layers with the correct one
gives 9. The board never needed the extra copper.

### The default design rules cannot route a 1.0 mm BGA

KiCad's defaults -- 0.2 mm track, 0.2 mm clearance, 0.6/0.3 mm via -- are not
merely tight here, they are geometrically impossible. FTG256 balls are 0.5 mm
pads on a 1.0 mm pitch, so the gap between two neighbouring balls is 0.5 mm.
Escaping a signal between them needs `width + 2 x clearance`, which at the
defaults is 0.6 mm. Nothing fits, and the router reports the pins as unroutable
rather than explaining why.

`scripts/rules.json` carries the rules the package actually needs. It is written
out as `dist/courant.kicad_pro`, because KiCad keeps design rules in the project
file rather than the board file:

| | Default | Power | Why |
| --- | --- | --- | --- |
| track | 0.15 mm | 0.4 mm | 0.15 + 2 x 0.15 = 0.45 mm clears the 0.5 mm ball gap |
| clearance | 0.15 mm | 0.15 mm | same sum; also the via-to-ball margin below |
| via | 0.55 / 0.25 mm | 0.55 / 0.25 mm | a dog-bone via sits 0.707 mm from four balls: 0.707 - 0.25 - 0.275 = 0.182 mm of clearance. A 0.6 mm via leaves 0.157 mm and fails |

0.25 mm through a 1.6 mm board is a 6.4:1 aspect ratio, comfortably inside the
8:1 that plating prefers, and the 0.15 mm annular ring is past the 0.13 mm knee
where breakout risk collapses. All of it sits inside a standard six-layer
process.

The Power class widens the rails but keeps the Default clearance and via
deliberately. `VCCINT`, `VCCAUX` and every `VCCO` ball is inside the same 1.0 mm
ball field as the signals, so a fatter power via could not be fanned out at all.
The rails take their width the moment they leave the package.

Freerouting's automatic neckdown is switched off for the same reason the rules
exist: left on, it thins a trace to squeeze past an obstacle, and it produced
0.1124 mm copper against the 0.15 mm minimum in 70 places. The minimum is a fab
limit, not a preference.

### Some copper is placed by hand, and the router must not touch it

The twelve grounded thermal vias in the switchers' exposed pads (section 1) are
a thermal structure, not a connection. No autorouter has a reason to invent them
and every reason to delete them: KiCad writes pre-existing copper into the DSN's
wiring section as `(type route)`, which tells Freerouting it is looking at its
own previous output and may rip it up. `scripts/route.py` rewrites those to
`(type protect)` -- Freerouting's `SYSTEM_FIXED` -- before the router sees the
file, so the vias survive the round trip and are treated as obstacles while the
rest of the board is routed around them. All twelve come back.

`scripts/check.ts` checks the same vias from the other side, in the netlist: that
each one lands inside a TPS62130A exposed pad without overhanging it, and that
no two barrels overlap. That is geometry the netlist cannot express and the
router will not police, and it is what would silently break if a regulator were
ever moved.

### Running the router

Freerouting's defaults are wrong for a batch run in three ways that cost real
time, and none of them is a command-line flag:

- it opens a GUI and spends the run repainting it;
- its multi-threading feature flag is off -- though note this only affects the
  optimizer, since the autorouter is single-threaded and measures at almost
  exactly 1.00 cores whatever you pass to `-mt`;
- its fanout stage has no budget of its own and will spend the entire job on
  itself. On this board fanout escapes about 94% of pins in three passes and
  then grinds on the same ~30 it cannot place, at a minute or more a pass, until
  the job times out with the autorouter never having started.

All three live in a settings file, so `scripts/route.py` writes one and points
`$FREEROUTING__USER_DATA_PATH` at it. That also keeps the run out of the user's
own `~/.config/freerouting` and turns off the telemetry that is on by default.
Fanout is capped at six passes and the optimizer at 45 minutes so that the stage
which actually routes nets gets the time.

`--gui` puts the board window up if you want to watch; it is slower.

---

## 4. Building it

```sh
cd hardware/courant
npm install
npm run verify     # typecheck, board rules, netlist, and a clean build
npm run export     # SVGs, netlist, KiCad board, and the Vivado XDC
npm run route      # KiCad -> Freerouting -> routed KiCad board
npm run fab        # DRC, Gerbers, drill, placement, BOM, board previews
```

`npm install` covers the first three. The last two need tools outside npm's
reach:

| Tool | Used for | Where |
| --- | --- | --- |
| KiCad 9+ with `pcbnew` | DSN export, session import, DRC, Gerbers | distro package |
| a JRE | running the router | distro package |
| `freerouting.jar` | the router itself | [releases](https://github.com/freerouting/freerouting/releases), then `$FREEROUTING_JAR` |

`npm run check` runs `scripts/check.ts`, which enforces the rules tscircuit
cannot know, all against AMD's own package file (`fpga-pins.json`, generated
from the checked-in `xc7a35tftg256pkg.txt` by `scripts/make-pinmap.py`):

- no single-connection nets, no duplicate reference designators
- no two nets differing only by case, which Specctra would merge (section 3)
- every assigned ball exists in the FTG256 package, and no user signal lands on
  a dedicated configuration or supply ball
- every bank carrying user I/O has all of its `VCCO` pins on the 3.3 V rail
- both clock inputs are on clock-capable (MRCC/SRCC) balls
- the master-SPI mode straps, `CFGBVS`, `VCCADC` and the unused-XADC ties
- no FPGA supply ball left unconnected, and one decoupling capacitor per
  powered ball
- every thermal via inside the exposed pad it cools, and no two overlapping

`npm run export` also generates `dist/courant_rev_a.xdc` from the same `io` map
the schematic uses, so the board's pinout and the constraints handed to Vivado
cannot drift apart. It is the board's half of the contract with
`src/rtl/synth_top.vhd`.

`npm run fab` refuses to run on an unrouted board. Gerbers plotted from one
carry pads, soldermask and drills but no copper -- a file that looks exactly
like fabrication data and is not, which is the single mistake in this directory
that would cost real money.

---

## 5. Current verification and remaining work

Native Backplane KiCad 10.0.6 DRC reports zero errors, zero warnings and zero unconnected items on the installed mainboard. Checks include all configured severities. Original check settings were retained; ignored checks are listed in the report. Physical pads, net assignments, component placement and board outline were preserved.

The former six remaining connections, clearance findings and dangling copper are no longer current open work. `finishing_the_route.md` is retained as historical context only.

No native mainboard schematic is supplied, so mainboard ERC and native schematic/PCB parity are not claimed. No new manufacturer footprint approval, FPGA timing/bitstream execution, physical assembly, electrical, audio, thermal or fault tests were performed in this repair. Native geometric connectivity does not validate circuit function.

The repository contains `src/rtl/adc_mcp3208.vhd` and its testbench; they were not modified or executed in this PCB repair. Validate the actual FPGA build before ordering hardware.
