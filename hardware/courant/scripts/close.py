#!/usr/bin/env python3
"""
Close the remaining connections with a real path search.

Everything else in scripts/ places copper along a shape decided in advance --
a straight line, an L, a 45 degree mitre. That is why they all failed on the
same handful of connections: what those need is a path that turns more than
twice, or that leaves a ball by one slot and arrives at another by a different
one. No amount of varying the search radius fixes a router that can only draw
three shapes.

This rasterises the board into a grid and searches it properly.

Two modes, because the two kinds of connection left are not the same problem:

  * A net with a plane -- GND on In1/In4, V3V3 on In3 -- does not need to reach
    the other endpoint at all. It needs to reach any point where a via is
    legal, because the via lands on the plane and the plane is the connection.
    Searching to the named endpoint, which is what every earlier attempt did,
    solves a harder problem than the board actually poses.

  * A net without one -- V1, V1V8, and the signals -- needs a genuine path
    between two points, free to change layer wherever a via fits.

Never routes on In1.Cu or In4.Cu: they are the ground planes, and a signal
crossing one cuts the return path under everything nearby.

    python3 scripts/close.py BOARD --out OUT [--step MM] [--net NET]
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, heapq, math, os, re, shutil, sys, tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import pcbnew, NM, drc, seg_dist as pe_seg_dist

PLANE_NETS = {"GND", "V3V3"}
PLANES = {"In1.Cu", "In4.Cu", "In3.Cu"}


class Window:
    """A rasterised patch of board, one bit-plane per routable copper layer."""

    def __init__(self, x0, y0, x1, y1, step, layers):
        self.step = step
        self.x0, self.y0 = x0, y0
        self.nx = int((x1 - x0) / step) + 1
        self.ny = int((y1 - y0) / step) + 1
        self.layers = layers
        self.xs = x0 + np.arange(self.nx) * step
        self.ys = y0 + np.arange(self.ny) * step

    def cell(self, x, y):
        return (int(round((y - self.y0) / self.step)),
                int(round((x - self.x0) / self.step)))

    def mm(self, r, c):
        return (self.x0 + c * self.step, self.y0 + r * self.step)

    def inside(self, r, c):
        return 0 <= r < self.ny and 0 <= c < self.nx

    def _box(self, lo_x, lo_y, hi_x, hi_y):
        c0 = max(0, int((lo_x - self.x0) / self.step))
        c1 = min(self.nx - 1, int((hi_x - self.x0) / self.step) + 1)
        r0 = max(0, int((lo_y - self.y0) / self.step))
        r1 = min(self.ny - 1, int((hi_y - self.y0) / self.step) + 1)
        return r0, r1, c0, c1

    def disc(self, grid, x, y, r):
        r0, r1, c0, c1 = self._box(x - r, y - r, x + r, y + r)
        if r1 < r0 or c1 < c0:
            return
        dx = self.xs[c0:c1 + 1][None, :] - x
        dy = self.ys[r0:r1 + 1][:, None] - y
        grid[r0:r1 + 1, c0:c1 + 1] |= (dx * dx + dy * dy) <= r * r

    def segment(self, grid, ax, ay, bx, by, r):
        r0, r1, c0, c1 = self._box(min(ax, bx) - r, min(ay, by) - r,
                                   max(ax, bx) + r, max(ay, by) + r)
        if r1 < r0 or c1 < c0:
            return
        X = self.xs[c0:c1 + 1][None, :]
        Y = self.ys[r0:r1 + 1][:, None]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        if L2 < 1e-12:
            d2 = (X - ax) ** 2 + (Y - ay) ** 2
        else:
            t = np.clip(((X - ax) * dx + (Y - ay) * dy) / L2, 0.0, 1.0)
            d2 = (X - (ax + t * dx)) ** 2 + (Y - (ay + t * dy)) ** 2
        grid[r0:r1 + 1, c0:c1 + 1] |= d2 <= r * r

    def rect(self, grid, x, y, hw, hh, deg, r):
        reach = math.hypot(hw, hh) + r
        r0, r1, c0, c1 = self._box(x - reach, y - reach, x + reach, y + reach)
        if r1 < r0 or c1 < c0:
            return
        a = math.radians(deg)
        ca, sa = math.cos(a), math.sin(a)
        X = self.xs[c0:c1 + 1][None, :] - x
        Y = self.ys[r0:r1 + 1][:, None] - y
        u = np.abs(X * ca + Y * sa) - hw
        v = np.abs(-X * sa + Y * ca) - hh
        u = np.maximum(u, 0.0); v = np.maximum(v, 0.0)
        grid[r0:r1 + 1, c0:c1 + 1] |= (u * u + v * v) <= r * r


def obstacles(board, win, netcode, clearance, trace_half, via_r):
    """Bit-planes of where this net's copper may not go.

    Two different questions, so two different answers: a trace centre only has
    to clear what is on its own layer (plus every through via), while a via
    barrel has to clear everything on every layer at once. Conflating them is
    how an earlier attempt here dropped a via 0.107 mm from a ball on a layer
    it had not looked at.
    """
    blocked = {li: np.zeros((win.ny, win.nx), bool) for li in range(len(win.layers))}
    via_no = np.zeros((win.ny, win.nx), bool)
    index = {l: i for i, l in enumerate(win.layers)}

    def paint(kind, args, layers, extent):
        for l in layers:
            i = index.get(l)
            if i is None:
                continue
            getattr(win, kind)(blocked[i], *args, extent + clearance + trace_half)
        getattr(win, kind)(via_no, *args, extent + clearance + via_r)

    for t in board.GetTracks():
        if t.GetNetCode() == netcode:
            continue
        if isinstance(t, pcbnew.PCB_VIA):
            p = t.GetPosition()
            paint("disc", (p.x / NM, p.y / NM), win.layers,
                  t.GetWidth(pcbnew.F_Cu) / 2 / NM)
        else:
            a, b = t.GetStart(), t.GetEnd()
            paint("segment", (a.x / NM, a.y / NM, b.x / NM, b.y / NM),
                  [t.GetLayer()], t.GetWidth() / 2 / NM)

    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() == netcode:
                continue
            on = [l for l in win.layers if pad.IsOnLayer(l)]
            if not on:
                continue
            p, sz = pad.GetPosition(), pad.GetSize()
            hw, hh = sz.x / 2 / NM, sz.y / 2 / NM
            if pad.GetShape() == pcbnew.PAD_SHAPE_CIRCLE or abs(hw - hh) < 1e-9:
                paint("disc", (p.x / NM, p.y / NM), on, max(hw, hh))
            else:
                paint("rect", (p.x / NM, p.y / NM, hw, hh,
                               pad.GetOrientationDegrees()), on, 0.0)
    return blocked, via_no


STEPS = [(-1, 0, 1.0), (1, 0, 1.0), (0, -1, 1.0), (0, 1, 1.0),
         (-1, -1, 1.4142), (-1, 1, 1.4142), (1, -1, 1.4142), (1, 1, 1.4142)]


def search(win, blocked, via_ok, starts, goals, via_cost):
    """A* over (layer, row, col); a layer change costs a via and needs one legal."""
    goal = set(goals)
    gr, gc = next(iter(goal))[1], next(iter(goal))[2]
    best = {}
    heap = []
    for s in starts:
        best[s] = 0.0
        heapq.heappush(heap, (0.0, 0.0, s, None))
    came = {}
    while heap:
        _, g, cur, prev = heapq.heappop(heap)
        if cur in came:
            continue
        came[cur] = prev
        if cur in goal:
            path = []
            while cur is not None:
                path.append(cur); cur = came[cur]
            return path[::-1]
        li, r, c = cur
        for dr, dc, w in STEPS:
            nr, nc = r + dr, c + dc
            if not win.inside(nr, nc) or blocked[li][nr, nc]:
                continue
            nxt = (li, nr, nc)
            ng = g + w * win.step
            if ng < best.get(nxt, 1e18):
                best[nxt] = ng
                h = math.hypot(nr - gr, nc - gc) * win.step
                heapq.heappush(heap, (ng + h, ng, nxt, cur))
        if via_ok[r, c]:
            for lj in range(len(win.layers)):
                if lj == li or blocked[lj][r, c]:
                    continue
                nxt = (lj, r, c)
                ng = g + via_cost
                if ng < best.get(nxt, 1e18):
                    best[nxt] = ng
                    h = math.hypot(r - gr, c - gc) * win.step
                    heapq.heappush(heap, (ng + h, ng, nxt, cur))
    return None


def to_plane(win, blocked_layer, via_ok, start):
    """Shortest walk on one layer to anywhere a via is legal.

    A net with a plane is connected the moment it reaches a via, wherever that
    via happens to be -- the plane does the rest.
    """
    li, sr, sc = start
    best = {(sr, sc): 0.0}
    came = {(sr, sc): None}
    heap = [(0.0, (sr, sc))]
    while heap:
        g, (r, c) = heapq.heappop(heap)
        if g > best.get((r, c), 1e18):
            continue
        if via_ok[r, c] and (r, c) != (sr, sc):
            path = []
            cur = (r, c)
            while cur is not None:
                path.append((li, cur[0], cur[1])); cur = came[cur]
            return path[::-1]
        for dr, dc, w in STEPS:
            nr, nc = r + dr, c + dc
            if not win.inside(nr, nc) or blocked_layer[nr, nc]:
                continue
            ng = g + w * win.step
            if ng < best.get((nr, nc), 1e18):
                best[(nr, nc)] = ng
                came[(nr, nc)] = (r, c)
                heapq.heappush(heap, (ng, (nr, nc)))
    return None


def simplify(points):
    out = [points[0]]
    for p in points[1:]:
        if len(out) >= 2:
            (x0, y0), (x1, y1), (x2, y2) = out[-2], out[-1], p
            if abs((x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)) < 1e-9:
                out[-1] = p; continue
        out.append(p)
    return out


def emit(board, win, path, code, width, via_d, via_drill, head=None, tail=None):
    added = []
    runs, cur = [], [path[0]]
    for node in path[1:]:
        if node[0] != cur[-1][0]:
            runs.append(cur); cur = [node]
        else:
            cur.append(node)
    runs.append(cur)

    for i, run in enumerate(runs):
        li = run[0][0]
        pts = [win.mm(r, c) for _, r, c in run]
        if i == 0 and head is not None:
            pts[0] = head
        if i == len(runs) - 1 and tail is not None:
            pts[-1] = tail
        pts = simplify(pts)
        for a, b in zip(pts, pts[1:]):
            if math.dist(a, b) < 1e-6:
                continue
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(pcbnew.VECTOR2I(int(a[0] * NM), int(a[1] * NM)))
            t.SetEnd(pcbnew.VECTOR2I(int(b[0] * NM), int(b[1] * NM)))
            t.SetWidth(int(width * NM)); t.SetLayer(win.layers[li])
            t.SetNetCode(code); board.Add(t); added.append(t)
        if i + 1 < len(runs):
            x, y = win.mm(run[-1][1], run[-1][2])
            v = pcbnew.PCB_VIA(board)
            v.SetPosition(pcbnew.VECTOR2I(int(x * NM), int(y * NM)))
            v.SetWidth(int(via_d * NM)); v.SetDrill(int(via_drill * NM))
            v.SetNetCode(code); v.SetViaType(pcbnew.VIATYPE_THROUGH)
            board.Add(v); added.append(v)
    return added


def close_plane_orphans(board, win_args, pro, code_skip, a, verbose=True):
    """Give anything a rip-up orphaned its own way back to its plane.

    Ripping GND or V3V3 out of a corridor is safe precisely because those nets
    have a plane to fall into, but only if whatever the ripped copper was
    carrying is actually given a via. This closes that loop so the rip and the
    repair are judged together, not separately.
    """
    # An unconnected pair has two ends. Healing one leaves the pair listed, so
    # taking "the first plane-net item" every round heals the same end forever
    # and never reaches the end that was actually orphaned.
    healed, seen = 0, set()
    for _ in range(24):
        trial = tempfile.mktemp(suffix=".kicad_pcb")
        if pro:
            shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
        pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
        pcbnew.SaveBoard(trial, board)
        _, _, data = drc(trial)
        os.unlink(trial)
        todo = None
        for e in data.get("unconnected_items", []):
            for it in e.get("items", []):
                m = re.search(r"\[([^\]]+)\]", it.get("description", ""))
                if not m or m.group(1) not in PLANE_NETS:
                    continue
                key = (m.group(1), round(it["pos"]["x"], 3), round(it["pos"]["y"], 3))
                if key in seen:
                    continue
                seen.add(key)
                todo = (m.group(1), it); break
            if todo:
                break
        if not todo:
            return healed
        name, it = todo
        code = board.GetNetsByName()[name].GetNetCode()
        px, py = it["pos"]["x"], it["pos"]["y"]
        routable = win_args
        win = Window(px - a.margin, py - a.margin, px + a.margin, py + a.margin,
                     a.step, routable)
        blocked, via_no = obstacles(board, win, code, a.clearance,
                                    a.width / 2, a.via / 2)
        r, c = win.cell(px, py)
        ls = layers_of(board, it["uuid"], routable)
        if not ls:
            return healed
        li = {l: i for i, l in enumerate(routable)}[ls[0]]
        blocked[li][r, c] = False
        path = to_plane(win, blocked[li], ~via_no, (li, r, c))
        if path is None:
            return healed
        emit(board, win, path, code, a.width, a.via, a.drill, head=(px, py))
        x, y = win.mm(path[-1][1], path[-1][2])
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(pcbnew.VECTOR2I(int(x * NM), int(y * NM)))
        v.SetWidth(int(a.via * NM)); v.SetDrill(int(a.drill * NM))
        v.SetNetCode(code); v.SetViaType(pcbnew.VIATYPE_THROUGH)
        board.Add(v)
        board.BuildConnectivity()
        healed += 1
        if verbose:
            print(f"      heal  {name:5} at ({px:.2f}, {py:.2f}) -> plane via "
                  f"({x:.2f}, {y:.2f})")
    return healed


def own_copper(board, win, netcode):
    """Cells already occupied by this net, per layer.

    The DRC report names one item per side of a break and gives a single point
    on it. Searching from that point is a needless restriction: any part of the
    same island is an equally good place to start, and the reported point is
    often the worst one. The escape via placed at a ball's slot is useless if
    the search insists on setting off from the ball.
    """
    mine = {li: np.zeros((win.ny, win.nx), bool) for li in range(len(win.layers))}
    index = {l: i for i, l in enumerate(win.layers)}
    for t in board.GetTracks():
        if t.GetNetCode() != netcode:
            continue
        if isinstance(t, pcbnew.PCB_VIA):
            p = t.GetPosition()
            for i in mine:
                win.disc(mine[i], p.x / NM, p.y / NM,
                         t.GetWidth(pcbnew.F_Cu) / 2 / NM)
        else:
            i = index.get(t.GetLayer())
            if i is None:
                continue
            a, b = t.GetStart(), t.GetEnd()
            win.segment(mine[i], a.x / NM, a.y / NM, b.x / NM, b.y / NM,
                        t.GetWidth() / 2 / NM)
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() != netcode:
                continue
            p, sz = pad.GetPosition(), pad.GetSize()
            for l in win.layers:
                i = index.get(l)
                if i is None or not pad.IsOnLayer(l):
                    continue
                win.disc(mine[i], p.x / NM, p.y / NM,
                         min(sz.x, sz.y) / 2 / NM)
    return mine


def island(win, mine, x, y, radius, other=None):
    """Cells of this net's copper near (x, y) -- one side of the break.

    `other` is the endpoint on the far side. Cells nearer to it belong to that
    side and are excluded: without the split, two endpoints closer together
    than twice the radius share cells, the search starts where it is meant to
    finish, and the zero-length path it returns connects nothing at all.
    """
    out = []
    r0, c0 = win.cell(x, y)
    span = int(radius / win.step)
    for li, grid in mine.items():
        for r in range(max(0, r0 - span), min(win.ny, r0 + span + 1)):
            for c in range(max(0, c0 - span), min(win.nx, c0 + span + 1)):
                if not grid[r, c]:
                    continue
                if math.hypot(r - r0, c - c0) * win.step > radius:
                    continue
                if other is not None:
                    px, py = win.mm(r, c)
                    if math.dist((px, py), other) < math.dist((px, py), (x, y)):
                        continue
                out.append((li, r, c))
    return out


def layers_of(board, uuid, routable):
    for t in board.GetTracks():
        if t.m_Uuid.AsString() == uuid:
            return list(routable) if isinstance(t, pcbnew.PCB_VIA) else \
                ([t.GetLayer()] if t.GetLayer() in routable else [])
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.m_Uuid.AsString() == uuid:
                return [l for l in routable if pad.IsOnLayer(l)]
    return []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--net", action="append")
    ap.add_argument("--step", type=float, default=0.05)
    ap.add_argument("--margin", type=float, default=4.0)
    ap.add_argument("--clearance", type=float, default=0.15)
    ap.add_argument("--width", type=float, default=0.15)
    ap.add_argument("--via", type=float, default=0.55)
    ap.add_argument("--drill", type=float, default=0.25)
    ap.add_argument("--via-cost", type=float, default=1.5)
    ap.add_argument("--rip-planes", action="store_true",
                    help="when no path exists, move GND/V3V3 copper out of the "
                         "way and give it a via back to its plane")
    ap.add_argument("--rip-radius", type=float, default=1.6)
    ap.add_argument("--guard", type=float, default=0.75,
                    help="extra clearance, in grid steps, to keep diagonal "
                         "moves legal between cells that are each only just legal")
    ap.add_argument("--island", type=float, default=3.0,
                    help="start and finish anywhere on the net's own copper "
                         "within this radius of each reported endpoint")
    ap.add_argument("--long-step", type=float, default=0.1,
                    help="grid for spans over 12 mm; the default trades "
                         "resolution for a tractable search, which is too "
                         "coarse to thread a 1.0 mm ball field")
    a = ap.parse_args()

    work = Path(a.out)
    shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    pro = str(pro) if pro.is_file() else None
    if pro:
        shutil.copy(pro, work.with_suffix(".kicad_pro"))

    v0, u0, _ = drc(str(work))
    print(f"  start      {v0} violation(s), {u0} unconnected pair(s)\n")

    tries: dict = {}
    while True:
        v_now, u_now, data = drc(str(work))
        board = pcbnew.LoadBoard(str(work))
        routable = [l for l in board.GetEnabledLayers().CuStack()
                    if board.GetLayerName(l) not in ("In1.Cu", "In4.Cu")]
        progressed = False

        for e in data.get("unconnected_items", []):
            its = e.get("items", [])
            if len(its) != 2:
                continue
            m = re.search(r"\[([^\]]+)\]", its[0].get("description", ""))
            name = m.group(1) if m else None
            if not name or (a.net and name not in a.net):
                continue
            code = board.GetNetsByName()[name].GetNetCode()
            (ax, ay), (bx, by) = ((i["pos"]["x"], i["pos"]["y"]) for i in its)
            la = layers_of(board, its[0]["uuid"], routable)
            lb = layers_of(board, its[1]["uuid"], routable)
            if not la or not lb:
                continue

            span = math.dist((ax, ay), (bx, by))
            step = a.step if span < 12 else a.long_step
            win = Window(min(ax, bx) - a.margin, min(ay, by) - a.margin,
                         max(ax, bx) + a.margin, max(ay, by) + a.margin,
                         step, routable)
            # The mask marks a cell when its *centre* is too close. A diagonal
            # step between two acceptable cells passes nearer than either of
            # them, by up to about a step, so the grid is given a guard band or
            # the path is legal by construction and illegal by DRC.
            guard = a.clearance + step * a.guard
            blocked, via_no = obstacles(board, win, code, guard,
                                        a.width / 2, a.via / 2)
            via_ok = ~via_no
            ra, ca = win.cell(ax, ay)
            rb, cb = win.cell(bx, by)
            idx = {l: i for i, l in enumerate(routable)}
            mine = own_copper(board, win, code)
            starts = [(idx[l], ra, ca) for l in la]
            goals = [(idx[l], rb, cb) for l in lb]
            starts += island(win, mine, ax, ay, a.island, other=(bx, by))
            goals += island(win, mine, bx, by, a.island, other=(ax, ay))
            for li, r, c in starts + goals:
                blocked[li][r, c] = False

            path = search(win, blocked, via_ok, starts, goals, a.via_cost)
            mode = "route"
            ripped = []
            if path is None and a.rip_planes and name not in PLANE_NETS:
                # The corridors this net needs are held by GND and V3V3, which
                # can be moved: they have a plane underneath and a via reaches
                # it from anywhere. Nothing else on the board may be touched.
                for t in list(board.GetTracks()):
                    if t.Type() != pcbnew.PCB_TRACE_T or t.GetNetCode() == code:
                        continue
                    if t.GetNetname() not in PLANE_NETS:
                        continue
                    s_, e_ = t.GetStart(), t.GetEnd()
                    near = min(
                        pe_seg_dist(ax, ay, s_.x / NM, s_.y / NM, e_.x / NM, e_.y / NM),
                        pe_seg_dist(bx, by, s_.x / NM, s_.y / NM, e_.x / NM, e_.y / NM))
                    if near < a.rip_radius:
                        ripped.append(t)
                for t in ripped:
                    board.RemoveNative(t)
                if ripped:
                    board.BuildConnectivity()
                    blocked, via_no = obstacles(board, win, code, a.clearance,
                                                a.width / 2, a.via / 2)
                    via_ok = ~via_no
                    for li, r, c in starts + goals:
                        blocked[li][r, c] = False
                    path = search(win, blocked, via_ok, starts, goals, a.via_cost)
                    if path is not None:
                        print(f"  rip        {len(ripped)} plane-backed trace(s) "
                              f"near {name}")
                    else:
                        board = pcbnew.LoadBoard(str(work))
                        continue
            if path is None and name in PLANE_NETS:
                for li, r, c in starts:
                    path = to_plane(win, blocked[li], via_ok, (li, r, c))
                    if path:
                        mode = "plane"; break
            if path is None:
                continue

            # No head/tail override. Every start and goal cell lies inside
            # this net's own copper, so the path already begins and ends on it;
            # dragging an end back to the point the DRC report happened to name
            # detaches it from the island the search actually set out from.
            added = emit(board, win, path, code, a.width, a.via, a.drill)
            if mode == "plane":
                x, y = win.mm(path[-1][1], path[-1][2])
                v = pcbnew.PCB_VIA(board)
                v.SetPosition(pcbnew.VECTOR2I(int(x * NM), int(y * NM)))
                v.SetWidth(int(a.via * NM)); v.SetDrill(int(a.drill * NM))
                v.SetNetCode(code); v.SetViaType(pcbnew.VIATYPE_THROUGH)
                board.Add(v); added.append(v)

            if ripped:
                close_plane_orphans(board, routable, pro, code, a)
            pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
            trial = tempfile.mktemp(suffix=".kicad_pcb")
            if pro:
                shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
            pcbnew.SaveBoard(trial, board)
            v1, u1, d1 = drc(trial)
            # Crossing In3.Cu cuts the V3V3 pour, which can orphan a pad that
            # was reaching the plane through the part just severed. The total
            # then stays level -- one pair closed, one opened -- and a gate that
            # demands the count fall discards a route that worked. Accept a
            # level trade when the pair actually aimed at is gone, and let the
            # next pass close what the cut orphaned.
            still = any(re.search(r"\[([^\]]+)\]", i.get("description", "") or "")
                        and re.search(r"\[([^\]]+)\]",
                                      i.get("description", "")).group(1) == name
                        for e2 in d1.get("unconnected_items", [])
                        for i in e2.get("items", []))
            tries[name] = tries.get(name, 0) + 1
            if v1 <= v_now and (u1 < u_now or
                                (u1 == u_now and not still and tries[name] <= 3)):
                shutil.move(trial, str(work))
                segs = sum(1 for t in added if t.Type() == pcbnew.PCB_TRACE_T)
                vias = len(added) - segs
                print(f"  CLOSED     {name:9} {span:5.2f} mm  {mode:5}  "
                      f"{segs} seg + {vias} via  -> {v1} violation(s), "
                      f"{u1} unconnected")
                progressed = True
                break
            os.unlink(trial)
            print(f"  rejected   {name:9} {span:5.2f} mm  {mode:5}  "
                  f"({v1} violation(s), {u1} unconnected)")
            board = pcbnew.LoadBoard(str(work))
        if not progressed:
            break

    vf, uf, _ = drc(str(work))
    print(f"\n  result     {v0} -> {vf} violation(s), {u0} -> {uf} unconnected")
    print(f"  wrote      {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
