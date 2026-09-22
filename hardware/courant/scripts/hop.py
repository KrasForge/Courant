#!/usr/bin/env python3
"""
Close short unconnected pairs by placing the copper directly.

What the router leaves behind on this board is mostly not routing: thirteen of
the fourteen remaining pairs are under 2.6 mm apart, and several under 1 mm.
They are two ends of the same net that need a wire between them, and a
topological router that has already decided it cannot place one will keep
deciding that. Placing it geometrically is both more direct and checkable.

For each pair this tries, in order of preference:

  * a straight segment on a layer both endpoints can reach;
  * an L, cornering at either right angle;
  * a mitred L, turning through 45 degrees, which fits where a square corner
    does not because the diagonal keeps clear of pads on both sides.

Each candidate is sampled along its length against every piece of foreign
copper on that layer, and through vias on all of them. The first that is clear
is placed, the board is re-checked with KiCad's DRC, and it is kept only if the
unconnected count fell and the violation count did not rise. Anything else is
rolled back, so a failure costs nothing but time.

    python3 scripts/hop.py BOARD --out OUT [--max-span MM]
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, json, math, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import (pcbnew, NM, drc, obstacles, obstacles_on,
                          clear_at, path_clear, find_slot)


def layers_of(board, uuid):
    """Copper layers an item occupies; a through via reaches all of them."""
    for t in board.GetTracks():
        if t.m_Uuid.AsString() == uuid:
            if isinstance(t, pcbnew.PCB_VIA):
                return [l for l in board.GetEnabledLayers().CuStack()]
            return [t.GetLayer()]
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.m_Uuid.AsString() == uuid:
                return [l for l in board.GetEnabledLayers().CuStack()
                        if pad.IsOnLayer(l)]
    return []


def candidates(ax, ay, bx, by):
    """Straight, then square corners, then 45 degree mitres."""
    yield [(ax, ay), (bx, by)]
    yield [(ax, ay), (bx, ay), (bx, by)]
    yield [(ax, ay), (ax, by), (bx, by)]
    dx, dy = bx - ax, by - ay
    if abs(dx) > 1e-9 and abs(dy) > 1e-9:
        m = min(abs(dx), abs(dy))
        sx, sy = math.copysign(m, dx), math.copysign(m, dy)
        yield [(ax, ay), (ax + sx, ay + sy), (bx, by)]
        yield [(ax, ay), (bx - sx, by - sy), (bx, by)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--max-span", type=float, default=4.0,
                    help="skip pairs further apart than this; they are routing, "
                         "not a hop")
    ap.add_argument("--clearance", type=float, default=0.15)
    ap.add_argument("--width", type=float, default=0.2)
    a = ap.parse_args()

    work = Path(a.out)
    shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    pro = str(pro) if pro.is_file() else None
    if pro:
        shutil.copy(pro, work.with_suffix(".kicad_pro"))

    v0, u0, _ = drc(str(work))
    print(f"  start      {v0} violation(s), {u0} unconnected pair(s)\n")
    need = a.width / 2 + a.clearance
    placed = skipped = rejected = 0

    while True:
        v_now, u_now, data = drc(str(work))
        board = pcbnew.LoadBoard(str(work))
        progressed = False
        for e in data.get("unconnected_items", []):
            its = e.get("items", [])
            if len(its) != 2:
                continue
            (ax, ay), (bx, by) = ((i["pos"]["x"], i["pos"]["y"]) for i in its)
            span = math.dist((ax, ay), (bx, by))
            if span > a.max_span:
                continue
            m = re.search(r"\[([^\]]+)\]", its[0].get("description", ""))
            name = m.group(1) if m else "?"
            la = set(layers_of(board, its[0]["uuid"]))
            lb = set(layers_of(board, its[1]["uuid"]))
            shared = [l for l in board.GetEnabledLayers().CuStack() if l in la & lb]
            code = board.GetNetsByName()[name].GetNetCode() if name in \
                board.GetNetsByName() else None
            if code is None:
                continue

            done = False
            # Endpoints on different layers need a via in the hop; most of what
            # survives the router is this shape, because the capacitor is on the
            # back and the rail it must reach runs on the front.
            if not shared:
                vneed = 0.55 / 2 + a.clearance
                discs, segs = obstacles(board, code)
                # Search for somewhere the via can actually go, nearest the
                # midpoint first. Under the ball field the obvious three points
                # -- both endpoints and the midpoint -- are all occupied, and
                # trying only those finds nothing at all.
                mx, my = (ax + bx) / 2, (ay + by) / 2
                spots = []
                for i in range(-50, 51):
                    for jj in range(-50, 51):
                        px, py = mx + i * 0.05, my + jj * 0.05
                        d = math.hypot(px - mx, py - my)
                        if d > 2.5:
                            continue
                        if clear_at(discs, segs, px, py, vneed):
                            spots.append((d, px, py))
                spots.sort()
                for _, vx, vy in spots[:80]:
                    # A leg may dogleg as well. Straight-only legs fail on
                    # pairs where the via slot is reachable but not in a
                    # straight line from the pad -- which is most of them once
                    # the easy ones are gone.
                    legs = []
                    for (px, py), ls in (((ax, ay), la), ((bx, by), lb)):
                        if math.dist((px, py), (vx, vy)) < 1e-3:
                            continue
                        leg = None
                        for l in board.GetEnabledLayers().CuStack():
                            if l not in ls:
                                continue
                            d2, s2 = obstacles_on(board, code, l)
                            for route in candidates(px, py, vx, vy):
                                if all(path_clear(d2, s2, q[0], q[1], r[0], r[1], need)
                                       for q, r in zip(route, route[1:])):
                                    leg = (route, l); break
                            if leg:
                                break
                        if leg is None:
                            legs = None; break
                        legs.append(leg)
                    if legs is None:
                        continue
                    v = pcbnew.PCB_VIA(board)
                    v.SetPosition(pcbnew.VECTOR2I(int(vx * NM), int(vy * NM)))
                    v.SetWidth(int(0.55 * NM)); v.SetDrill(int(0.25 * NM))
                    v.SetNetCode(code); v.SetViaType(pcbnew.VIATYPE_THROUGH)
                    board.Add(v)
                    added = [v]
                    for route, l in legs:
                        for q, r in zip(route, route[1:]):
                            t = pcbnew.PCB_TRACK(board)
                            t.SetStart(pcbnew.VECTOR2I(int(q[0] * NM), int(q[1] * NM)))
                            t.SetEnd(pcbnew.VECTOR2I(int(r[0] * NM), int(r[1] * NM)))
                            t.SetWidth(int(a.width * NM)); t.SetLayer(l)
                            t.SetNetCode(code); board.Add(t); added.append(t)
                    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
                    board.BuildConnectivity()
                    trial = tempfile.mktemp(suffix=".kicad_pcb")
                    if pro:
                        shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
                    pcbnew.SaveBoard(trial, board)
                    v1, u1, _ = drc(trial)
                    if v1 <= v_now and u1 < u_now:
                        shutil.move(trial, str(work))
                        print(f"  HOP        {name:9} {span:5.2f} mm via at "
                              f"({vx:.2f}, {vy:.2f})  -> {v1} violation(s), "
                              f"{u1} unconnected")
                        placed += 1; done = progressed = True
                        break
                    os.unlink(trial)
                    for t in added:
                        board.RemoveNative(t)
                    board.BuildConnectivity()
                    rejected += 1
                if done:
                    break
                continue
            for layer in shared:
                discs, segs = obstacles_on(board, code, layer)
                for path in candidates(ax, ay, bx, by):
                    if not all(path_clear(discs, segs, p[0], p[1], q[0], q[1], need)
                               for p, q in zip(path, path[1:])):
                        continue
                    added = []
                    for p, q in zip(path, path[1:]):
                        t = pcbnew.PCB_TRACK(board)
                        t.SetStart(pcbnew.VECTOR2I(int(p[0] * NM), int(p[1] * NM)))
                        t.SetEnd(pcbnew.VECTOR2I(int(q[0] * NM), int(q[1] * NM)))
                        t.SetWidth(int(a.width * NM)); t.SetLayer(layer)
                        t.SetNetCode(code); board.Add(t); added.append(t)
                    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
                    board.BuildConnectivity()
                    trial = tempfile.mktemp(suffix=".kicad_pcb")
                    if pro:
                        shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
                    pcbnew.SaveBoard(trial, board)
                    v1, u1, _ = drc(trial)
                    if v1 <= v_now and u1 < u_now:
                        shutil.move(trial, str(work))
                        print(f"  HOP        {name:9} {span:5.2f} mm on "
                              f"{board.GetLayerName(layer):6} "
                              f"({len(path) - 1} seg)  -> {v1} violation(s), "
                              f"{u1} unconnected")
                        placed += 1; done = progressed = True
                        break
                    os.unlink(trial)
                    for t in added:
                        board.RemoveNative(t)
                    board.BuildConnectivity()
                    rejected += 1
                if done:
                    break
            if done:
                break
        if not progressed:
            break

    vf, uf, data = drc(str(work))
    left = [e for e in data.get("unconnected_items", [])]
    print(f"\n  placed     {placed} hop(s), {rejected} candidate(s) rejected by DRC")
    print(f"  result     {v0} -> {vf} violation(s), {u0} -> {uf} unconnected")
    print(f"  wrote      {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
