#!/usr/bin/env python3
"""
Open a BGA escape slot by returning plane-backed copper to its plane.

The five connections this board could not finish are not blocked by signal
traffic that a shove router would move aside. They are blocked by power routed
as *traces* across F.Cu and B.Cu inside U1's ball field -- 356 mm of it, of
which 262 mm is GND or V3V3 and therefore has a plane it could have used
instead. Freerouting daisy-chained the back-side decoupling capacitors along
the outer layers rather than dropping each one onto In1/In4 (GND) or In3
(V3V3), and those chains run straight through the diagonal slots the remaining
balls need for their dog-bone vias.

So: delete the plane-backed copper that occupies a slot, give whatever it
orphaned its own via into the plane, and the slot opens. This is strictly
better decoupling as well -- a cap that reaches its plane through a via at its
own pad has a shorter return loop than one chained to three neighbours.

Nothing here is accepted on faith. Every step writes a trial board, runs
KiCad's DRC over it, and keeps the result only if the unconnected count falls
and the violation count does not rise.

    python3 scripts/plane_escape.py BOARD --out OUT [--net NET ...]
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, json, math, os, re, shutil, subprocess, tempfile
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

# Nets that have a plane to fall back into, and may therefore have their
# outer-layer copper deleted: the via that replaces it reaches the same net.
PLANE_NETS = {"GND", "V3V3"}


def drc(path):
    o = tempfile.mktemp(suffix=".json")
    subprocess.run(["kicad-cli", "pcb", "drc", "--output", o, "--format", "json",
                    "--units", "mm", "--severity-error", "--refill-zones", path],
                   capture_output=True, text=True)
    j = json.load(open(o)); os.unlink(o)
    return len(j.get("violations", [])), len(j.get("unconnected_items", [])), j


def seg_dist(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / L))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def obstacles(board, netcode):
    """Foreign copper, as discs and segments, keyed by nothing: a through via
    crosses every layer, so a via slot must be clear on all of them at once."""
    discs, segs = [], []
    for t in board.GetTracks():
        if t.GetNetCode() == netcode:
            continue
        if isinstance(t, pcbnew.PCB_VIA):
            p = t.GetPosition()
            discs.append((p.x / NM, p.y / NM, t.GetWidth(pcbnew.F_Cu) / 2 / NM))
        else:
            s, e = t.GetStart(), t.GetEnd()
            segs.append((s.x / NM, s.y / NM, e.x / NM, e.y / NM, t.GetWidth() / 2 / NM))
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() == netcode:
                continue
            p, sz = pad.GetPosition(), pad.GetSize()
            discs.append((p.x / NM, p.y / NM, max(sz.x, sz.y) / 2 / NM))
    return discs, segs


def obstacles_on(board, netcode, layer):
    """Foreign copper a *trace* on LAYER must avoid. Unlike a via this is a
    single-layer question, except for through vias, which are on every layer."""
    discs, segs = [], []
    for t in board.GetTracks():
        if t.GetNetCode() == netcode:
            continue
        if isinstance(t, pcbnew.PCB_VIA):
            p = t.GetPosition()
            discs.append((p.x / NM, p.y / NM, t.GetWidth(pcbnew.F_Cu) / 2 / NM))
        elif t.GetLayer() == layer:
            a, b = t.GetStart(), t.GetEnd()
            segs.append((a.x / NM, a.y / NM, b.x / NM, b.y / NM, t.GetWidth() / 2 / NM))
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() == netcode or not pad.IsOnLayer(layer):
                continue
            p, sz = pad.GetPosition(), pad.GetSize()
            discs.append((p.x / NM, p.y / NM, max(sz.x, sz.y) / 2 / NM))
    return discs, segs


def same_net_points(board, netcode, layer):
    """Where a trace on LAYER could join this net without a via."""
    out = []
    for t in board.GetTracks():
        if t.GetNetCode() != netcode:
            continue
        if isinstance(t, pcbnew.PCB_VIA):
            p = t.GetPosition(); out.append((p.x / NM, p.y / NM))
        elif t.GetLayer() == layer:
            for p in (t.GetStart(), t.GetEnd()):
                out.append((p.x / NM, p.y / NM))
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() == netcode and pad.IsOnLayer(layer):
                p = pad.GetPosition(); out.append((p.x / NM, p.y / NM))
    return out


def path_clear(discs, segs, ax, ay, bx, by, need, reserved=(), step=0.05):
    n = max(1, int(math.hypot(bx - ax, by - ay) / step))
    for i in range(n + 1):
        t = i / n
        if not clear_at(discs, segs, ax + t * (bx - ax), ay + t * (by - ay),
                        need, reserved):
            return False
    return True


def find_link(board, netcode, ax, ay, layer, need, reach, reserved=()):
    """Nearest point of this net that a clear straight trace can reach on LAYER.

    A ball whose only via slot has been given to a neighbour does not have to
    have a via of its own -- it only has to reach copper that already does.
    """
    discs, segs = obstacles_on(board, netcode, layer)
    best = None
    for bx, by in same_net_points(board, netcode, layer):
        d = math.hypot(bx - ax, by - ay)
        if d < 1e-3 or d > reach or (best and d >= best[0]):
            continue
        if path_clear(discs, segs, ax, ay, bx, by, need, reserved):
            best = (d, bx, by)
    return best


def clear_at(discs, segs, px, py, need, reserved=()):
    # A slot being freed for an escape must not be handed straight back to the
    # net whose copper was just removed from it -- which is exactly what the
    # nearest-clear-point search does if nothing forbids it.
    for x, y, r in reserved:
        if math.hypot(px - x, py - y) < r:
            return False
    for x, y, r in discs:
        if math.hypot(px - x, py - y) < r + need:
            return False
    for x1, y1, x2, y2, r in segs:
        if seg_dist(px, py, x1, y1, x2, y2) < r + need:
            return False
    return True


def find_slot(discs, segs, ax, ay, need, reach, reserved=(), step=0.05):
    """Nearest point to (ax, ay) that a through via can occupy."""
    best = None
    n = int(reach / step)
    for i in range(-n, n + 1):
        for j in range(-n, n + 1):
            px, py = ax + i * step, ay + j * step
            d = math.hypot(px - ax, py - ay)
            if d > reach or (best and d >= best[0]):
                continue
            if clear_at(discs, segs, px, py, need, reserved):
                best = (d, px, py)
    return best


def blockers_at(board, netcode, sx, sy, need, rip_any=False):
    """Copper that stops a via at (sx, sy), split by whether it can be deleted.

    With rip_any, any track or via may go and be re-routed afterwards; a pad
    never can, because moving a component is not the router's to do.
    """
    plane, fixed = [], []
    for t in board.GetTracks():
        if t.GetNetCode() == netcode:
            continue
        if isinstance(t, pcbnew.PCB_VIA):
            p = t.GetPosition()
            d = math.hypot(p.x / NM - sx, p.y / NM - sy) - t.GetWidth(pcbnew.F_Cu) / 2 / NM
        else:
            s, e = t.GetStart(), t.GetEnd()
            d = seg_dist(sx, sy, s.x / NM, s.y / NM, e.x / NM, e.y / NM) - t.GetWidth() / 2 / NM
        if d >= need:
            continue
        (plane if (rip_any or t.GetNetname() in PLANE_NETS) else fixed).append(t)
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetCode() == netcode:
                continue
            p, sz = pad.GetPosition(), pad.GetSize()
            if math.hypot(p.x / NM - sx, p.y / NM - sy) < max(sz.x, sz.y) / 2 / NM + need:
                fixed.append(pad)          # a pad is never ours to delete
    return plane, fixed


def item_layer(board, uuid, fallback):
    """The copper layer an item lives on -- a stub must not be drawn anywhere else."""
    for t in board.GetTracks():
        if t.m_Uuid.AsString() == uuid:
            return fallback if isinstance(t, pcbnew.PCB_VIA) else t.GetLayer()
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.m_Uuid.AsString() == uuid:
                return pcbnew.B_Cu if pad.IsOnLayer(pcbnew.B_Cu) else pcbnew.F_Cu
    return fallback


def repair(board, pro, need, reach, width, via, drill, reserved=(),
           prefer="via", verbose=True):
    """Give every plane-net item the deletion orphaned its own via into the plane.

    A through via on GND lands on In1 and In4; on V3V3 it lands on In3. Both
    pours cover the whole board, so the via alone restores the connection and
    the search only has to reach from the orphan, not between two endpoints.
    """
    added, done = 0, set()
    baseline, last = None, None
    while True:
        trial = tempfile.mktemp(suffix=".kicad_pcb")
        if pro: shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
        pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
        pcbnew.SaveBoard(trial, board)
        v_now, _, data = drc(trial)
        os.unlink(trial)

        # Undo one placement at a time rather than judging the batch at the
        # end: a single link that breaks a clearance would otherwise discard
        # every good one made alongside it.
        if baseline is None:
            baseline = v_now
        elif v_now > baseline and last is not None:
            key, items = last
            for it in items:
                board.RemoveNative(it)
            board.BuildConnectivity()
            if verbose:
                print(f"      undo  {key[0]} at ({key[1]}, {key[2]}): "
                      f"+{v_now - baseline} violation(s)")
            added -= 1; last = None
            continue
        last = None
        # KiCad's DRC JSON leaves "net" null on unconnected items and puts the
        # net name in the description instead: 'Track [GND] on B.Cu, ...'.
        todo = []
        for e in data.get("unconnected_items", []):
            for it in e.get("items", []):
                m = re.search(r"\[([^\]]+)\]", it.get("description", ""))
                if m and m.group(1) in PLANE_NETS:
                    todo.append((m.group(1), it))
        if not todo:
            return added
        placed = False
        for name, it in todo:
            key = (name, round(it["pos"]["x"], 3), round(it["pos"]["y"], 3))
            if key in done:
                continue
            ax, ay = it["pos"]["x"], it["pos"]["y"]
            code = board.GetNetsByName()[name].GetNetCode()
            layer = item_layer(board, it["uuid"], pcbnew.B_Cu)
            discs, segs = obstacles(board, code)
            slot = find_slot(discs, segs, ax, ay, need, reach, reserved)
            link = find_link(board, code, ax, ay, layer,
                             width / 2 + (need - via / 2), reach, reserved)
            # A via is the shorter return path and the better connection, but
            # vias are the scarce resource here: 225 interior slots less the 38
            # the capacitor array occupies is 187, against 36 signal escapes,
            # 76 power ball vias and 76 capacitor lands -- 188 wanted. Spending
            # one per land does not fit and strands the lands that come last.
            # With prefer="link" a land joins its neighbour's copper instead and
            # the group shares a via, which is what the original routing did.
            if prefer == "link" and link is not None:
                slot = None
            if slot is None and link is None:
                if verbose:
                    print(f"      {name:5} orphan at ({ax:.3f}, {ay:.3f}) on "
                          f"{board.GetLayerName(layer)}: no slot, no link")
                continue
            done.add(key)
            placed_items = []
            if slot is not None:
                _, vx, vy = slot
                v = pcbnew.PCB_VIA(board)
                v.SetPosition(pcbnew.VECTOR2I(int(vx * NM), int(vy * NM)))
                v.SetWidth(int(via * NM)); v.SetDrill(int(drill * NM))
                v.SetNetCode(code); v.SetViaType(pcbnew.VIATYPE_THROUGH)
                board.Add(v); placed_items.append(v)
                how = f"via ({vx:.3f}, {vy:.3f})"
            else:
                _, vx, vy = link
                how = f"link ({vx:.3f}, {vy:.3f})"
            if math.hypot(vx - ax, vy - ay) > 1e-3:
                t = pcbnew.PCB_TRACK(board)
                t.SetStart(pcbnew.VECTOR2I(int(ax * NM), int(ay * NM)))
                t.SetEnd(pcbnew.VECTOR2I(int(vx * NM), int(vy * NM)))
                t.SetWidth(int(width * NM)); t.SetLayer(layer)
                t.SetNetCode(code); board.Add(t); placed_items.append(t)
            last = (key, placed_items)
            if verbose:
                print(f"      {name:5} orphan at ({ax:.3f}, {ay:.3f}) -> {how}"
                      f" on {board.GetLayerName(layer)}")
            added += 1; placed = True
            break
        if not placed:
            return added


def escape(board, pro, net, need, reach, width, via, drill,
           rip_any=False, do_repair=True):
    """Free the best diagonal slot beside NET's ball and put its dog-bone in."""
    u1 = board.FindFootprintByReference("U1")
    pad = next((p for p in u1.Pads() if p.GetNetname() == net), None)
    if pad is None:
        print(f"  {net:14} no such ball on U1"); return None
    c = pad.GetPosition(); bx, by = c.x / NM, c.y / NM
    code = pad.GetNetCode()

    # Only the four adjacent diagonal slots are reachable: a clear slot further
    # out is useless because the straight line to it crosses another ball.
    cands = []
    for dx in (-1, 1):
        for dy in (-1, 1):
            sx, sy = bx + dx * 0.5, by + dy * 0.5
            plane, fixed = blockers_at(board, code, sx, sy, need, rip_any)
            cands.append((len(fixed), len(plane), sx, sy, plane))
    cands.sort()
    nfixed, nplane, sx, sy, plane = cands[0]
    if nfixed:
        print(f"  {net:14} best slot ({sx:.1f}, {sy:.1f}) still has {nfixed} "
              f"immovable blocker(s) -- skipping")
        return None

    gone = ", ".join(sorted({t.GetNetname() for t in plane})) or "nothing"
    print(f"  {net:14} slot ({sx:.1f}, {sy:.1f}): ripping {nplane} item(s) [{gone}]")
    for t in plane:
        board.RemoveNative(t)
    if do_repair:
        repair(board, pro, need, reach, width, via, drill,
               reserved=[(sx, sy, via / 2 + need)])

    v = pcbnew.PCB_VIA(board)
    v.SetPosition(pcbnew.VECTOR2I(int(sx * NM), int(sy * NM)))
    v.SetWidth(int(via * NM)); v.SetDrill(int(drill * NM))
    v.SetNetCode(code); v.SetViaType(pcbnew.VIATYPE_THROUGH); board.Add(v)
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(c); t.SetEnd(pcbnew.VECTOR2I(int(sx * NM), int(sy * NM)))
    t.SetWidth(int(width * NM)); t.SetLayer(pcbnew.F_Cu)
    t.SetNetCode(code); board.Add(t)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()
    return (sx, sy)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--net", action="append", required=True)
    ap.add_argument("--reach", type=float, default=1.5)
    ap.add_argument("--clearance", type=float, default=0.15)
    ap.add_argument("--via", type=float, default=0.55)
    ap.add_argument("--drill", type=float, default=0.25)
    ap.add_argument("--width", type=float, default=0.2)
    ap.add_argument("--rip-any", action="store_true",
                    help="rip any track or via out of the slot, not only nets "
                         "with a plane to fall back into")
    ap.add_argument("--no-repair", action="store_true",
                    help="do not re-connect what was ripped; leave it to the router")
    a = ap.parse_args()

    work = Path(a.out)
    shutil.copy(a.board, work)
    pro = Path(a.board).with_suffix(".kicad_pro")
    pro = str(pro) if pro.is_file() else None
    if pro: shutil.copy(pro, work.with_suffix(".kicad_pro"))

    need = a.via / 2 + a.clearance
    v0, u0, _ = drc(str(work))
    print(f"  start          {v0} violation(s), {u0} unconnected\n")

    kept = []
    for net in a.net:
        board = pcbnew.LoadBoard(str(work))
        if escape(board, pro, net, need, a.reach, a.width, a.via, a.drill,
                  a.rip_any, not a.no_repair) is None:
            continue
        trial = tempfile.mktemp(suffix=".kicad_pcb")
        if pro: shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
        pcbnew.SaveBoard(trial, board)
        v1, u1, _ = drc(trial)
        vn, un, _ = drc(str(work))
        if v1 <= vn and (u1 <= un or a.no_repair):
            shutil.move(trial, str(work))
            print(f"  {net:14} KEPT   -> {v1} violation(s), {u1} unconnected\n")
            kept.append(net)
        else:
            os.unlink(trial)
            print(f"  {net:14} REVERTED ({v1} violation(s), {u1} unconnected)\n")

    vf, uf, _ = drc(str(work))
    print(f"  result         {len(kept)} escaped: {', '.join(kept) or 'none'}")
    print(f"                 {v0} -> {vf} violation(s), {u0} -> {uf} unconnected")
    print(f"  wrote          {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
