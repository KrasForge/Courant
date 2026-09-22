#!/usr/bin/env python3
"""
Close short BGA escapes by finding a via slot that is clear on every layer.

The connections the autorouter leaves on this board are mostly a ball on the
top and its decoupling capacitor underneath, needing a via between them. They
are not routing problems and a maze router handles them badly -- it searches for
a path when what is wanted is a hole in the right place.

The one thing that makes this work is checking *all* layers. A through via
crosses six of them, and a slot that is obviously free on F.Cu and B.Cu can be
occupied on In2 by a trace nobody was looking at; two earlier attempts here
placed vias that shorted to exactly that. So the search tests every copper
layer, and then KiCad's DRC checks the result before it is kept.

    python3 scripts/stitch.py BOARD --out OUT [--reach MM]
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, json, math, os, shutil, subprocess, tempfile
from pathlib import Path


def load_pcbnew():
    import importlib
    saved, devnull = os.dup(2), os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 2)
        return importlib.import_module("pcbnew")
    finally:
        os.dup2(saved, 2); os.close(saved); os.close(devnull)


pcbnew = load_pcbnew()
NM = 1_000_000


def drc(path):
    o = tempfile.mktemp(suffix=".json")
    subprocess.run(["kicad-cli", "pcb", "drc", "--output", o, "--format", "json",
                    "--units", "mm", "--severity-error", "--refill-zones", path],
                   capture_output=True, text=True)
    j = json.load(open(o)); os.unlink(o)
    return len(j.get("violations", [])), len(j.get("unconnected_items", [])), j


def obstacles(board, netcode):
    """Foreign copper as discs and segments, with the layers they sit on."""
    discs, segs = [], []
    for t in board.GetTracks():
        if t.GetNetCode() == netcode:
            continue
        if t.Type() == pcbnew.PCB_VIA_T:
            p = t.GetPosition()
            discs.append((p.x / 1e6, p.y / 1e6, t.GetWidth(pcbnew.F_Cu) / 2 / 1e6))
        else:
            a, e = t.GetStart(), t.GetEnd()
            segs.append((a.x / 1e6, a.y / 1e6, e.x / 1e6, e.y / 1e6, t.GetWidth() / 2 / 1e6))
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() == netcode:
                continue
            p = pad.GetPosition(); sz = pad.GetSize()
            discs.append((p.x / 1e6, p.y / 1e6, max(sz.x, sz.y) / 2 / 1e6))
    return discs, segs


def seg_dist(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / L))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def find_slot(discs, segs, a, b, need, reach, step=0.05):
    """A point clear of all foreign copper, reachable from both endpoints."""
    best = None
    steps = int(reach / step)
    for i in range(-steps, steps + 1):
        for j in range(-steps, steps + 1):
            px, py = a[0] + i * step, a[1] + j * step
            if math.hypot(px - a[0], py - a[1]) > reach:
                continue
            if math.hypot(px - b[0], py - b[1]) > reach:
                continue
            ok = True
            for x, y, r in discs:
                if math.hypot(px - x, py - y) < r + need:
                    ok = False; break
            if ok:
                for x1, y1, x2, y2, r in segs:
                    if seg_dist(px, py, x1, y1, x2, y2) < r + need:
                        ok = False; break
            if ok:
                cost = math.hypot(px - a[0], py - a[1]) + math.hypot(px - b[0], py - b[1])
                if best is None or cost < best[0]:
                    best = (cost, px, py)
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--reach", type=float, default=2.5,
                    help="how far a stub may run from either endpoint")
    ap.add_argument("--clearance", type=float, default=0.15)
    ap.add_argument("--via", type=float, default=0.55)
    ap.add_argument("--drill", type=float, default=0.25)
    ap.add_argument("--width", type=float, default=0.25)
    a = ap.parse_args()

    work = Path(a.out)
    shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    if pro.is_file():
        shutil.copy(pro, work.with_suffix(".kicad_pro"))

    v0, u0, _ = drc(str(work))
    print(f"  start    {v0} violation(s), {u0} unconnected")
    need = a.via / 2 + a.clearance

    kept = skipped = reverted = 0
    while True:
        v_now, u_now, data = drc(str(work))
        pending = data.get("unconnected_items", [])
        progressed = False
        for e in pending:
            items = e.get("items", [])
            if len(items) != 2:
                continue
            board = pcbnew.LoadBoard(str(work))
            idx = {t.m_Uuid.AsString(): t for t in board.GetTracks()}
            for fp in board.GetFootprints():
                for pad in fp.Pads():
                    idx[pad.m_Uuid.AsString()] = pad
            ia, ib = idx.get(items[0]["uuid"]), idx.get(items[1]["uuid"])
            if ia is None or ib is None:
                continue
            net = ia.GetNetCode(); name = ia.GetNetname()
            pa = (items[0]["pos"]["x"], items[0]["pos"]["y"])
            pb = (items[1]["pos"]["x"], items[1]["pos"]["y"])
            la = ia.GetLayer() if ia.Type() == pcbnew.PCB_TRACE_T else pcbnew.F_Cu
            lb = ib.GetLayer() if ib.Type() == pcbnew.PCB_TRACE_T else pcbnew.F_Cu

            discs, segs = obstacles(board, net)
            slot = find_slot(discs, segs, pa, pb, need, a.reach)
            if slot is None:
                continue
            _, vx, vy = slot

            v = pcbnew.PCB_VIA(board)
            v.SetPosition(pcbnew.VECTOR2I(int(vx * NM), int(vy * NM)))
            v.SetWidth(int(a.via * NM)); v.SetDrill(int(a.drill * NM))
            v.SetNetCode(net); v.SetViaType(pcbnew.VIATYPE_THROUGH); board.Add(v)
            for (sx, sy), ly in ((pa, la), (pb, lb)):
                t = pcbnew.PCB_TRACK(board)
                t.SetStart(pcbnew.VECTOR2I(int(sx * NM), int(sy * NM)))
                t.SetEnd(pcbnew.VECTOR2I(int(vx * NM), int(vy * NM)))
                t.SetWidth(int(a.width * NM)); t.SetLayer(ly)
                t.SetNetCode(net); board.Add(t)
            pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()

            trial = tempfile.mktemp(suffix=".kicad_pcb")
            if pro.is_file():
                shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
            pcbnew.SaveBoard(trial, board)
            v1, u1, _ = drc(trial)
            if v1 <= v_now and u1 < u_now:
                shutil.move(trial, str(work))
                print(f"  STITCH   {name:14s} via at ({vx:.3f}, {vy:.3f})"
                      f"  -> {v1} violation(s), {u1} unconnected")
                kept += 1; progressed = True
                break
            os.unlink(trial)
            reverted += 1
        if not progressed:
            break

    vf, uf, _ = drc(str(work))
    print(f"\n  result   {kept} stitched, {reverted} rejected by DRC")
    print(f"           {v0} -> {vf} violation(s), {u0} -> {uf} unconnected")
    if vf > v0 or uf >= u0:
        print("  NOTE     not an improvement; discard this file")
    print(f"  wrote    {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
