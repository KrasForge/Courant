#!/usr/bin/env python3
"""
Move a capacitor a fraction of a millimetre so its neighbour can connect.

Under a 1.0 mm BGA the thing that blocks a connection is often not other
routing but a capacitor's own opposite land: a 0201 at 45 degrees puts its
second pad 0.66 mm from its first, and a trace leaving the first pad has to
pass within 0.25 mm of the second. Twenty micrometres decides it, and no
router can help because routers do not move components.

This tries small offsets of the named footprint -- eight directions, growing
radius -- and after each one asks scripts/hop.py's placement search whether the
connection can now be made. The first offset that produces a DRC-clean board
with fewer unconnected pairs wins; everything else is rolled back.

Only footprints with no copper attached are safe to move this way, and the
script refuses otherwise: moving a pad out from under its own trace trades one
broken connection for another.

    python3 scripts/nudge.py BOARD --out OUT --ref C107 [--ref C134]
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, math, os, shutil, subprocess, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import pcbnew, NM, drc

HOP = Path(__file__).resolve().parent / "hop.py"


def attached(board, fp):
    lands = {(p.GetPosition().x, p.GetPosition().y) for p in fp.Pads()}
    return sum(1 for t in board.GetTracks() if t.Type() == pcbnew.PCB_TRACE_T
               and any((q.x, q.y) in lands for q in (t.GetStart(), t.GetEnd())))


def offsets(step, rings):
    for r in range(1, rings + 1):
        for k in range(8):
            a = k * math.pi / 4
            yield round(math.cos(a) * step * r, 4), round(math.sin(a) * step * r, 4)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--ref", action="append", required=True)
    ap.add_argument("--step", type=float, default=0.15)
    ap.add_argument("--rings", type=int, default=3)
    a = ap.parse_args()

    work = Path(a.out)
    shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    pro = str(pro) if pro.is_file() else None
    if pro:
        shutil.copy(pro, work.with_suffix(".kicad_pro"))

    v0, u0, _ = drc(str(work))
    print(f"  start      {v0} violation(s), {u0} unconnected pair(s)\n")

    for ref in a.ref:
        board = pcbnew.LoadBoard(str(work))
        fp = board.FindFootprintByReference(ref)
        if fp is None:
            print(f"  {ref:6} no such footprint"); continue
        n = attached(board, fp)
        if n:
            print(f"  {ref:6} REFUSED: {n} segment(s) attached; moving it would "
                  f"break them"); continue
        home = fp.GetPosition()
        best = None
        for dx, dy in offsets(a.step, a.rings):
            board = pcbnew.LoadBoard(str(work))
            fp = board.FindFootprintByReference(ref)
            fp.SetPosition(pcbnew.VECTOR2I(int(home.x + dx * NM),
                                           int(home.y + dy * NM)))
            pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
            moved = tempfile.mktemp(suffix=".kicad_pcb")
            if pro:
                shutil.copy(pro, Path(moved).with_suffix(".kicad_pro"))
            pcbnew.SaveBoard(moved, board)
            out = tempfile.mktemp(suffix=".kicad_pcb")
            r = subprocess.run([sys.executable, str(HOP), moved, "--out", out],
                               capture_output=True, text=True)
            if not os.path.exists(out):
                os.unlink(moved); continue
            v1, u1, _ = drc(out)
            os.unlink(moved)
            if v1 <= v0 and u1 < u0:
                print(f"  {ref:6} moved ({dx:+.2f}, {dy:+.2f}) mm  -> "
                      f"{v1} violation(s), {u1} unconnected")
                shutil.move(out, str(work))
                v0, u0 = v1, u1
                best = (dx, dy)
                break
            os.unlink(out)
        if best is None:
            print(f"  {ref:6} no offset within {a.step * a.rings:.2f} mm helped")

    vf, uf, _ = drc(str(work))
    print(f"\n  result     {vf} violation(s), {uf} unconnected pair(s)")
    print(f"  wrote      {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
