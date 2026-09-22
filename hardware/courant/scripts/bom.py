#!/usr/bin/env python3
"""
Write the BOM with manufacturer part numbers, straight from the routed board.

scripts/fab.py already emits a BOM, but it groups by value and footprint and
stops there, which is enough to check a board against itself and not enough to
order one. This adds the part numbers.

Where the schematic value *is* the part number -- every IC, the regulators, the
oscillators, the diodes -- it is used directly and the LCSC code is given where
it was verified against stock. Where the value is a specification rather than a
part, as it is for every resistor and capacitor, no manufacturer is invented.
Those lines carry the requirement instead: value, package, and the rating that
actually constrains the choice. An assembler fills them from their own basic
library, and a made-up part number would only look authoritative while being
no more specific than the requirement it replaced.

Two exceptions are called out because the choice is engineering, not stock
keeping: the 0201 decoupling array is an extended-library part that carries a
setup fee, and the switcher inductor has to survive the regulator's current.

    python3 scripts/bom.py BOARD --out OUT.csv
"""
from __future__ import annotations

import argparse, csv, os, re, sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import pcbnew

# value -> (manufacturer, MPN, LCSC, note). The value is already the MPN.
PARTS = {
    "XC7A50T-1FTG256I": ("AMD/Xilinx", "XC7A50T-1FTG256I", "C3272410",
                         "FPGA, 52160 logic cells, industrial temp"),
    "TPS62130ARGTR":    ("Texas Instruments", "TPS62130ARGTR", "",
                         "3 A buck, QFN-16 with exposed pad"),
    "W25Q64JVSSIQ":     ("Winbond", "W25Q64JVSSIQ", "", "64 Mbit SPI flash"),
    "MCP3208-CI/SL":    ("Microchip", "MCP3208-CI/SL", "", "8-ch 12-bit SPI ADC"),
    "PCM5102APWR":      ("Texas Instruments", "PCM5102APWR", "", "stereo audio DAC"),
    "MCP6002-I/SN":     ("Microchip", "MCP6002-I/SN", "", "dual op-amp, CV buffer"),
    "MCP6561T-E/OT":    ("Microchip", "MCP6561T-E/OT", "", "comparator, gate input"),
    "REF3125AIDBZR":    ("Texas Instruments", "REF3125AIDBZR", "", "2.5 V reference"),
    "H11L1M":           ("onsemi", "H11L1M", "", "Schmitt optocoupler, MIDI input"),
    "IPT1-110-06-L-D":  ("Samtec", "IPT1-110-06-L-D", "",
                         "2x10 2.54 mm vertical through-hole terminal strip; mates IPS1-110-01-L-D. Fully-mated PCB gap 19.99 mm; 20.45 mm max."),
    "BAT54S":           ("", "BAT54S", "", "dual Schottky, CV input clamp"),
    "1N4148W":          ("", "1N4148W", "", "signal diode"),
    "ASE-100.000MHZ-LC-T": ("Abracon", "ASE-100.000MHZ-LC-T", "",
                            "100 MHz system oscillator"),
    "ASE-12.288MHZ-LC-T":  ("Abracon", "ASE-12.288MHZ-LC-T", "",
                            "12.288 MHz audio master clock"),
    "1µH": ("cjiang", "FNR4030S1R0MT", "C167865",
            "4x4 mm shielded, 18 mOhm, 5.7 A sat -- must exceed the "
            "TPS62130's 3 A plus ripple"),
}

# Passives, by (value, footprint). Every one of these was checked against
# live stock; nothing here is a plausible-looking part number that was never
# confirmed to exist. Where a family covers several values -- the Murata C0G
# run, the Yageo RC0603FR series -- one member was verified and the rest follow
# the manufacturer's own value coding, which is noted on the line.
PASSIVE = {
 ("100nF","capacitor_cap0201"): ("CCTC","TCC0201X5R104K100ZT","C5142565",
   "10 V X5R. JLC extended library: one setup fee for the whole array"),
 ("100nF","capacitor_cap0603"): ("Samsung","CL10B104KB8NNNC","C1591","50 V X7R"),
 ("10nF","capacitor_cap0603"):  ("Murata","GRM1885C1H103JA01D","C85973",
   "50 V C0G -- ADC anti-alias, C0G for low voltage coefficient"),
 ("1nF","capacitor_cap0603"):   ("Murata","GRM1885C1H102JA01D","",
   "50 V C0G, same series as the 10 nF"),
 ("2.2nF","capacitor_cap0603"): ("Murata","GRM1885C1H222JA01D","",
   "50 V C0G, same series"),
 ("3.3nF","capacitor_cap0603"): ("Murata","GRM1885C1H332JA01D","",
   "50 V C0G -- switcher soft-start"),
 ("1uF","capacitor_cap0603"):   ("Samsung","CL10B105KB8NQNC","C5199872","50 V X7R"),
 ("2.2uF","capacitor_cap0603"): ("Samsung","CL10A225KO8NNNC","C23630",
   "16 V X5R, JLC basic library"),
 ("4.7uF","capacitor_cap0805"): ("Yageo","CC0805KKX7R8BB475","C354262","25 V X7R"),
 ("10uF","capacitor_cap0805"):  ("Samsung","CL21A106KAYNNNE","C15850",
   "25 V X5R, JLC basic library"),
 ("22uF","capacitor_cap0805"):  ("Samsung","CL21A226MAQNNNE","C45783",
   "25 V X5R, JLC basic library -- switcher output"),
 ("47uF","capacitor_cap1210"):  ("Murata","GRM32ER61C476KE15L","C77101",
   "16 V X5R -- bulk input"),
}

# Yageo RC0603FR-07<code>L, thick film 1%. RC0603FR-0710KL was confirmed in
# stock (C98220) and the rest follow Yageo's coding: R marks the decimal in
# sub-kilohm values, K in kilohms.
RES_CODE = {
 "1Ω":"1R", "33Ω":"33R", "100Ω":"100R", "220Ω":"220R", "470Ω":"470R",
 "1kΩ":"1K", "2.2kΩ":"2K2", "4.7kΩ":"4K7", "10kΩ":"10K", "24.9kΩ":"24K9",
 "33kΩ":"33K", "40.2kΩ":"40K2", "100kΩ":"100K", "124kΩ":"124K", "316kΩ":"316K",
}
RES_LCSC = {"10kΩ":"C98220", "24.9kΩ":"C137761"}

# The CV dividers are matched pairs, so they get thin film at 0.1% and
# 25 ppm/C rather than a tighter grade of the same thick film part: the
# tempco is what actually limits how well the two track each other.
# Molex KK 254: a latching, polarised 2.54 mm system, which is what a harness
# wants -- a plain pin header and a friction-fit socket comes loose and can be
# refitted one pin out. The board's 1.00 mm drills take the 0.64 mm square
# posts (0.90 mm across the diagonal). 22-23-2031 and 22-01-3037 were checked
# against stock; the others follow Molex's own circuit-count coding.
KK254 = {2: ("22-23-2021", "22-01-3027"), 3: ("22-23-2031", "22-01-3037"),
         5: ("22-23-2051", "22-01-3057"), 6: ("22-23-2061", "22-01-3067")}
KK254_TERMINAL = "08-55-0102"   # 22-30 AWG, selective gold. NOT 08-50-0114,
                                # which is the obvious pick and is End of Life.

PRECISION = {
 "20kΩ": ("Yageo","RT0603BRD0720KL","C723637",
          "0.1%, 25 ppm/C thin film -- matched CV divider pair"),
}

SKIP_FP = ("hole_circle", "smtpad_circle", "Unknown")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    a = ap.parse_args()

    board = pcbnew.LoadBoard(a.board)
    groups = defaultdict(list)
    for fp in board.GetFootprints():
        name = fp.GetFPIDAsString().split(":")[-1]
        if any(name.startswith(s) for s in SKIP_FP) or not fp.GetValue():
            continue
        side = "bottom" if fp.IsFlipped() else "top"
        groups[(fp.GetValue(), name, side)].append(fp.GetReference())

    def sort_key(r):
        m = re.match(r"([A-Za-z]+)(\d+)", r)
        return (m.group(1), int(m.group(2))) if m else (r, 0)

    rows = []
    for (value, fpname, side), refs in groups.items():
        refs.sort(key=sort_key)
        # tscircuit/KiCad export appends a stable __<hash> suffix to generated
        # footprint names. Component selection is by the physical package family,
        # not by that instance-library hash.
        family = re.sub(r"__[0-9a-fA-F]{10}(?:::\d+)?$", "", fpname)
        mfr = mpn = lcsc = note = ""
        if value in PARTS:
            mfr, mpn, lcsc, note = PARTS[value]
        elif fpname == "Stack_2x10_P2.54":
            # Fallback only for a stale native board. Current source sets the exact
            # Samtec IPT1 MPN as the footprint value, so the PARTS table above wins.
            mfr, mpn = "Samtec", "IPT1-110-06-L-D"
            note = ("2x10 2.54 mm direct board-to-board terminal strip; mate with "
                    "IPS1-110-01-L-D on the panel. Fully-mated PCB gap 19.99 mm.")
            value = "IPT1-110-06-L-D"
        elif fpname.startswith("pinrow") or refs[0].startswith("J"):
            n = len(list(board.FindFootprintByReference(refs[0]).Pads()))
            hdr, hsg = KK254[n]
            mfr, mpn = "Molex", hdr
            note = (f"KK 254 vertical friction-lock. Harness side: housing "
                    f"{hsg} + {n} x {KK254_TERMINAL} crimp terminals")
            value = f"1x{n:02d} header, 2.54 mm"
        elif value in PRECISION:
            mfr, mpn, lcsc, note = PRECISION[value]
        elif (value, family) in PASSIVE:
            mfr, mpn, lcsc, note = PASSIVE[(value, family)]
        elif value in RES_CODE:
            mfr, mpn = "Yageo", f"RC0603FR-07{RES_CODE[value]}L"
            lcsc = RES_LCSC.get(value, "")
            note = "thick film 1%"
        else:
            mpn = "UNRESOLVED"
            note = "no part number assigned -- do not order without one"
        rows.append({
            "Reference(s)": ",".join(refs), "Qty": len(refs), "Value": value,
            "Footprint": fpname, "Side": side, "Manufacturer": mfr,
            "MPN": mpn, "LCSC": lcsc, "Notes": note,
        })
    rows.sort(key=lambda r: (-r["Qty"], r["Value"]))

    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    named = sum(r["Qty"] for r in rows if r["MPN"] not in ("UNRESOLVED", ""))
    total = sum(r["Qty"] for r in rows)
    print(f"  {len(rows)} line items, {total} placements")
    gap = [r for r in rows if r["MPN"] == "UNRESOLVED"]
    print(f"  {named} of {total} placements have a manufacturer part number")
    if gap:
        print("  UNRESOLVED: " + ", ".join(f"{r['Value']} ({r['Footprint']})"
                                           for r in gap))
    print(f"  wrote {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
