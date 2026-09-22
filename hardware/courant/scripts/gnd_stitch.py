#!/usr/bin/env python3
"""
Replace the back-side decoupling caps' ground daisy-chain with plane vias.

The autorouter connected the 38 decoupling capacitors' ground pads by running
B.Cu traces from one cap to the next, 3 mm at a time, threading between the BGA
balls. Electrically that is poor -- a cap's return current takes a sideways trip
through its neighbours instead of dropping into the ground plane a fraction of a
millimetre below -- and it is also what blocks the escape slots the remaining
BGA balls need, because those chains run exactly through the diagonal gaps.

Both problems have the same fix: delete the chain and give each ground pad its
own via into the plane.

Each removal orphans whatever was downstream, so the two go together: cut, then
re-via every ground pad DRC reports as disconnected, repeat until stable. The
whole thing is judged at the end by KiCad, and discarded unless the board comes
out at least as good as it went in.

    python3 scripts/gnd_stitch.py BOARD --out OUT
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


def clear_spot(board, net, px, py, need, limit=1.5):
    for r in [i * 0.05 for i in range(2, int(limit / 0.05) + 1)]:
        for k in range(32):
            ang = 2 * math.pi * k / 32
            sx, sy = px + r * math.cos(ang), py + r * math.sin(ang)
            ok = True
            for t in board.GetTracks():
                if t.GetNetCode() == net:
                    continue
                if t.Type() == pcbnew.PCB_VIA_T:
                    p = t.GetPosition()
                    if math.hypot(p.x/1e6-sx, p.y/1e6-sy) < t.GetWidth(pcbnew.F_Cu)/2/1e6 + need:
                        ok = False; break
                else:
                    a, e = t.GetStart(), t.GetEnd(); rr = t.GetWidth()/2/1e6
                    x1, y1, x2, y2 = a.x/1e6, a.y/1e6, e.x/1e6, e.y/1e6
                    dx, dy = x2-x1, y2-y1; L = dx*dx + dy*dy
                    tt = 0 if L == 0 else max(0, min(1, ((sx-x1)*dx + (sy-y1)*dy)/L))
                    if math.hypot(sx-(x1+tt*dx), sy-(y1+tt*dy)) < rr + need:
                        ok = False; break
            if ok:
                for fp in board.GetFootprints():
                    for pad in fp.Pads():
                        if pad.GetNetCode() == net:
                            continue
                        p = pad.GetPosition()
                        rr = max(pad.GetSize().x, pad.GetSize().y)/2/1e6
                        if math.hypot(p.x/1e6-sx, p.y/1e6-sy) < rr + need:
                            ok = False; break
                    if not ok:
                        break
            if ok:
                return (sx, sy)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--clearance", type=float, default=0.16)
    ap.add_argument("--via", type=float, default=0.55)
    ap.add_argument("--drill", type=float, default=0.25)
    ap.add_argument("--max-len", type=float, default=3.5,
                    help="longest B.Cu ground hop treated as chain, in mm")
    a = ap.parse_args()

    work = Path(a.out); shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    if pro.is_file():
        shutil.copy(pro, work.with_suffix(".kicad_pro"))
    v0, u0, _ = drc(str(work))
    print(f"  start    {v0} violation(s), {u0} unconnected")
    need = a.via / 2 + a.clearance

    board = pcbnew.LoadBoard(str(work))
    gnd = board.FindNet("GND").GetNetCode()
    # Ground pads of the back-side decoupling array.
    pads = [(fp.GetReference(), pad.GetPosition())
            for fp in board.GetFootprints() if fp.IsFlipped()
            for pad in fp.Pads() if pad.GetNetCode() == gnd]
    near = lambda p, q: math.hypot(p.x-q.x, p.y-q.y)/1e6 < 0.4

    doomed = []
    for t in board.GetTracks():
        if t.Type() != pcbnew.PCB_TRACE_T or t.GetNetCode() != gnd:
            continue
        if t.GetLayer() != pcbnew.B_Cu or t.GetLength()/1e6 > a.max_len:
            continue
        s, e = t.GetStart(), t.GetEnd()
        if any(near(s, q) for _, q in pads) and any(near(e, q) for _, q in pads):
            doomed.append(t)
    for t in doomed:
        board.Remove(t)
    print(f"  cut      {len(doomed)} chain hop(s) between decoupling ground pads")
    pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
    pcbnew.SaveBoard(str(work), board)

    total_vias = 0
    for _ in range(12):
        v, u, data = drc(str(work))
        orphans = []
        for e in data.get("unconnected_items", []):
            for i in e["items"]:
                if "[GND]" in i["description"] and " of C" in i["description"]:
                    orphans.append((i["description"].split(" of ")[1].split()[0],
                                    i["pos"]["x"], i["pos"]["y"]))
        if not orphans:
            break
        board = pcbnew.LoadBoard(str(work))
        gnd = board.FindNet("GND").GetNetCode()
        added = 0
        for ref, px, py in orphans:
            spot = clear_spot(board, gnd, px, py, need)
            if not spot:
                continue
            via = pcbnew.PCB_VIA(board)
            via.SetPosition(pcbnew.VECTOR2I(int(spot[0]*NM), int(spot[1]*NM)))
            via.SetWidth(int(a.via*NM)); via.SetDrill(int(a.drill*NM))
            via.SetNetCode(gnd); via.SetViaType(pcbnew.VIATYPE_THROUGH); board.Add(via)
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(pcbnew.VECTOR2I(int(px*NM), int(py*NM)))
            t.SetEnd(pcbnew.VECTOR2I(int(spot[0]*NM), int(spot[1]*NM)))
            t.SetWidth(int(0.3*NM)); t.SetLayer(pcbnew.B_Cu)
            t.SetNetCode(gnd); board.Add(t)
            added += 1
        if not added:
            break
        total_vias += added
        pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
        pcbnew.SaveBoard(str(work), board)
    print(f"  vias     {total_vias} ground pad(s) dropped straight into the plane")

    vf, uf, _ = drc(str(work))
    print(f"\n  result   {v0} -> {vf} violation(s), {u0} -> {uf} unconnected")
    if vf > v0 or uf > u0:
        print("  NOTE     not an improvement; discard this file")
    print(f"  wrote    {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
