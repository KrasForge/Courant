#!/usr/bin/env python3
"""
Write the netlist and the panel interface from the routed board.

This board has no drawn schematic to export. It is defined in code -- design.ts
-- and tscircuit's schematic renderer produces an essentially blank sheet for
it (twenty text elements for two hundred components), so there is nothing
honest to ship under that name. The netlist below is the electrical definition
instead, and it is taken from the routed board rather than the source, which
makes it the authoritative record of what was actually fabricated.

The panel interface table is the other half: every one of the fifteen headers
is a connection to hardware that is not on this PCB, and whoever builds the
front panel needs the pinout more than they need a drawing.

    python3 scripts/netlist.py BOARD --netlist OUT.txt --panel OUT.csv
"""
from __future__ import annotations

import argparse, csv, re, sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import pcbnew

PANEL = {
    "J1":  "5 V DC input, externally fused",
    "J2":  "JTAG, to programmer",
    "J3":  "PROGRAM_B, momentary to GND forces reconfiguration",
    "J4":  "Reset, momentary to GND",
    "J5":  "Stereo line out, to panel jacks",
    "J6":  "Pitch potentiometer, panel mounted",
    "J7":  "Decay potentiometer, panel mounted",
    "J8":  "Timbre potentiometer, panel mounted",
    "J9":  "Rotary encoder with switch, panel mounted",
    "J10": "Mode selector switch, panel mounted",
    "J11": "Status LEDs x4, anodes -- series resistors are on-board",
    "J12": "Pitch CV input jack, 0-5 V",
    "J13": "Mod CV input jack, 0-5 V",
    "J14": "Gate input jack",
    "J15": "MIDI DIN socket, pins 4 and 5",
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board")
    ap.add_argument("--netlist", required=True)
    ap.add_argument("--panel", required=True)
    a = ap.parse_args()

    board = pcbnew.LoadBoard(a.board)
    nets = defaultdict(list)
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetname():
                nets[pad.GetNetname()].append(
                    (fp.GetReference(), pad.GetNumber()))

    def key(r):
        m = re.match(r"([A-Za-z]+)(\d+)", r[0])
        return (m.group(1), int(m.group(2)), r[1]) if m else (r[0], 0, r[1])

    with open(a.netlist, "w") as f:
        f.write("Courant Rev A -- netlist, extracted from the routed board\n")
        f.write(f"{len(nets)} nets, "
                f"{sum(len(v) for v in nets.values())} connections\n\n")
        for name in sorted(nets):
            pads = sorted(nets[name], key=key)
            f.write(f"{name}  ({len(pads)})\n")
            for ref, num in pads:
                f.write(f"    {ref}.{num}\n")
            f.write("\n")

    rows = []
    for ref, purpose in PANEL.items():
        fp = board.FindFootprintByReference(ref)
        if fp is None:
            continue
        for pad in sorted(fp.Pads(), key=lambda p: int(p.GetNumber())):
            rows.append({"Connector": ref, "Pin": pad.GetNumber(),
                         "Net": pad.GetNetname(), "Purpose": purpose})
    with open(a.panel, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["Connector", "Pin", "Net", "Purpose"])
        w.writeheader(); w.writerows(rows)

    print(f"  netlist  {len(nets)} nets -> {a.netlist}")
    print(f"  panel    {len(rows)} pins on {len(PANEL)} headers -> {a.panel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
