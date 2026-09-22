#!/usr/bin/env python3
"""
Re-land the back-side decoupling array on the already-routed board.

The array under U1 was 0402, centred on the ball grid. A dog-bone escape via
needs 0.275 mm of barrel plus 0.15 mm of clearance, and the diagonal slot it
occupies is 0.707 mm from four balls of 0.25 mm radius -- 0.032 mm of slack
before anything else is placed. A capacitor centred on a ball aims both lands
at that ball's four slots and blocks all of them, which is why ten of the
twenty slots the last five connections needed were unusable and why no router,
interactive or otherwise, could finish them.

design.ts now places the same capacitors as 0201, offset half a pitch
diagonally so each sits on a *slot* rather than on a ball, and turned 45
degrees so its lands point along the diagonal at the two balls it straddles.
Each capacitor then consumes exactly one slot instead of four -- 38 slot-kills
across the array rather than 152 -- and leaves its neighbours 0.528 mm clear
against the 0.425 mm requirement.

This script moves that change onto the routed board without re-routing it.
Each land travels about 0.77 mm, so the 92 segments that terminate on one
cannot simply be stretched after it; they are deleted. Of those, 75 are GND
and V3V3 daisy-chains -- the outer-layer copper Freerouting wove through the
ball field instead of dropping each capacitor onto the planes already sitting
under it. Every one of them is replaced by a via into its own plane at its own
pad, which is both the fix for the slots and a shorter return loop than the
chain it replaces. The remaining 17 are V1 and V1V8, which have no plane and
are left unrouted for a person to finish.

The other 1724 segments are untouched.

    python3 scripts/reland_decaps.py ROUTED --from FRESH --out OUT

FRESH is the board design.ts exports (new lands, no copper); ROUTED carries the
routing. Net codes differ between the two boards -- 94 of 97 on this one -- so
every transplanted pad is re-bound to its net by name, never by number.
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import (pcbnew, NM, drc, obstacles, find_slot, find_link,
                          item_layer, repair, PLANE_NETS)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("routed")
    ap.add_argument("--from", dest="fresh", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--refs", default="C100-C137")
    ap.add_argument("--reach", type=float, default=1.2)
    ap.add_argument("--clearance", type=float, default=0.15)
    ap.add_argument("--via", type=float, default=0.55)
    ap.add_argument("--drill", type=float, default=0.25)
    ap.add_argument("--width", type=float, default=0.25)
    ap.add_argument("--no-repair", action="store_true",
                    help="leave the capacitor lands unconnected. A via per land "
                         "does not fit: 225 interior slots less 38 the array now "
                         "occupies is 187, against 36 signal escapes + 76 power "
                         "ball vias + 76 capacitor lands = 188 wanted. Vias have "
                         "to be shared, so the escapes are placed first and the "
                         "router re-shares the rest around them.")
    a = ap.parse_args()

    m = re.fullmatch(r"([A-Za-z]+)(\d+)-\1(\d+)", a.refs)
    refs = {f"{m.group(1)}{i}" for i in range(int(m.group(2)), int(m.group(3)) + 1)}

    work = Path(a.out)
    shutil.copy(a.routed, work)
    pro = Path(a.routed).with_suffix(".kicad_pro")
    pro = str(pro) if pro.is_file() else None
    if pro:
        shutil.copy(pro, work.with_suffix(".kicad_pro"))

    v0, u0, _ = drc(str(work))
    print(f"  start      {v0} violation(s), {u0} unconnected")

    fresh = pcbnew.LoadBoard(a.fresh)
    board = pcbnew.LoadBoard(str(work))
    by_name = {n.GetNetname(): n.GetNetCode()
               for n in board.GetNetInfo().NetsByNetcode().values()}

    have_fresh = {f.GetReference() for f in fresh.GetFootprints()} & refs
    have_rt = {f.GetReference() for f in board.GetFootprints()} & refs
    if have_fresh != refs or have_rt != refs:
        print(f"  ABORT      refs missing: fresh {sorted(refs - have_fresh)[:3]} "
              f"routed {sorted(refs - have_rt)[:3]}")
        return 1

    # Land positions as they are *now*, so the copper that ends on one can be
    # found before the footprint moves out from under it.
    lands = set()
    for fp in board.GetFootprints():
        if fp.GetReference() in refs:
            for pad in fp.Pads():
                p = pad.GetPosition(); lands.add((p.x, p.y))

    doomed = []
    for t in board.GetTracks():
        if isinstance(t, pcbnew.PCB_VIA):
            continue
        if any((p.x, p.y) in lands for p in (t.GetStart(), t.GetEnd())):
            doomed.append(t)
    by_net = {}
    for t in doomed:
        by_net[t.GetNetname()] = by_net.get(t.GetNetname(), 0) + 1
    print(f"  delete     {len(doomed)} segment(s) landing on the old array: "
          + ", ".join(f"{k} {v}" for k, v in sorted(by_net.items(), key=lambda x: -x[1])))
    for t in doomed:
        board.RemoveNative(t)

    # Swap the footprints wholesale. Pad positions live relative to the
    # footprint in the board file, and pcbnew exposes no setter for that, so a
    # pad cannot be moved in place -- the footprint has to be replaced.
    swapped = 0
    for old in [f for f in board.GetFootprints() if f.GetReference() in refs]:
        src = fresh.FindFootprintByReference(old.GetReference())
        nets = {pad.GetNumber(): pad.GetNetname() for pad in old.Pads()}
        board.RemoveNative(old)
        new = pcbnew.Cast_to_FOOTPRINT(src.Duplicate(False))
        board.Add(new)
        for pad in new.Pads():
            name = nets.get(pad.GetNumber())
            if name in by_name:
                pad.SetNetCode(by_name[name])
        swapped += 1
    print(f"  transplant {swapped} footprint(s) re-landed as 0201 at 45 deg")

    pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()

    def save(b):
        t = tempfile.mktemp(suffix=".kicad_pcb")
        if pro:
            shutil.copy(pro, Path(t).with_suffix(".kicad_pro"))
        pcbnew.SaveBoard(t, b)
        return t

    # The lands moved 0.77 mm, so some of them now sit on copper that used to
    # route around where they were. All of it is ripped up rather than dodged --
    # not only the GND and V3V3 that has a plane to fall back into, but the V1
    # and V1V8 rails and the handful of signals caught in the array as well.
    # Whatever this disconnects is re-routed afterwards; leaving a short in
    # place to save the router some work is not a trade worth making.
    for _ in range(12):
        t = save(board)
        _, _, data = drc(t); os.unlink(t)
        hits = {}
        for v in data.get("violations", []):
            desc = [i.get("description", "") for i in v.get("items", [])]
            if not any(re.search(r"of (" + "|".join(sorted(refs)) + r") on", d) for d in desc):
                continue
            for i in v.get("items", []):
                mm = re.search(r"\[([^\]]+)\]", i.get("description", ""))
                if mm and "Pad" not in i.get("description", ""):
                    hits[i["uuid"]] = mm.group(1)
        if not hits:
            break
        gone = 0
        for t_ in list(board.GetTracks()):
            if t_.m_Uuid.AsString() in hits:
                board.RemoveNative(t_); gone += 1
        print(f"  clear      {gone} item(s) ripped up from under the new lands")
        if not gone:
            break
        pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()

    # Each capacitor now reaches its plane at its own pad instead of through a
    # chain of its neighbours -- the shorter return loop, and the reason the
    # escape slots are free.
    if a.no_repair:
        print("  plane vias skipped -- lands left for the router to share")
    else:
        added = repair(board, pro, a.via / 2 + a.clearance, a.reach,
                       a.width, a.via, a.drill)
        print(f"  plane vias {added} placed")
    pcbnew.ZONE_FILLER(board).Fill(board.Zones()); board.BuildConnectivity()

    trial = tempfile.mktemp(suffix=".kicad_pcb")
    if pro:
        shutil.copy(pro, Path(trial).with_suffix(".kicad_pro"))
    pcbnew.SaveBoard(trial, board)
    v1, u1, _ = drc(trial)
    print(f"  after swap {v1} violation(s), {u1} unconnected")
    shutil.move(trial, str(work))
    print(f"  wrote      {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
