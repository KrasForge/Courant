#!/usr/bin/env python3
"""
Cost the board from its own BOM.

Unit prices marked `verified` were read from live JLCPCB/LCSC stock while this
was written. The rest are marked `est` and are the author's estimate; they are
small parts and the total is not sensitive to them, but they are labelled so
nobody mistakes a guess for a quote.

Nothing here is a quotation. Board and assembly pricing is a model of JLCPCB's
published structure, not a cart total, and both move with panel utilisation,
lead time and whatever the assembler decides about a given part.

    python3 scripts/cost.py --bom deliverables/courant-bom.csv
"""
from __future__ import annotations

import argparse, csv, re
from collections import defaultdict

# MPN or (value, footprint) -> (unit price USD, verified?)
PRICE = {
    "XC7A50T-1FTG256I": (67.01, True), "TPS62130ARGTR": (0.9245, True),
    "PCM5102APWR": (1.4062, True),     "MCP3208-CI/SL": (3.3283, True),
    "FNR4030S1R0MT": (0.0567, True),
    "TCC0201X5R104K100ZT": (0.0013, True), "CL10B104KB8NNNC": (0.0104, True),
    "GRM1885C1H103JA01D": (0.0292, True), "CL10B105KB8NQNC": (0.0267, True),
    "CL10A225KO8NNNC": (0.0189, True),    "CC0805KKX7R8BB475": (0.0878, True),
    "CL21A106KAYNNNE": (0.0844, True),    "CL21A226MAQNNNE": (0.2432, True),
    "GRM32ER61C476KE15L": (0.3003, True), "RC0603FR-0710KL": (0.0035, True),
    "RC0603FR-0724K9L": (0.0061, True),   "RT0603BRD0720KL": (0.0346, True),
    "ASE-100.000MHZ-LC-T": (0.3086, True), "ASE-12.288MHZ-LC-T": (0.3086, True),
    # estimates
    "REF3125AIDBZR": (1.80, False),   # genuine TI; an XBLW clone is $0.55 and
                                      # is a poor trade on a voltage reference
    "W25Q64JVSSIQ": (0.60, False), "MCP6002-I/SN": (0.35, False),
    "MCP6561T-E/OT": (0.45, False), "H11L1M": (0.90, False),
    "BAT54S": (0.04, False), "1N4148W": (0.01, False),
    "GRM1885C1H102JA01D": (0.03, False), "GRM1885C1H222JA01D": (0.03, False),
    "GRM1885C1H332JA01D": (0.03, False),
}
RES_DEFAULT = (0.005, False)      # any other RC0603FR thick film
HEADER_DEFAULT = (0.10, False)    # 2.54 mm pin header, per connector

# JLCPCB structure, as a range. Low end assumes a good panel and no surprises.
PCB_5 = (90.0, 140.0)             # 6-layer, 160.1 x 100.1 mm, minimum order 5
STENCIL = (8.0, 15.0)
SETUP = (16.0, 30.0)              # SMT setup, both sides
EXT_FEE = (2.5, 3.0)              # per distinct extended-library part
PLACE = (0.11, 0.19)              # per placement
BASIC = {"CL21A226MAQNNNE", "CL21A106KAYNNNE", "CL10A225KO8NNNC"}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bom", default="deliverables/courant-bom.csv")
    ap.add_argument("--qty", type=int, nargs="*", default=[1, 2, 5, 10, 25])
    a = ap.parse_args()

    rows = list(csv.DictReader(open(a.bom)))
    parts = 0.0
    unverified = 0.0
    placements = 0
    distinct_ext = set()
    for r in rows:
        qty = int(r["Qty"]); mpn = r["MPN"]
        placements += qty
        if mpn.startswith("1x") and "header" in mpn:
            unit, ok = HEADER_DEFAULT
        elif mpn in PRICE:
            unit, ok = PRICE[mpn]
        elif mpn.startswith("RC0603FR"):
            unit, ok = RES_DEFAULT
        else:
            unit, ok = 0.05, False
        parts += unit * qty
        if not ok:
            unverified += unit * qty
        if mpn not in BASIC:
            distinct_ext.add(mpn)

    print(f"  {len(rows)} line items, {placements} placements")
    print(f"  parts per board  ${parts:,.2f}"
          f"   (${parts - unverified:,.2f} verified, ${unverified:,.2f} estimated)")
    print(f"  distinct extended-library parts: {len(distinct_ext)}\n")

    fixed_lo = PCB_5[0] + STENCIL[0] + SETUP[0] + EXT_FEE[0] * len(distinct_ext)
    fixed_hi = PCB_5[1] + STENCIL[1] + SETUP[1] + EXT_FEE[1] * len(distinct_ext)
    print(f"  one-time: PCB 5 pcs ${PCB_5[0]:.0f}-{PCB_5[1]:.0f}, stencil "
          f"${STENCIL[0]:.0f}-{STENCIL[1]:.0f}, setup ${SETUP[0]:.0f}-{SETUP[1]:.0f}, "
          f"{len(distinct_ext)} extended parts "
          f"${EXT_FEE[0] * len(distinct_ext):.0f}-{EXT_FEE[1] * len(distinct_ext):.0f}")
    print(f"            = ${fixed_lo:,.0f} - ${fixed_hi:,.0f}\n")

    print(f"  {'built':>6}  {'total':>18}  {'per board':>16}")
    for q in a.qty:
        extra_pcb = 0.0 if q <= 5 else (PCB_5[0] / 5) * (q - 5)
        lo = fixed_lo + q * (parts + PLACE[0] * placements) + extra_pcb
        hi = fixed_hi + q * (parts + PLACE[1] * placements) + extra_pcb * 1.6
        print(f"  {q:>6}  ${lo:>7,.0f} - ${hi:<7,.0f}  ${lo / q:>6,.0f} - ${hi / q:<6,.0f}")
    print("\n  panel hardware adds about $16 per instrument "
          "(see courant-panel-hardware.md)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
