#!/usr/bin/env python3
"""
Route the board.

tscircuit places the board and owns the netlist; it does not route it. This
script drives the handoff end to end and brings the copper back:

    dist/courant.kicad_pcb          (from `npm run export`)
      -> dist/courant.kicad_pro     design rules, from scripts/rules.json
      -> dist/courant.dsn           Specctra, written by KiCad
      -> dist/courant.ses           Specctra session, written by Freerouting
      -> dist/courant.routed.kicad_pcb

Why KiCad writes the DSN and not `tsci export -f specctra-dsn`: tscircuit's
converter places every component with `side: "front"` regardless of its layer,
which would move all 38 back-side BGA decoupling capacitors to the top of the
board, and it crashes outright on a pad whose `pcb_component_id` is null (the
three fiducials). KiCad's exporter gets both right, and it is the same file
Freerouting is actually tested against.

Requirements, none of which npm can install:

  * KiCad 9 or newer with the `pcbnew` Python module (`python3 -c "import pcbnew"`)
  * a JRE
  * freerouting.jar, from https://github.com/freerouting/freerouting/releases
    Point $FREEROUTING_JAR at it, or pass --jar, or drop it in hardware/courant/.

Usage:
    python3 scripts/route.py [--passes N] [--threads N] [--jar PATH]
    python3 scripts/route.py --import-only     # re-import an existing .ses
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DIST = ROOT / "dist"

BOARD = PROJECT = DSN = SES = ROUTED = FRCFG = None


def shown(p: Path) -> str:
    """Path for a message: repo-relative when it is in the repo, else absolute.

    --dist can point anywhere, and Path.relative_to raises rather than falling
    back when it does not.
    """
    return str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p)


def set_dist(d: Path) -> None:
    """Point the whole pipeline at a directory other than dist/.

    A re-route that starts from a board which already carries copper is an
    experiment, and an experiment must not be able to overwrite the routed
    board it was seeded from. --dist gives it somewhere else to write; the
    per-directory lock in check_not_already_running() then keeps two of them
    from colliding as well.
    """
    global DIST, BOARD, PROJECT, DSN, SES, ROUTED, FRCFG
    DIST = d
    BOARD = DIST / "courant.kicad_pcb"
    PROJECT = DIST / "courant.kicad_pro"
    DSN = DIST / "courant.dsn"
    SES = DIST / "courant.ses"
    ROUTED = DIST / "courant.routed.kicad_pcb"
    FRCFG = DIST / "freerouting"


set_dist(DIST)


def load_pcbnew():
    """Import KiCad's pcbnew module without its startup noise.

    Importing pcbnew outside the KiCad application prints a page of
    `assert "m_choices.GetCount() > 0" failed in PROPERTY_ENUM()` to stderr
    while it registers property enums it has no UI for. It is harmless and
    there is no flag for it, so file descriptor 2 is closed over the import
    only -- anything these scripts actually report still reaches the terminal.
    """
    import importlib
    import os as _os
    saved = _os.dup(2)
    devnull = _os.open(_os.devnull, _os.O_WRONLY)
    try:
        _os.dup2(devnull, 2)
        return importlib.import_module("pcbnew")
    finally:
        _os.dup2(saved, 2)
        _os.close(saved)
        _os.close(devnull)


def die(msg: str) -> None:
    print(f"route: {msg}", file=sys.stderr)
    raise SystemExit(1)


def find_jar(explicit: str | None) -> Path:
    for candidate in (explicit, os.environ.get("FREEROUTING_JAR"),
                      ROOT / "freerouting.jar", DIST / "freerouting.jar"):
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    die("freerouting.jar not found. Download it from\n"
        "  https://github.com/freerouting/freerouting/releases\n"
        "and set $FREEROUTING_JAR, or pass --jar PATH.")


def write_project() -> None:
    """Write the KiCad project file that carries the board's design rules.

    KiCad reads design rules from the project, not the board, so the rules have
    to sit next to the .kicad_pcb under the same basename for the DSN export,
    the DRC and the Gerber export to agree with each other.
    """
    rules = json.loads((HERE / "rules.json").read_text())
    rules.pop("_comment", None)
    PROJECT.write_text(json.dumps(rules, indent=2))


def protect_existing_wiring(dsn: Path, ripup_box=None, keep=()) -> tuple[int, int]:
    """Decide, per wire and via, whether the router may rip it up.

    KiCad writes pre-existing copper into the DSN's wiring section as
    `(type route)`, which tells Freerouting it is looking at its own previous
    output and may do as it likes with it. `protect` maps to SYSTEM_FIXED and
    takes that permission away.

    Protecting everything is the safe default and, on a board seeded with a
    previous route, it is also a way to lose. A router that may not rip up is a
    router that cannot negotiate: on this board it closed 84 of 139 connections
    in the first pass and then sat at 48 unrouted and 23 violations for four
    passes, because the conflicts that remained could only be resolved by
    moving copper it had been forbidden to touch.

    So protection is selective. `ripup_box` is a region -- in DSN coordinates,
    which are micrometres with y negated -- inside which copper stays rippable;
    everything outside it is frozen. Pass U1's bounding box and the router may
    rework the ball field, where all the contention is, while the rest of the
    board and both ground planes stay exactly as they were.

    `keep` names points that stay protected wherever they are: the escape vias
    placed by hand in slots that took real work to open, and which the router
    would be free to delete and then fail to re-create.
    """
    text = dsn.read_text()
    head, sep, wiring = text.partition("(wiring")
    if not sep:
        return 0, 0

    def points(line):
        body = line.split("(path", 1)[1] if "(path" in line else line.split('"', 2)[-1]
        nums, out = re.findall(r"-?\d+(?:\.\d+)?", body.split("(net", 1)[0]), []
        if "(path" in line:
            nums = nums[1:]          # drop the width that follows the layer
        for i in range(0, len(nums) - 1, 2):
            out.append((float(nums[i]), float(nums[i + 1])))
        return out

    def inside(pts):
        if not ripup_box:
            return False
        x0, y0, x1, y1 = ripup_box
        return any(x0 <= x <= x1 and y0 <= y <= y1 for x, y in pts)

    def pinned(pts):
        return any(abs(x - kx) <= 50 and abs(y - ky) <= 50
                   for x, y in pts for kx, ky in keep)

    frozen = free = 0
    out = []
    for line in wiring.splitlines(keepends=True):
        if "(type route)" in line:
            pts = points(line)
            if inside(pts) and not pinned(pts):
                free += 1
            else:
                line = line.replace("(type route)", "(type protect)")
                frozen += 1
        out.append(line)
    dsn.write_text(head + sep + "".join(out))
    return frozen, free


# Nets whose pour is a return path, and therefore must not be cut by signals.
RETURN_NETS = {"GND", "AGND", "DGND"}


def restrict_signal_layers(dsn: Path, plane_layers: list[str],
                           ground_class: str = "Ground") -> int:
    """Keep signals off the ground planes without locking GND out of them.

    The obvious approach -- declaring the plane layers `(type power)` in the
    DSN -- is wrong, and wrong in a way that looks exactly like the board being
    too dense. A `power` layer is not "routable by GND only"; Freerouting takes
    it as unavailable for connections altogether, so the GND pins cannot reach
    their own plane either. Three routing runs left 55 to 60 connections
    unrouted that way, about fifty of them GND, and the planes being off limits
    was read as insufficient routing capacity. It was not: the board was never
    short of layers, GND was short of a way down.

    Specctra has the mechanism actually wanted. Every layer stays `signal`, so
    vias and plane connections work normally, and each net class except the
    ground class carries a `use_layer` clause naming only the non-plane layers.
    Signals are then confined to the signal layers by rule, while GND keeps the
    whole stackup and drops straight into its pours.
    """
    text = dsn.read_text()
    all_layers = re.findall(r"\(layer\s+(\S+)\s*\n\s*\(type\s+\w+\)", text)
    routable = [l for l in all_layers if l not in plane_layers]
    if not routable:
        return 0
    clause = "(use_layer " + " ".join(routable) + ")"

    def patch(m: re.Match) -> str:
        name, body = m.group(1), m.group(0)
        if name.startswith(ground_class) or "use_layer" in body:
            return body
        return body.replace("(circuit\n", "(circuit\n        " + clause + "\n", 1)

    text, n = re.subn(r"\(class\s+(\S+)[\s\S]*?\n    \)", patch, text), 0
    if isinstance(text, tuple):
        text, n = text
    dsn.write_text(text)
    return len(re.findall(re.escape(clause), text))


def plane_layers(board, pcbnew) -> list[str]:
    """Copper layers the router must not touch: the ground planes, and only those.

    The reason to forbid routing on a poured layer is to protect return
    current, and return current flows in the ground planes. A power pour is
    different: V3V3 is decoupled at two dozen points across this board, and a
    slot in it costs far less than a slot in GND, which every signal on an
    adjacent layer references.

    The specificity is worth having, because reserving too much is as damaging
    as reserving too little. Measured on this board: reserving nothing left 166
    signal segments cut through both ground planes but only 8 connections
    unrouted; reserving both ground planes gave clean planes and 56 unrouted;
    additionally reserving the V3V3 plane gave about 90. Four signal layers is
    what this board needs, so In3 carries the 3.3 V pour *and* signals, and the
    pour fills around them.
    """
    out = []
    for zone in board.Zones():
        if zone.GetNetname() not in RETURN_NETS:
            continue
        for layer in zone.GetLayerSet().CuStack():
            name = board.GetLayerName(layer)
            if name not in out:
                out.append(name)
    return out


def remove_degenerate_tracks(board, pcbnew, limit_mm: float = 0.01) -> int:
    """Delete segments too short to be geometry.

    A track a few microns long joins two points that are already coincident as
    far as any fabrication process is concerned, so removing it cannot
    disconnect anything -- whatever touched one end touches the other. It can,
    however, stop the router dead. Freerouting normalizes every protected wire
    into a polyline before it can treat it as an obstacle, and a zero-length
    segment sends that recursion to its depth limit; on this board 29 such
    segments (7 of them on V3V3) pinned the fanout stage in a loop that emitted
    nothing but `PolylineTrace.normalize: max normalization depth reached` for
    thirteen minutes and never reached the autorouter at all.

    They arrive from the router itself, and from importing a session whose
    wiring has been re-landed, so this runs on both sides of the round trip.
    """
    doomed = [t for t in board.GetTracks()
              if t.Type() == pcbnew.PCB_TRACE_T
              and t.GetLength() < limit_mm * 1_000_000]
    for t in doomed:
        board.RemoveNative(t)
    if doomed:
        board.BuildConnectivity()
    return len(doomed)


def weld_near_misses(board, pcbnew, tol_mm: float = 0.02) -> int:
    """Snap same-net track endpoints that nearly, but do not exactly, meet.

    KiCad decides connectivity geometrically: two 0.15 mm tracks whose
    endpoints miss each other by seven micrometres still overlap, so the net
    reads as connected and DRC says nothing. Freerouting decides it from the
    endpoints, so it sees a break, adds the connection to its worklist, and
    then fails to route it -- the gap is far too short to hold a trace.

    On this board that accounted for 192 phantom breaks, 173 of them on V1V8,
    and V1V8 was among the nets the router reported itself unable to finish.
    They come from the router's own floating-point output on the previous run,
    which is why they survived every DRC since.

    Snapping each cluster to its first member closes the gap. The largest move
    is the tolerance itself -- 20 um, an order of magnitude below anything a
    fabricator resolves.
    """
    tol = tol_mm * 1_000_000
    groups: dict = {}
    for t in board.GetTracks():
        if t.Type() != pcbnew.PCB_TRACE_T:
            continue
        groups.setdefault((t.GetNetCode(), t.GetLayer()), []).append(t)

    welded = 0
    for tracks in groups.values():
        anchors: list = []
        for t in tracks:
            for get, set_ in ((t.GetStart, t.SetStart), (t.GetEnd, t.SetEnd)):
                p = get()
                for a in anchors:
                    dx, dy = p.x - a.x, p.y - a.y
                    if dx * dx + dy * dy <= tol * tol:
                        if dx or dy:
                            set_(a); welded += 1
                        break
                else:
                    anchors.append(p)
    if welded:
        board.BuildConnectivity()
    return welded


def export_dsn(ripup_ref: str | None = None, keep_mm=()) -> None:
    pcbnew = load_pcbnew()
    board = pcbnew.LoadBoard(str(BOARD))
    shed = remove_degenerate_tracks(board, pcbnew)
    welded = weld_near_misses(board, pcbnew)
    if shed or welded:
        print(f"  clean    {shed} degenerate segment(s) dropped, "
              f"{welded} near-miss junction(s) welded before export")
        pcbnew.SaveBoard(str(BOARD), board)
        board = pcbnew.LoadBoard(str(BOARD))
    if not pcbnew.ExportSpecctraDSN(board, str(DSN)):
        die("KiCad failed to write the DSN")
    box = None
    if ripup_ref:
        fp = board.FindFootprintByReference(ripup_ref)
        if fp is None:
            die(f"--ripup {ripup_ref}: no such footprint")
        bb = fp.GetBoundingBox()
        # DSN coordinates are micrometres with y negated.
        box = (bb.GetLeft() / 1000, -bb.GetBottom() / 1000,
               bb.GetRight() / 1000, -bb.GetTop() / 1000)
    keep = [(x * 1000, -y * 1000) for x, y in keep_mm]
    frozen, free = protect_existing_wiring(DSN, box, keep)
    planes = plane_layers(board, pcbnew)
    marked = restrict_signal_layers(DSN, planes)
    print(f"  dsn      {DSN.name}  ({frozen} item(s) protected"
          + (f", {free} left rippable inside {ripup_ref}" if box else "")
          + (f", {len(keep)} escape via(s) pinned" if keep else "")
          + f", {marked} class(es) kept off the ground planes: {', '.join(planes)})")


def run_freerouting(jar: Path, passes: int, threads: int, gui: bool = False,
                    fanout: bool = True, optimize: bool = True) -> None:
    """Run the router headless.

    Freerouting's defaults are wrong for a batch run in three ways that cost
    real time: it opens a GUI and spends the run repainting it, its
    multi-threading feature flag is off, which holds the whole route to about
    one core, and its fanout stage has no budget of its own. All three live in
    a settings file rather than on the command line, so
    the settings file is written here and $FREEROUTING__USER_DATA_PATH points
    the tool at it. That also keeps this run out of the user's own
    ~/.config/freerouting, and turns off the telemetry that is on by default.
    """
    FRCFG.mkdir(parents=True, exist_ok=True)
    (FRCFG / "freerouting.json").write_text(json.dumps({
        # A profile id has to be present or the tool NPEs on startup.
        "profile": {"id": "00000000-0000-4000-8000-000000000000", "email": "",
                    "allow_telemetry": False, "allow_contact": False},
        # Headless by default. --gui puts the router's board window up so the
        # route can be watched; it costs real time, because the tool repaints
        # the whole board, conduction areas included, while it works.
        "gui": {"enabled": gui, "dialog_confirmation_timeout": 0},
        "router": {
            "enabled": True, "max_passes": passes, "job_timeout": "PT3H",
            "vias_allowed": True,
            # Fanout and the optimizer draw on the same job budget as the
            # autorouter, and fanout will happily spend all of it: on this board
            # it escapes 506 of 544 pins in the first three passes and then
            # grinds on the same ~33 it cannot place, at a minute or more a
            # pass. Capping it leaves the time for the stage that actually
            # routes nets.
            # Automatic neckdown lets the router thin a trace to squeeze past an
            # obstacle. It produced 0.1124 mm copper against a 0.15 mm minimum
            # and 70 DRC errors; the minimum is a fab limit, not a preference.
            "automatic_neckdown": False,
            "neck_width_um": 150,
            # --no-fanout turns this stage off entirely. Its budget is only
            # checked between passes, so a pass that fails to terminate ignores
            # it: on a board seeded with already-routed copper, fanout has been
            # seen to sit in a single pass indefinitely and never hand over to
            # the autorouter. When every surviving wire is protected and the
            # escapes are pre-placed, fanout is an optimisation rather than a
            # requirement -- the autorouter will place the vias it needs itself.
            "fanout": {"enabled": fanout, "max_passes": 6, "timeout": "PT12M"},
            # The optimizer cannot close a connection -- it shortens routes and
            # removes vias on what is already routed. That is worth having on
            # this board, where vias are the binding constraint, but it also
            # holds the session file hostage: Freerouting writes the .ses only
            # when the whole job ends, so a 45 minute optimizer is 45 minutes
            # before the result can be imported and measured. --no-optimize
            # trades the polish for the answer.
            "optimizer": {"enabled": optimize, "max_passes": 20,
                          "timeout": "PT45M"},
            "scoring": {},
        },
        "usage_and_diagnostic_data": {"disable_analytics": True},
        "feature_flags": {"multi_threading": True},
        "api_server": {"enabled": False},
        "mcp_server": {"enabled": False},
        "logging": {"console": {"enabled": True, "level": "INFO"},
                    "file": {"enabled": True, "level": "INFO"}},
        "version": "2.4.1",
    }, indent=1))

    SES.unlink(missing_ok=True)
    env = {**os.environ, "FREEROUTING__USER_DATA_PATH": str(FRCFG)}
    cmd = ["java", "-jar", str(jar), "-de", str(DSN), "-do", str(SES),
           "-mp", str(passes), "-mt", str(threads)]
    print(f"  route    {' '.join(cmd[2:])}")
    proc = subprocess.run(cmd, env=env, cwd=DIST, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)
    (DIST / "freerouting-run.log").write_text(proc.stdout)
    for line in proc.stdout.splitlines():
        if "stage" in line and ("completed" in line or "interrupted" in line):
            print("  " + line.split("INFO", 1)[-1].strip())
    if not SES.is_file():
        die("Freerouting produced no session file; see dist/freerouting-run.log")


MIN_SILK_TEXT_MM = 0.8


def normalize_silkscreen(board, pcbnew) -> int:
    """Raise reference designators to a size a screen printer can resolve.

    tscircuit emits most references at 0.4 mm, half of KiCad's 0.8 mm minimum
    and below what silkscreen printing holds -- they come back smeared or
    filled in, which matters for assembly and rework, and accounts for 199 of
    the DRC violations on the first routed board. Only the height is wrong;
    the 0.15 mm stroke is already above the 0.08 mm floor, and value text is
    already on F.Fab and hidden, which is what it should be.

    Nothing else about the silkscreen is touched here. The outlines clear each
    other by more than half a millimetre, which is the one thing about this
    board's silk that was never actually broken, and the connectors' generic
    "pinN" labels are left at 0.5 mm on purpose: enlarging them to 0.8 mm would
    put roughly 2.4 mm of text on a 2.54 mm header pitch, and the board already
    carries the labels that matter ("5V DC", "MIDI IN", "PITCH", "LINE L G R")
    as board-level silkscreen next to each connector. They remain as DRC
    warnings rather than being made illegible or removed.

    Raising the references costs about nineteen extra `silk_overlap` warnings,
    nearly all of which are a reference sitting on its own footprint outline.
    That is normal and prints fine; a reference too small to read does not.
    """
    fixed = 0
    for fp in board.GetFootprints():
        ref = fp.Reference()
        if not ref.IsVisible():
            continue
        if ref.GetTextHeight() < int(MIN_SILK_TEXT_MM * 1e6):
            ref.SetTextSize(pcbnew.VECTOR2I(int(MIN_SILK_TEXT_MM * 1e6),
                                            int(MIN_SILK_TEXT_MM * 1e6)))
            fixed += 1
    return fixed


def widen_thin_tracks(board, pcbnew) -> tuple[int, int]:
    """Bring stub copper up to the board minimum, except where it must be thin.

    Freerouting emits short pad-exit stubs at about 0.1124 mm regardless of the
    net class width, and `automatic_neckdown: false` does not stop it. Most of
    those stubs are half a millimetre of copper leaving an 0603 pad with room
    to spare on every side, so they are simply widened to the 0.15 mm minimum.

    Inside the BGA they are left alone. Escaping between two FTG256 balls has
    0.5 mm to work with, and 0.1124 mm of trace with 0.15 mm either side fits
    where 0.15 mm of trace does not -- widening those ten segments trades a
    width warning for four real clearance violations against the balls
    themselves. A narrower trace under a BGA is a deliberate, normal technique;
    it does mean the board's true minimum feature is 0.1124 mm rather than
    0.15 mm, which is what the fab has to be told (see docs/board.md section 3).
    """
    u1 = next((f for f in board.GetFootprints() if f.GetReference() == "U1"), None)
    if u1 is None:
        return 0, 0
    bb = u1.GetBoundingBox(False, False)
    margin = 200000
    x0, x1 = bb.GetX() - margin, bb.GetX() + bb.GetWidth() + margin
    y0, y1 = bb.GetY() - margin, bb.GetY() + bb.GetHeight() + margin

    def in_escape(track) -> bool:
        return any(x0 <= p.x <= x1 and y0 <= p.y <= y1
                   for p in (track.GetStart(), track.GetEnd()))

    minimum = int(0.15 * 1e6)
    widened = kept = 0
    for t in board.GetTracks():
        if t.Type() != pcbnew.PCB_TRACE_T or t.GetWidth() >= minimum:
            continue
        if in_escape(t):
            kept += 1
        else:
            t.SetWidth(minimum)
            widened += 1
    return widened, kept


def remove_dangling_vias(board, pcbnew) -> int:
    """Drop vias the router left connected to nothing.

    Fanout places an escape via for every pad it can, and when the autorouter
    later routes that net a different way the via is simply abandoned. It is
    not harmful, but it is a hole the fab drills and plates for no reason, and
    it shows up as `via_dangling` in DRC.
    """
    connectivity = board.GetConnectivity()
    doomed = []
    for t in board.GetTracks():
        if t.Type() != pcbnew.PCB_VIA_T:
            continue
        try:
            neighbours = connectivity.GetConnectedItems(t)
        except TypeError:
            continue
        # The via itself is normally in its own connected set, so a via that
        # reaches nothing else has at most one entry.
        if len([n for n in neighbours if n is not t]) < 1:
            doomed.append(t)
    for v in doomed:
        board.Remove(v)
    return len(doomed)


def import_ses() -> int:
    """Pull the routed copper back into the board and refill the ground planes."""
    pcbnew = load_pcbnew()
    board = pcbnew.LoadBoard(str(BOARD))
    if not pcbnew.ImportSpecctraSES(board, str(SES)):
        die("KiCad failed to import the session file")

    bumped = normalize_silkscreen(board, pcbnew)
    board.BuildConnectivity()
    widened, necked = widen_thin_tracks(board, pcbnew)
    dropped = remove_dangling_vias(board, pcbnew)
    shed = remove_degenerate_tracks(board, pcbnew)

    # The pours are regenerated here rather than trusted from the placed board:
    # they have to flow around copper that did not exist when tscircuit emitted
    # them, and an unfilled zone is not a ground plane.
    filler = pcbnew.ZONE_FILLER(board)
    filler.Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(str(ROUTED), board)

    if shed:
        print(f"  clean    {shed} degenerate segment(s) dropped after import")
    tracks = [t for t in board.GetTracks() if t.Type() == pcbnew.PCB_TRACE_T]
    vias = [t for t in board.GetTracks() if t.Type() == pcbnew.PCB_VIA_T]
    length = sum(t.GetLength() for t in tracks) / 1e6
    unrouted = board.GetConnectivity().GetUnconnectedCount(True)
    print(f"  routed   {len(tracks)} segments ({length:.0f} mm), {len(vias)} vias, "
          f"{board.GetAreaCount()} zones filled")
    print(f"  silk     {bumped} reference designator(s) raised to "
          f"{MIN_SILK_TEXT_MM} mm")
    print(f"  width    {widened} stub(s) widened to 0.15 mm, "
          f"{necked} left necked in the BGA escape")
    print(f"  cleanup  {dropped} dangling via(s) removed")
    print(f"  {'OK' if unrouted == 0 else 'INCOMPLETE'}       "
          f"{unrouted} unrouted connection(s)")
    print(f"  wrote    {shown(ROUTED)}")
    return unrouted


def check_not_already_running() -> None:
    """Refuse to start if another route is writing the same dist/ directory.

    Two routes sharing output files will swap the board out from under each
    other. That happened here once: a six-layer session finished importing two
    minutes after the board had been rebuilt with eight layers, producing an
    archive that held eight copper layers of six-layer routing. It is not
    detectable from the file afterwards, so this is a guard rather than a note.

    The lock is per output directory, not per machine, so an isolated run with
    its own tree can proceed in parallel -- which is the whole point of having
    one, when a long route is already in flight.
    """
    lock = DIST / ".route.lock"
    if lock.is_file():
        try:
            other = int(lock.read_text().strip())
        except ValueError:
            other = None
        if other and other != os.getpid():
            try:
                os.kill(other, 0)
            except (ProcessLookupError, PermissionError):
                pass            # stale lock, ours now
            else:
                die(f"another route is already writing {DIST} (pid {other}).\n"
                    "Wait for it, kill it, or run from a separate tree.")
    DIST.mkdir(parents=True, exist_ok=True)
    lock.write_text(str(os.getpid()))
    import atexit
    atexit.register(lambda: lock.unlink(missing_ok=True))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--passes", type=int, default=100)
    ap.add_argument("--threads", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument("--jar")
    ap.add_argument("--gui", action="store_true",
                    help="show Freerouting's board window while it routes (slower)")
    ap.add_argument("--no-fanout", action="store_true",
                    help="skip the fanout stage and go straight to autorouting")
    ap.add_argument("--no-optimize", action="store_true",
                    help="skip the optimizer; the session file is written as "
                         "soon as autorouting ends rather than up to 45 minutes "
                         "later, at the cost of via-count and length polish")
    ap.add_argument("--ripup", metavar="REF",
                    help="let the router rip up and rework copper inside this "
                         "footprint's bounding box; everything outside stays "
                         "frozen. Without it every pre-existing wire is "
                         "protected, which on a seeded re-route can wall the "
                         "router off from the only moves that would help.")
    ap.add_argument("--keep-via", metavar="X,Y", action="append", default=[],
                    help="protect the via at these mm coordinates even inside "
                         "--ripup, for escapes placed by hand (repeatable)")
    ap.add_argument("--import-only", action="store_true",
                    help="skip the router and re-import the existing .ses")
    ap.add_argument("--dist", type=Path,
                    help="work in this directory instead of dist/, so a re-route "
                         "seeded from an already-routed board cannot overwrite it")
    args = ap.parse_args()

    if args.dist:
        set_dist(args.dist.resolve())
        print(f"  dist     {DIST}")
    check_not_already_running()
    try:
        load_pcbnew()
    except ImportError:
        die("KiCad's pcbnew Python module is not importable.\n"
            "Install KiCad 9+ (Fedora: dnf install kicad; Debian: apt install kicad).")
    if not BOARD.is_file():
        die(f"{shown(BOARD)} not found -- run `npm run export` first.")

    write_project()
    print(f"  rules    {PROJECT.name} from scripts/rules.json")

    if not args.import_only:
        if not shutil.which("java"):
            die("java not found; Freerouting needs a JRE.")
        jar = find_jar(args.jar)
        keep = []
        for spec in args.keep_via:
            try:
                x, y = (float(v) for v in spec.split(","))
            except ValueError:
                die(f"--keep-via {spec}: expected X,Y in mm")
            keep.append((x, y))
        export_dsn(args.ripup, keep)
        run_freerouting(jar, args.passes, args.threads, args.gui,
                        fanout=not args.no_fanout,
                        optimize=not args.no_optimize)
    elif not SES.is_file():
        die(f"{shown(SES)} not found; run without --import-only first.")

    return 1 if import_ses() else 0


if __name__ == "__main__":
    raise SystemExit(main())
