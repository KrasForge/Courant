# Courant Rev A — off-board (panel) hardware

Nothing in this list is on the PCB. Every control and socket is panel-mounted
and wires to one of the fifteen 2.54 mm headers; `courant-panel-interface.csv`
gives the pin-by-pin mapping. The board was designed this way deliberately —
see `courant-source-design.ts:187` for the filter arrangement that depends on
it — so these are the parts that complete the instrument, not alternatives to
anything on the board.

**These are selections, not decisions you have already made.** The design does
not name panel hardware, and the right choice depends on a panel format that
does not exist yet. Everything below is specified to be electrically correct
and mechanically ordinary; treat it as a starting BOM to argue with.

## Sourced, with datasheets in `datasheets/`

| Qty | Part | Manufacturer | MPN | ~$ ea | Feeds |
| --- | --- | --- | --- | --- | --- |
| 3 | 10 kΩ linear pot, 9 mm, 6 mm flatted shaft | Bourns | `PTV09A-4020F-B103` | 1.29 | J6 pitch, J7 decay, J8 timbre |
| 1 | Rotary encoder, 24 PPR, detented, with switch | Bourns | `PEC11R-4215F-S0024` | 2.95 | J9 |
| 4 | 3.5 mm TRS jack, right angle | Same Sky | `SJ1-3523N` | 1.12 | J5 line out, J12 pitch CV, J13 mod CV, J14 gate |
| 1 | DIN 5-pin socket, 180°, right angle | Same Sky | `SDS-50J` | 2.84 | J15 MIDI in |

Panel hardware subtotal: **about $16 per instrument.**

## Still to choose — trivial parts, but they depend on the panel

| Qty | What | Note |
| --- | --- | --- |
| 4 | LEDs, 3 mm or 5 mm | J11. **Series resistors R147–R150 are on the board** — wire the LEDs directly, anode to the pin, cathode to the GND pin. Do not add panel resistors |
| 1 | SPDT toggle or slide switch | J10. Pin 1 is 3V3, pin 3 is GND, pin 2 is the wiper to `cv_select`. Any single-pole changeover |
| 1 | 5 V DC inlet | J1. The board expects **regulated 5 V**, externally fused. A 2.1 mm barrel jack (e.g. Same Sky `PJ-102AH`) or a 2-pin terminal block both work |

## Three things worth knowing before wiring the panel

**The pots are referenced to `VREF25`, not 3.3 V.** Pin 1 of J6/J7/J8 carries
the 2.5 V reference that the ADC also uses, so a wiper reading is ratiometric
and reference drift cancels instead of appearing as pitch drift. Do not wire
the pot top ends to a rail.

**Keep the wiper runs as short as convenient, but do not add filtering.** The
1 kΩ series resistor sits on the board at the header and the 10 nF sits at the
ADC pin, which puts the cable *inside* the RC — anything the wiring picks up is
shunted at the ADC input rather than arriving at its sampling capacitor. A
capacitor added at the pot would defeat that.

**The CV inputs expect 0–5 V unipolar.** They pass through 0.1 % matched 20 kΩ
dividers into an MCP6002 buffer, scaling to the ADC's 0–2.5 V span, with
BAT54S clamps to the rails. Bipolar Eurorack CV (±5 V) will clamp on the
negative half — if this needs to accept bipolar CV, that is a front-end change,
not a wiring choice.
