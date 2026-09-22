#!/usr/bin/env python3
"""
Close what the router left open, and say what it could not.

Run this on an imported routed board. It reports the residue by net, then
closes the part that is mechanical: a capacitor land on GND or V3V3 only has
to reach a plane, and In1/In4 and In3 cover the whole board, so the connection
is a short link to neighbouring copper of the same net or -- failing that -- a
via of its own.

Link first, via second, deliberately. Vias are the scarce resource under a
1.0 mm BGA: 225 interior slots, less the 38 the capacitor array sits on, is
187 usable, against 36 signal escapes plus 76 power ball vias plus 76
capacitor lands = 188 wanted. One via per land does not fit and strands
whichever lands are handled last, which is exactly what happened the first
time this was tried. Chaining neighbours onto a shared via is what the
original routing did, and it was right to.

V1 and V1V8 have no plane anywhere in the six-layer stackup, so their lands
cannot be closed this way and are reported rather than touched.

Every change is checked: the board is kept only if KiCad's DRC reports no more
violations and no more unconnected items than it started with.

    python3 scripts/finish.py BOARD --out OUT
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, collections, json, os, re, shutil, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import pcbnew, NM, drc, repair, PLANE_NETS


def residue(data):
    """Unconnected items grouped by net, read out of the DRC report."""
    by_net = collections.Counter()
    where = collections.defaultdict(list)
    for e in data.get("unconnected_items", []):
        for it in e.get("items", []):
            m = re.search(r"\[([^\]]+)\]", it.get("description", ""))
            if not m:
                continue
            by_net[m.group(1)] += 1
            where[m.group(1)].append((it["pos"]["x"], it["pos"]["y"],
                                      it.get("description", "")))
    return by_net, where


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--reach", type=float, default=1.6)
    ap.add_argument("--clearance", type=float, default=0.15)
    ap.add_argument("--via", type=float, default=0.55)
    ap.add_argument("--drill", type=float, default=0.25)
    ap.add_argument("--width", type=float, default=0.25)
    ap.add_argument("--report-only", action="store_true")
    ap.add_argument("--prefer", choices=("link", "via"), default="link",
                    help="link shares a via with a neighbour and is the right "
                         "default under the ball field, where vias are scarce; "
                         "via is what a land cut off from its plane needs")
    a = ap.parse_args()

    work = Path(a.out)
    shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    pro = str(pro) if pro.is_file() else None
    if pro:
        shutil.copy(pro, work.with_suffix(".kicad_pro"))

    v0, u0, data = drc(str(work))
    by_net, where = residue(data)
    print(f"  start      {v0} violation(s), {u0} unconnected pair(s)\n")
    print("  residue by net:")
    for net, n in by_net.most_common():
        tag = ("plane" if net in PLANE_NETS else
               "no plane" if net in ("V1", "V1V8") else "signal")
        print(f"     {net:16} {n:3}   ({tag})")
    if a.report_only:
        return 0

    print()
    board = pcbnew.LoadBoard(str(work))
    added = repair(board, pro, a.via / 2 + a.clearance, a.reach,
                   a.width, a.via, a.drill, prefer=a.prefer)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()

    trial = tempfile.mktemp(suffix=".kicad_pcb")
    if pro:
        shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
    pcbnew.SaveBoard(trial, board)
    v1, u1, data1 = drc(trial)
    print(f"\n  closed     {added} land(s)")
    print(f"  result     {v0} -> {v1} violation(s), {u0} -> {u1} unconnected")
    if v1 > v0 or u1 > u0:
        os.unlink(trial)
        print("  REVERTED   not an improvement; board left untouched")
        return 1
    shutil.move(trial, str(work))
    left, _ = residue(data1)
    if left:
        print("\n  still open:")
        for net, n in left.most_common():
            print(f"     {net:16} {n:3}")
    print(f"\n  wrote      {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
