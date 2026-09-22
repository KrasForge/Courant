#!/usr/bin/env python3
"""
Escape the remaining BGA balls: free a slot if a capacitor is on it, then route.

The connections the autorouter leaves on this board all start at a BGA ball
that has no usable escape. Three facts make them tractable, and missing any one
of them is what defeated earlier attempts here:

  * Only the four *adjacent* diagonal slots are reachable. A slot two pitches
    away may be clear and still useless, because the straight line to it passes
    through another ball. An earlier version returned exactly such a slot for
    K10 and then could not understand why nothing worked.

  * The blocker is usually a capacitor, not a trace. The back-side decoupling
    array sits on a 3 mm grid inside the ball field, and a 0402 pad is 0.64 mm
    across against a 0.425 mm clearance requirement -- so a cap centred on a
    ball blocks all four of its slots. No router can shove a component. Moving
    it 0.3 mm frees two.

  * Below F.Cu there are no ball pads at all. U1's pads are top-layer only, so
    once a via reaches In2 the 1.0 mm ball grid stops being an obstacle and
    the 0.05 mm corridor problem disappears. Route out on an inner layer.

Every change is checked by KiCad's DRC and rolled back unless the board
strictly improves.

    python3 scripts/bga_escape.py BOARD --out OUT
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, heapq, json, math, os, shutil, subprocess, tempfile
from pathlib import Path
import numpy as np


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


def blockers(board, net, sx, sy, need):
    """What stops a via at (sx, sy): (movable footprints, other obstructions)."""
    fps, other = set(), 0
    for t in board.GetTracks():
        if t.GetNetCode() == net:
            continue
        if t.Type() == pcbnew.PCB_VIA_T:
            p = t.GetPosition(); r = t.GetWidth(pcbnew.F_Cu) / 2 / 1e6
            if math.hypot(p.x/1e6 - sx, p.y/1e6 - sy) < r + need:
                other += 1
        else:
            a, e = t.GetStart(), t.GetEnd(); r = t.GetWidth() / 2 / 1e6
            x1, y1, x2, y2 = a.x/1e6, a.y/1e6, e.x/1e6, e.y/1e6
            dx, dy = x2-x1, y2-y1; L = dx*dx + dy*dy
            tt = 0 if L == 0 else max(0, min(1, ((sx-x1)*dx + (sy-y1)*dy)/L))
            if math.hypot(sx-(x1+tt*dx), sy-(y1+tt*dy)) < r + need:
                other += 1
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() == net:
                continue
            p = pad.GetPosition()
            r = max(pad.GetSize().x, pad.GetSize().y) / 2 / 1e6
            if math.hypot(p.x/1e6 - sx, p.y/1e6 - sy) < r + need:
                # A two-pad passive can be nudged; a BGA or IC cannot.
                if fp.GetPadCount() <= 2:
                    fps.add(fp.GetReference())
                else:
                    other += 1
    return fps, other


def try_nudge(board, fpref, slot, need, limit=0.6, step=0.1):
    """Smallest move of a two-pad part that clears `slot`, or None."""
    fp = next((f for f in board.GetFootprints() if f.GetReference() == fpref), None)
    if fp is None:
        return None
    orig = fp.GetPosition()
    best = None
    n = int(limit / step)
    for i in range(-n, n + 1):
        for j in range(-n, n + 1):
            if i == 0 and j == 0:
                continue
            dx, dy = i * step, j * step
            if math.hypot(dx, dy) > limit:
                continue
            ok = True
            for pad in fp.Pads():
                p = pad.GetPosition()
                r = max(pad.GetSize().x, pad.GetSize().y) / 2 / 1e6
                if math.hypot(p.x/1e6 + dx - slot[0], p.y/1e6 + dy - slot[1]) < r + need:
                    ok = False; break
            if ok:
                d = math.hypot(dx, dy)
                if best is None or d < best[0]:
                    best = (d, dx, dy)
    return best


class Grid:
    """Rasterised obstacles for the inner-layer run. No ball pads exist here."""

    def __init__(self, step, layers, bbox):
        self.step, self.layers = step, layers
        self.idx = {ly: i for i, ly in enumerate(layers)}
        self.x0, self.y0 = bbox[0], bbox[2]
        self.w = int((bbox[1] - bbox[0]) / step) + 2
        self.h = int((bbox[3] - bbox[2]) / step) + 2

    def cell(self, x, y):
        return (int((x - self.x0) / self.step), int((y - self.y0) / self.step))

    def mm(self, cx, cy):
        return (self.x0 + cx * self.step, self.y0 + cy * self.step)

    def build(self, board, net, need):
        b = np.zeros((len(self.layers), self.h, self.w), dtype=bool)

        def stamp(i, x, y, r):
            cx, cy = self.cell(x, y)
            rr = max(1, int(math.ceil(r / self.step)))
            xl, xh = max(0, cx-rr), min(self.w, cx+rr+1)
            yl, yh = max(0, cy-rr), min(self.h, cy+rr+1)
            if xl < xh and yl < yh:
                b[i, yl:yh, xl:xh] = True

        for t in board.GetTracks():
            if t.GetNetCode() == net:
                continue
            if t.Type() == pcbnew.PCB_VIA_T:
                p = t.GetPosition(); r = t.GetWidth(pcbnew.F_Cu)/2/1e6 + need
                for i in range(len(self.layers)):
                    stamp(i, p.x/1e6, p.y/1e6, r)
            else:
                if t.GetLayer() not in self.idx:
                    continue
                i = self.idx[t.GetLayer()]
                a, e = t.GetStart(), t.GetEnd(); r = t.GetWidth()/2/1e6 + need
                n = max(1, int(math.hypot(e.x-a.x, e.y-a.y)/1e6/self.step))
                for k in range(n+1):
                    stamp(i, (a.x+(e.x-a.x)*k/n)/1e6, (a.y+(e.y-a.y)*k/n)/1e6, r)
        for fp in board.GetFootprints():
            for pad in fp.Pads():
                if pad.GetNetCode() == net:
                    continue
                p = pad.GetPosition()
                r = max(pad.GetSize().x, pad.GetSize().y)/2/1e6 + need
                for i, ly in enumerate(self.layers):
                    if pad.IsOnLayer(ly):
                        stamp(i, p.x/1e6, p.y/1e6, r)
        return b


def astar(b, start, goals, via_cost, shape, via_ok=None):
    """A* where a layer change is only allowed where a via can actually go.

    The subtle bug this exists to prevent: a through via spans every copper
    layer, so changing layer at (x, y) needs (x, y) clear on *all* of them, not
    just the one being moved to. Checking only the destination layer produces
    routes that look fine and drop vias into other nets -- it put one 0.107 mm
    from a V1 ball and shorted another to V3V3.
    """
    nl, h, w = shape
    gx = sum(g[1] for g in goals)/len(goals); gy = sum(g[2] for g in goals)/len(goals)
    hf = lambda x, y: int(10*max(abs(x-gx), abs(y-gy)) + 4*min(abs(x-gx), abs(y-gy)))
    INF = 1 << 30
    dist = {start: 0}; prev = {}; pq = [(hf(start[1], start[2]), 0, start)]
    steps = [(dx, dy, 10 if not (dx and dy) else 14)
             for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy]
    while pq:
        _, d, cur = heapq.heappop(pq)
        if d > dist.get(cur, INF):
            continue
        if cur in goals:
            path = [cur]
            while path[-1] in prev:
                path.append(prev[path[-1]])
            return list(reversed(path))
        li, x, y = cur
        for dx, dy, c in steps:
            nx, ny = x+dx, y+dy
            if not (0 <= nx < w and 0 <= ny < h) or b[li, ny, nx]:
                continue
            nd = d+c; nxt = (li, nx, ny)
            if nd < dist.get(nxt, INF):
                dist[nxt], prev[nxt] = nd, cur
                heapq.heappush(pq, (nd+hf(nx, ny), nd, nxt))
        if via_ok is not None and not via_ok[y, x]:
            continue
        for nli in range(nl):
            if nli == li or b[nli, y, x]:
                continue
            nd = d+via_cost; nxt = (nli, x, y)
            if nd < dist.get(nxt, INF):
                dist[nxt], prev[nxt] = nd, cur
                heapq.heappush(pq, (nd+hf(x, y), nd, nxt))
    return None


def emit(board, g, path, net, width_nm, via_d, via_drill):
    runs, cur = [], [path[0]]
    for n in path[1:]:
        if n[0] == cur[-1][0]:
            cur.append(n)
        else:
            runs.append(cur); cur = [n]
    runs.append(cur)
    length = 0.0
    for run in runs:
        pts = [run[0]]
        for i in range(1, len(run)-1):
            if (run[i][1]-run[i-1][1], run[i][2]-run[i-1][2]) != \
               (run[i+1][1]-run[i][1], run[i+1][2]-run[i][2]):
                pts.append(run[i])
        if len(run) > 1:
            pts.append(run[-1])
        for a, c in zip(pts, pts[1:]):
            ax, ay = g.mm(a[1], a[2]); cx, cy = g.mm(c[1], c[2])
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(pcbnew.VECTOR2I(int(ax*NM), int(ay*NM)))
            t.SetEnd(pcbnew.VECTOR2I(int(cx*NM), int(cy*NM)))
            t.SetWidth(width_nm); t.SetLayer(g.layers[run[0][0]])
            t.SetNetCode(net); board.Add(t)
            length += math.hypot(cx-ax, cy-ay)
    for a, c in zip(runs, runs[1:]):
        vx, vy = g.mm(a[-1][1], a[-1][2])
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(pcbnew.VECTOR2I(int(vx*NM), int(vy*NM)))
        v.SetWidth(via_d); v.SetDrill(via_drill); v.SetNetCode(net)
        v.SetViaType(pcbnew.VIATYPE_THROUGH); board.Add(v)
    return length


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--grid", type=float, default=0.1)
    ap.add_argument("--clearance", type=float, default=0.16)
    ap.add_argument("--width", type=float, default=0.15)
    ap.add_argument("--via", type=float, default=0.55)
    ap.add_argument("--drill", type=float, default=0.25)
    ap.add_argument("--via-cost", type=int, default=300)
    ap.add_argument("--margin", type=float, default=8.0)
    ap.add_argument("--detour", type=float, default=3.0)
    a = ap.parse_args()

    work = Path(a.out); shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    if pro.is_file():
        shutil.copy(pro, work.with_suffix(".kicad_pro"))
    v0, u0, _ = drc(str(work))
    print(f"  start    {v0} violation(s), {u0} unconnected")
    need = a.via/2 + a.clearance
    moved, kept, failed = [], 0, 0

    while True:
        v_now, u_now, data = drc(str(work))
        progressed = False
        for e in data.get("unconnected_items", []):
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
            if ib.Type() == pcbnew.PCB_PAD_T and ia.Type() != pcbnew.PCB_PAD_T:
                ia, ib = ib, ia; items = [items[1], items[0]]
            if ia.Type() != pcbnew.PCB_PAD_T:
                continue
            net, name = ia.GetNetCode(), ia.GetNetname()
            ball = (items[0]["pos"]["x"], items[0]["pos"]["y"])
            dest = (items[1]["pos"]["x"], items[1]["pos"]["y"])
            direct = math.hypot(ball[0]-dest[0], ball[1]-dest[1])

            # Only the four adjacent diagonal slots are reachable from a ball.
            cands = [(ball[0]+dx, ball[1]+dy)
                     for dx in (-0.5, 0.5) for dy in (-0.5, 0.5)]
            slot = nudge = None
            for sx, sy in cands:
                fps, other = blockers(board, net, sx, sy, need)
                if other == 0 and not fps:
                    slot = (sx, sy); break
            if slot is None:
                for sx, sy in cands:
                    fps, other = blockers(board, net, sx, sy, need)
                    if other == 0 and len(fps) == 1:
                        ref = next(iter(fps))
                        nd = try_nudge(board, ref, (sx, sy), need)
                        if nd:
                            slot, nudge = (sx, sy), (ref, nd[1], nd[2]); break
            if slot is None:
                failed += 1
                continue

            if nudge:
                ref, dx, dy = nudge
                fp = next(f for f in board.GetFootprints() if f.GetReference() == ref)
                p = fp.GetPosition()
                fp.SetPosition(pcbnew.VECTOR2I(int(p.x + dx*NM), int(p.y + dy*NM)))

            planes = {ly for z in board.Zones()
                      if z.GetNetname() in ("GND", "AGND", "DGND")
                      for ly in z.GetLayerSet().CuStack()}
            own = {ly for z in board.Zones() if z.GetNetCode() == net
                   for ly in z.GetLayerSet().CuStack()}
            layers = [ly for ly in board.GetEnabledLayers().CuStack()
                      if ly not in planes or ly in own]
            xs = [ball[0], dest[0], slot[0]]; ys = [ball[1], dest[1], slot[1]]
            bbox = (min(xs)-a.margin, max(xs)+a.margin, min(ys)-a.margin, max(ys)+a.margin)
            g = Grid(a.grid, layers, bbox)
            b = g.build(board, net, a.clearance + a.width/2)
            start = (0,) + g.cell(*slot)
            dl = ib.GetLayer() if ib.Type() == pcbnew.PCB_TRACE_T else pcbnew.F_Cu
            if dl not in g.idx:
                dl = pcbnew.F_Cu
            # Aim at the whole destination item, not the one point DRC named.
            # A trace can be joined anywhere along its length, and the reported
            # endpoint is often walled in by the copper around it -- which looks
            # exactly like "no route exists" when the trace is wide open 2 mm
            # further along.
            goals = set()
            if ib.Type() == pcbnew.PCB_TRACE_T and ib.GetLayer() in g.idx:
                gi = g.idx[ib.GetLayer()]
                sa, se = ib.GetStart(), ib.GetEnd()
                n = max(1, int(math.hypot(se.x-sa.x, se.y-sa.y)/1e6/g.step))
                for k in range(n+1):
                    goals.add((gi,) + g.cell((sa.x+(se.x-sa.x)*k/n)/1e6,
                                             (sa.y+(se.y-sa.y)*k/n)/1e6))
            elif ib.Type() == pcbnew.PCB_VIA_T:
                c = g.cell(ib.GetPosition().x/1e6, ib.GetPosition().y/1e6)
                goals = {(i,) + c for i in range(len(layers))}
            else:
                goals = {(g.idx[dl],) + g.cell(*dest)}
            goals = {gg for gg in goals
                     if 0 <= gg[1] < g.w and 0 <= gg[2] < g.h}
            if not goals:
                failed += 1
                continue
            b[start[0], start[2], start[1]] = False
            for gg in goals:
                b[gg[0], gg[2], gg[1]] = False
            via_ok = ~b.any(axis=0)
            # The escape via sits at `start` by construction, and the goal is
            # copper we are joining -- both are legal transition points even
            # though the surrounding layers read as occupied.
            via_ok[start[2], start[1]] = True
            for gg in goals:
                via_ok[gg[2], gg[1]] = True
            path = astar(b, start, goals, a.via_cost, (len(layers), g.h, g.w), via_ok)
            if path is None:
                failed += 1
                continue

            v = pcbnew.PCB_VIA(board)
            v.SetPosition(pcbnew.VECTOR2I(int(slot[0]*NM), int(slot[1]*NM)))
            v.SetWidth(int(a.via*NM)); v.SetDrill(int(a.drill*NM))
            v.SetNetCode(net); v.SetViaType(pcbnew.VIATYPE_THROUGH); board.Add(v)
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(pcbnew.VECTOR2I(int(ball[0]*NM), int(ball[1]*NM)))
            t.SetEnd(pcbnew.VECTOR2I(int(slot[0]*NM), int(slot[1]*NM)))
            t.SetWidth(int(a.width*NM)); t.SetLayer(pcbnew.F_Cu)
            t.SetNetCode(net); board.Add(t)
            length = emit(board, g, path, net, int(a.width*NM),
                          int(a.via*NM), int(a.drill*NM))
            if length > a.detour * max(direct, 1.0):
                failed += 1
                continue

            pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
            trial = tempfile.mktemp(suffix=".kicad_pcb")
            if pro.is_file():
                shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
            pcbnew.SaveBoard(trial, board)
            v1, u1, _ = drc(trial)
            if v1 <= v_now and u1 < u_now:
                shutil.move(trial, str(work))
                note = f", moved {nudge[0]} by ({nudge[1]:+.1f},{nudge[2]:+.1f}) mm" if nudge else ""
                if nudge:
                    moved.append((nudge[0], nudge[1], nudge[2]))
                print(f"  ROUTED   {name:14s} {length:5.1f} mm via ({slot[0]:.2f},{slot[1]:.2f})"
                      f"{note}  -> {v1} viol, {u1} unconnected")
                kept += 1; progressed = True
                break
            os.unlink(trial); failed += 1
        if not progressed:
            break

    vf, uf, _ = drc(str(work))
    print(f"\n  result   {kept} routed, {failed} not")
    print(f"           {v0} -> {vf} violation(s), {u0} -> {uf} unconnected")
    if moved:
        print("  moved    " + "; ".join(f"{r} by ({x:+.1f},{y:+.1f}) mm" for r, x, y in moved))
        print("           mirror these into design.ts")
    print(f"  wrote    {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
