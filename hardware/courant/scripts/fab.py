#!/usr/bin/env python3
"""
Design rule check and fabrication outputs for the routed board.

Runs against `dist/courant.routed.kicad_pcb`, which `scripts/route.py` writes.
It refuses to run on the unrouted board on purpose: Gerbers plotted from a
board with no copper look exactly like fabrication data and are not, and that
is the one mistake in this directory that would cost real money.

    python3 scripts/fab.py            # DRC, then Gerbers/drill/placement/BOM
    python3 scripts/fab.py --drc-only

Outputs land in dist/fab/. Requires KiCad 9+ (`kicad-cli` and `pcbnew`).
"""
from __future__ import annotations

import argparse
import csv
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DIST = ROOT / "dist"
ROUTED = DIST / "courant.routed.kicad_pcb"
FAB = DIST / "fab"

# Every copper layer plus the mask, paste, silkscreen and outline the fab needs.
LAYERS = ("F.Cu,In1.Cu,In2.Cu,In3.Cu,In4.Cu,B.Cu,"
          "F.Paste,B.Paste,F.SilkS,B.SilkS,F.Mask,B.Mask,Edge.Cuts")


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
    print(f"fab: {msg}", file=sys.stderr)
    raise SystemExit(1)


def run(*cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True)


def drc() -> int:
    """Run KiCad's DRC and print the violation summary.

    Zones are refilled first: a stale pour would let a real clearance error
    through, and the copper under the BGA is entirely pour.
    """
    report = DIST / "courant.drc.rpt"
    r = run("kicad-cli", "pcb", "drc", "--output", report, "--format", "report",
            "--units", "mm", "--severity-error", "--severity-warning",
            "--refill-zones", "--exit-code-violations", ROUTED)
    text = report.read_text() if report.is_file() else r.stdout
    counts = {}
    for line in text.splitlines():
        line = line.strip()
        for kind in ("violations", "unconnected items", "schematic parity"):
            if line.startswith("** Found") and kind in line:
                counts[kind] = int(line.split()[2])
    for kind, n in counts.items():
        print(f"  drc      {n} {kind}")
    if not counts:
        print("  drc      " + (r.stdout.strip().splitlines() or ["no report"])[-1])
    print(f"  wrote    {report.relative_to(ROOT)}")
    return r.returncode


def preview() -> None:
    """Plot a top and bottom view of the routed board as SVG and PNG.

    Generated here rather than by hand so the pictures cannot drift from the
    copper they claim to show. SVG is the artifact worth keeping -- it is
    vector, so it zooms losslessly into the BGA escape -- and the PNG exists
    only because most things that display an image will not render SVG.
    """
    views = {
        "courant-top": "F.Cu,In1.Cu,F.SilkS,F.Mask,Edge.Cuts",
        "courant-bottom": "B.Cu,In4.Cu,B.SilkS,B.Mask,Edge.Cuts",
    }
    made = []
    for name, layers in views.items():
        svg = DIST / f"{name}.svg"
        r = run("kicad-cli", "pcb", "export", "svg", "--mode-single",
                "--exclude-drawing-sheet", "--fit-page-to-board",
                "--page-size-mode", "2", "-l", layers, "-o", svg, ROUTED)
        if r.returncode:
            print(f"  preview  {name}.svg failed:\n{r.stdout}{r.stderr}")
            continue
        made.append(svg.name)
        if shutil.which("magick"):
            png = DIST / f"{name}.png"
            if run("magick", "-density", "160", "-background", "white", svg,
                   "-flatten", "-resize", "2000x", png).returncode == 0:
                made.append(png.name)
    print(f"  preview  {', '.join(made) if made else 'none'}")


def bom() -> None:
    """Write a flat BOM grouped by value and footprint, straight from the board.

    Generated from the routed board rather than from design.ts so that what is
    ordered is what is on the copper.
    """
    pcbnew = load_pcbnew()
    board = pcbnew.LoadBoard(str(ROUTED))
    groups: dict[tuple[str, str], list[str]] = {}
    for fp in board.GetFootprints():
        if not fp.GetReference():
            continue  # mounting holes, thermal helpers and fiducials are not BOM parts
        key = (fp.GetValue(), str(fp.GetFPID().GetLibItemName()))
        groups.setdefault(key, []).append(fp.GetReference())
    out = FAB / "courant-bom.csv"
    with out.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["Comment", "Designator", "Footprint", "Quantity"])
        for (value, footprint), refs in sorted(groups.items()):
            refs.sort()
            w.writerow([value, ",".join(refs), footprint, len(refs)])
    print(f"  bom      {len(groups)} line items, "
          f"{sum(len(r) for r in groups.values())} placements")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--drc-only", action="store_true")
    args = ap.parse_args()

    if not shutil.which("kicad-cli"):
        die("kicad-cli not found; install KiCad 9 or newer.")
    if not ROUTED.is_file():
        die(f"{ROUTED.relative_to(ROOT)} not found.\n"
            "Route the board first: python3 scripts/route.py\n"
            "Gerbers are not plotted from the unrouted board on purpose -- they "
            "would carry pads, mask and drills but no copper.")

    status = drc()
    if args.drc_only:
        return status
    if status:
        die("Native DRC did not pass; existing fabrication outputs left untouched.")

    FAB.mkdir(parents=True, exist_ok=True)
    for f in FAB.iterdir():
        f.unlink()

    r = run("kicad-cli", "pcb", "export", "gerbers", "-o", FAB, "--layers", LAYERS,
            "--no-protel-ext", "--check-zones", "--subtract-soldermask", ROUTED)
    if r.returncode:
        die(f"gerber export failed:\n{r.stdout}{r.stderr}")
    r = run("kicad-cli", "pcb", "export", "drill", "-o", FAB, "--format", "excellon",
            "--excellon-separate-th", "--excellon-units", "mm",
            "--generate-map", "--map-format", "gerberx2", ROUTED)
    if r.returncode:
        die(f"drill export failed:\n{r.stdout}{r.stderr}")
    r = run("kicad-cli", "pcb", "export", "pos", "-o", FAB / "courant-pos.csv",
            "--format", "csv", "--units", "mm", "--side", "both", ROUTED)
    if r.returncode:
        die(f"placement export failed:\n{r.stdout}{r.stderr}")
    bom()
    preview()

    files = sorted(FAB.iterdir())
    print(f"  gerbers  {len(files)} files in {FAB.relative_to(ROOT)}/")
    archive = shutil.make_archive(str(DIST / "courant-fab"), "zip", FAB)
    print(f"  wrote    {Path(archive).relative_to(ROOT)}")
    if status:
        print("  NOTE     DRC reported violations; see dist/courant.drc.rpt")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
