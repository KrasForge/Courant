> Historical routing notes, superseded by the 2026-09-16 native repair. No unconnected items remain in the current mainboard; see `../hardware/REPAIR_STATUS.md`.

# Finishing the last six connections

`hardware/courant/dist/courant.routed.kicad_pcb` is routed except for six
connections. All six are BGA escapes that have to travel 15 to 46 mm, and all
six are blocked by a neighbouring trace rather than by distance -- which is why
the autorouter oscillated on them and why they need a router that can shove
existing copper aside.

There were nine. Three were a BGA ball on the top and its decoupling capacitor
directly underneath, needing only a via between them, and `scripts/stitch.py`
placed those: it searches for a via position clear on *every* copper layer and
keeps the result only if KiCad's DRC agrees. The remaining six are real routing
and want a person.

Budget twenty minutes.

## 1. Open it

```sh
cd hardware/courant
pcbnew dist/courant.routed.kicad_pcb
```

The project file `dist/courant.routed.kicad_pro` sits beside it, so the board's
real design rules load rather than KiCad's defaults. Confirm in
`File → Board Setup → Net Classes` that you see:

| Class | Clearance | Track | Via |
| --- | --- | --- | --- |
| Default | 0.15 mm | 0.15 mm | 0.55 / 0.25 mm |
| Power | 0.15 mm | 0.40 mm | 0.55 / 0.25 mm |
| Ground | 0.15 mm | 0.30 mm | 0.55 / 0.25 mm |

If those are missing you are editing without constraints — close, check the
`.kicad_pro` is present, and reopen.

## 2. Turn on the one setting that matters

`Route → Interactive Router Settings…` → **Mode: Shove**.

This is the whole reason the job is quick. In *Highlight collisions* mode the
router refuses to cross an obstruction; in **Shove** it pushes the obstructing
trace out of the way and re-routes it. Every one of the six is blocked by a
neighbour, so without this you will be fighting the tool.

Also worth setting, in the same dialog:

- **Remove redundant tracks**: on
- **Optimise pad connections**: on
- **Allow DRC violations**: off — you want it to refuse rather than let you
  create a short

## 3. Work the list

Open `Inspect → Design Rules Checker`, press **Run DRC**, and select the
**Unconnected Items** tab. That is your worklist: click an entry and the canvas
jumps to it. Re-run DRC to tick items off.

The six, shortest first. Coordinates are KiCad page coordinates, which is what
the DRC panel and the cursor readout show.

| # | Net | From | To | Gap |
| --- | --- | --- | --- | --- |
| 1 | `FLASH_CLK_RAW` | U1 ball **E8** @ 99.50, 91.50 | track on F.Cu @ 109.34, 102.43 | 14.7 mm |
| 2 | `INIT_B` | U1 ball **K10** @ 101.50, 96.50 | via @ 110.33, 108.67 | 15.0 mm |
| 3 | `PUDC_B` | track on F.Cu @ 111.17, 115.00 | U1 ball **L15** @ 106.50, 97.50 | 18.1 mm |
| 4 | `FLASH_MISO` | U1 ball **J14** @ 105.50, 95.50 | track on F.Cu @ 119.45, 121.36 | 29.4 mm |
| 5 | `JTAG_TCK` | track on In3.Cu @ 110.26, 140.41 | U1 ball **L7** @ 98.50, 97.50 | 44.5 mm |
| 6 | `reset_n` | track on F.Cu @ 87.17, 132.00 | U1 ball **B10** @ 101.50, 88.50 | 45.8 mm |

Every one is the same shape of job: get off the ball, out through the ball
field, then across to the target. The standard move is a dog-bone -- a short
stub on F.Cu into the diagonal gap between four balls, a via there, then run out
on an inner layer.

**The one thing to watch when placing that via.** A through via crosses all six
layers, and the diagonal gap that looks empty on F.Cu and B.Cu is often occupied
on In2 or In3 by a trace you cannot see. Two automated attempts here placed vias
that shorted to exactly that -- once to `dac_bclk` on In2. Before committing a
via, switch the view to In2 and In3 and check the slot is clear there too. The
interactive router in Shove mode will refuse a genuine collision, which is the
main reason to leave *Allow DRC violations* off.

### What blocks each of the six

Every one of these balls has four diagonal escape slots, and every one of those
24 slots is occupied -- almost always by traces the autorouter placed for other
nets, sometimes also by a back-side decoupling capacitor. This is the list to
work from: drag the named obstruction clear first, then escape.

| Net | Ball | Best slot | In the way |
| --- | --- | --- | --- |
| `INIT_B` | K10 | (101.0, 97.0) | C121 + 1 trace |
| `JTAG_TCK` | L7 | (98.0, 98.0) or (99.0, 98.0) | 1 trace |
| `reset_n` | B10 | (101.0, 89.0) | 2 traces |
| `FLASH_MISO` | J14 | (105.0, 95.0) | 2 traces |
| `FLASH_CLK_RAW` | E8 | (99.0, 92.0) or (100.0, 91.0) | 3 traces |
| `PUDC_B` | L15 | (106.0, 97.0) | 4 traces |

`JTAG_TCK` is the easiest -- one trace in the way and no capacitor. `PUDC_B` is
the worst. Working in that order is the path of least resistance.

Note that the decoupling capacitors *can* be moved: a 0402 pad is 0.64 mm
across and needs 0.425 mm of clearance from a via, so a cap centred on a ball
blocks all four of its slots and a 0.3 mm nudge frees two of them. C121 sits at
exactly ball K10's coordinates. Moving one is fine; it is a decoupling cap on a
3 mm grid, not a critical placement.

### Why this cannot be automated here

Worth knowing before anyone tries again. Threading a trace between two FTG256
balls is sub-grid geometry:

```
ball pad radius            0.250 mm
+ clearance                0.150 mm
+ half trace width         0.075 mm
= trace centre at least    0.475 mm from a ball centre
midpoint between balls is  0.500 mm from each
-> routable corridor        0.050 mm wide
```

Fifty microns. A grid router needs cells well inside that to find the gap: at
0.1 mm it sees half a cell and reports the board as blocked, at 0.05 mm one
cell and only if it happens to align. 0.025 mm would work and is 640 million
cells across this board's signal layers.

That is why every scripted attempt here failed, and it is not a matter of
writing them better -- they were grid routers, and this is continuous geometry.
Freerouting manages the other 1800 segments because it is a topological router
working in exact coordinates; KiCad's interactive router is the same, which is
why Shove mode solves in seconds what a lattice search cannot solve at all.

Four of the six do have a clear escape via slot, found geometrically:
`INIT_B` at (103.0, 95.0), `PUDC_B` at (106.0, 99.0), `JTAG_TCK` at
(97.0, 96.0), `reset_n` at (100.0, 89.0). `FLASH_CLK_RAW` (ball E8) and
`FLASH_MISO` (ball J14) have no clear slot within 2.2 mm and will need a
neighbour moved first.

## 4. Routing, concretely

| Key | Does |
| --- | --- |
| `X` | start routing from whatever is under the cursor |
| click | anchor a corner |
| `V` | drop a via and switch to the next layer |
| `PgUp` / `PgDn` | jump to F.Cu / B.Cu |
| `Backspace` | undo the last segment while routing |
| `Esc` | abandon this trace |
| double-click | finish on the target |
| `D` | drag an existing trace |
| `Ctrl+Z` | undo |
| `` ` `` | highlight the net under the cursor |

Highlighting the net (`` ` ``) before you start is worth the keystroke: it dims
everything else, so the ratsnest line you are chasing is unambiguous.

## 5. Two rules while you work

**Do not put copper on In1.Cu or In4.Cu.** They are the ground planes. Keeping
them uncut is the single biggest thing this layout has going for it — the
autorouter's unrestricted run cut them 166 times, including the I2S master and
bit clocks, and fixing that was most of the work. KiCad will happily let you
route there; don't. Your signal layers are **F.Cu, In2.Cu, In3.Cu, B.Cu**. In3
also carries the 3.3 V pour, which is fine to cross — the pour refills around
you.

**Leave the twelve via-in-pad warnings under U11–U13 alone.** Those are the
grounded thermal vias in the switchers' exposed pads, on GND, per TI's layout
guidance for the RGT0016C package. They are deliberate.

## 6. While you are in there

Two small things already on the board, both easy to fix by hand and neither
worth a separate session:

- **Two clearance violations at 0.1373 mm** against the 0.150 mm rule. They
  would very likely fabricate — most processes hold 0.09 to 0.127 mm — but they
  break the rule the board declares. `Inspect → DRC` lists them; nudge the trace.
- **Four dangling vias**: escape vias the autorouter placed and then routed
  around. Harmless, but they are holes the fab drills for nothing. Select and
  delete.

## 7. When you are done

```sh
npm run fab
```

DRC, Gerbers, drill files, placement, BOM and board previews, into `dist/fab/`
plus `dist/courant-fab.zip`. It refuses to run while connections are missing,
which is why it has not run yet.

Before ordering, see the open item in `MILESTONES.md` about swapping U1 to
**XC7A50T-1FTG256I** — same package, byte-identical pinout, $51.74 cheaper, 57%
more logic. It is a one-line change and it should happen before money is spent.
