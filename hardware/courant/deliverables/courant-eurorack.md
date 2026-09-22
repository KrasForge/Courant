# Courant Rev A — Eurorack status

Everything below is measured against the board as routed, not against an
intention. Where a change is needed the values are computed, not estimated.

| | Status |
| --- | --- |
| Mechanical | **done** — RADIAN Rev F.1 gives a 40 HP panel, DXF through-cuts, STLs and a desktop dock |
| Gate input | **works as built** |
| Power | **works if the case supplies +5 V** — no board change, see below |
| Pitch/mod CV | **partial** — 0–5 V only; one resistor per channel fixes bipolar |
| Audio level | **line, not modular** — the one item needing new circuitry |

## Gate — no change

R166/R167 divide by 0.2481 against a comparator reference of
2.5 × 10/50.2 = 0.498 V, so the rising threshold at the jack is **2.01 V**. The
BAT54S only conducts above (3.3 + 0.3)/0.2481 ≈ **14.5 V** at the jack. Both
5 V and 10 V Eurorack gates are inside that with room to spare.

## Power — probably no change either

The Doepfer 16-pin bus carries **+5 V**, not only ±12 V. J1 needs +5 V and GND
and nothing else, so an adapter cable from the bus header to J1's 2-pin KK 254
housing is sufficient — **no board modification**.

`design.ts` specifies "5 V / 3 A", which would be beyond most Eurorack +5 V
rails, but that is headroom, not draw. Estimating from the actual load:

```
VCCINT 1.0 V   ~0.5 A                      0.50 W
VCCAUX 1.8 V   ~50 mA                      0.09 W
VCCO 3.3 V + codec, ADC, flash             0.65 W
                                    out    1.24 W
                        in, at ~85% buck   1.5 W  =  about 0.30 A at 5 V
```

**~300 mA is comfortable for a typical +5 V rail.** Treat it as an estimate
until a real board is measured — that is the single number that settles this.

Two things the adapter cable must carry, because the board has neither: a
**fuse** and **reverse-polarity protection**. A series Schottky costs 0.3 V of
the 5 V headroom, which the 3–17 V TPS62130 input range absorbs without
complaint.

Do **not** feed +12 V to J1. The regulators would tolerate it, but R12/R22 pull
the power-good pins to that rail and drive the next regulator's EN input, whose
absolute maximum has not been checked here, and C1 is a 16 V part.

## Pitch and mod CV — one resistor per channel

As built: R160 20 k from the jack, R161 20 k to ground, ÷2 into a 0–2.5 V ADC.
That is **0–5 V unipolar, 40 kΩ input impedance**, five octaves at 1 V/oct.
Negative input clamps at −0.6 V.

**For ±5 V bipolar** — add one resistor per channel from `VREF25` to the
existing divider node. R160 and R161 are unchanged:

```
R_offset = 10 kΩ    (VREF25 -> the R160/R161 junction)

  -5 V in  ->  0.000 V at the ADC
   0 V in  ->  1.250 V
  +5 V in  ->  2.500 V

input impedance 26.7 kΩ; VREF25 load 125 uA per channel
```

Exact, with no change to the buffer or the clamps. The REF3125 sources 10 mA,
so 250 µA for both channels is nothing.

**For 0–10 V unipolar** instead, change R160 from 20 k to **60.4 kΩ** (E96):
ratio 0.2488, full scale at 10.05 V, input impedance 80.4 kΩ.

Both are BOM changes on existing footprints — the bipolar option needs two new
0603 placements, which is local placement and a few millimetres of track, not
a re-route.

## Audio — the one real addition

The PCM5102A gives about 2.1 Vrms (5.9 Vpp). Eurorack runs ~10 Vpp, so the
board is **4.5 dB quiet**. Closing that needs a gain of 1.69 and a supply that
can swing to ±5 V; the board has only 3.3 V. That means a bipolar rail or a
charge pump and an output stage — genuinely new circuitry, unlike everything
else on this page.

Worth asking whether it matters. Plenty of Eurorack modules output line level
and are simply turned up. If modular level is a requirement, it belongs in
Rev B alongside the CV change.

## What this adds up to

Nothing here touches the FPGA, the ball field or the routed copper. The
mechanical design exists. Gate works. Power works with a cable, if the case has
+5 V. CV is one resistor per channel away from bipolar. Only the output level
would need a new circuit block, and only if you want modular level rather than
line level.
