#!/usr/bin/env python3
"""
Render the schematic from circuit JSON, because tscircuit's own renderers do not.

`tsci export -f schematic-svg` and `-f schematic-pdf` both emit a near-empty
sheet for this design -- twenty text elements and sixteen lines for two hundred
components, about ten kilobytes either way. The data is not missing: the circuit
JSON carries 183 schematic components, 739 ports, 532 traces and 248 net labels.
Only the drawing is missing, so this draws it.

It is a schematic in the sense that matters for a handoff -- every component,
every pin, every wire and every net label, to scale and legible -- and not in
the sense of a hand-drafted sheet with signal flow arranged left to right.
tscircuit places symbols on a grid in declaration order; no autolayout will
turn that into the drawing a person would have made.

    python3 scripts/schematic.py CIRCUIT_JSON --out OUT.svg
"""
from __future__ import annotations

import argparse, json
from xml.sax.saxutils import escape

PX = 64.0          # pixels per schematic unit
PAD = 1.2          # margin, schematic units


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("circuit"); ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="Courant Rev A")
    a = ap.parse_args()

    d = json.load(open(a.circuit))
    by = {}
    for e in d:
        by.setdefault(e.get("type"), []).append(e)
    src = {e["source_component_id"]: e for e in by.get("source_component", [])}

    xs, ys = [], []
    def note(x, y):
        xs.append(x); ys.append(y)

    for c in by.get("schematic_component", []):
        w, h = c["size"]["width"] / 2, c["size"]["height"] / 2
        note(c["center"]["x"] - w, c["center"]["y"] - h)
        note(c["center"]["x"] + w, c["center"]["y"] + h)
    for t in by.get("schematic_trace", []):
        for ed in t.get("edges", []):
            for p in (ed.get("from"), ed.get("to")):
                if p: note(p["x"], p["y"])
    for n in by.get("schematic_net_label", []):
        note(n["center"]["x"], n["center"]["y"])
    if not xs:
        print("  nothing to draw"); return 1

    x0, x1 = min(xs) - PAD, max(xs) + PAD
    y0, y1 = min(ys) - PAD, max(ys) + PAD
    W, H = (x1 - x0) * PX, (y1 - y0) * PX

    def X(v): return (v - x0) * PX
    def Y(v): return (y1 - v) * PX          # schematic Y is up, SVG Y is down

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" '
         f'height="{H:.0f}" viewBox="0 0 {W:.0f} {H:.0f}">',
         '<rect width="100%" height="100%" fill="#fbfaf7"/>',
         '<g stroke-linecap="round" stroke-linejoin="round">']

    # wires first, so symbols sit on top of them
    for t in by.get("schematic_trace", []):
        for ed in t.get("edges", []):
            f, g = ed.get("from"), ed.get("to")
            if not f or not g:
                continue
            o.append(f'<line x1="{X(f["x"]):.1f}" y1="{Y(f["y"]):.1f}" '
                     f'x2="{X(g["x"]):.1f}" y2="{Y(g["y"]):.1f}" '
                     f'stroke="#1f6f3f" stroke-width="2"/>')
        for j in t.get("junctions", []):
            o.append(f'<circle cx="{X(j["x"]):.1f}" cy="{Y(j["y"]):.1f}" '
                     f'r="4" fill="#1f6f3f"/>')

    for c in by.get("schematic_component", []):
        cx, cy = c["center"]["x"], c["center"]["y"]
        w, h = c["size"]["width"], c["size"]["height"]
        o.append(f'<rect x="{X(cx - w / 2):.1f}" y="{Y(cy + h / 2):.1f}" '
                 f'width="{w * PX:.1f}" height="{h * PX:.1f}" rx="3" '
                 f'fill="#ffffff" stroke="#1b1b1b" stroke-width="2"/>')
        s = src.get(c.get("source_component_id"), {})
        name = s.get("name", "")
        # circuit JSON keeps the value under a different key per component
        # type; there is no common one, and reading only display_value drops
        # every resistor, capacitor and inductor on the sheet.
        val = next((s[k] for k in ("display_resistance", "display_capacitance",
                                   "display_inductance", "display_value",
                                   "manufacturer_part_number") if s.get(k)), "")
        if name:
            o.append(f'<text x="{X(cx):.1f}" y="{Y(cy + h / 2) - 7:.1f}" '
                     f'font-family="sans-serif" font-size="15" font-weight="600" '
                     f'text-anchor="middle" fill="#1b1b1b">{escape(name)}</text>')
        if val:
            o.append(f'<text x="{X(cx):.1f}" y="{Y(cy - h / 2) + 19:.1f}" '
                     f'font-family="sans-serif" font-size="13" '
                     f'text-anchor="middle" fill="#8a4b00">{escape(str(val))}</text>')

    for p in by.get("schematic_port", []):
        o.append(f'<circle cx="{X(p["center"]["x"]):.1f}" '
                 f'cy="{Y(p["center"]["y"]):.1f}" r="3" fill="#b03030"/>')

    for n in by.get("schematic_net_label", []):
        cx, cy = n["center"]["x"], n["center"]["y"]
        o.append(f'<text x="{X(cx):.1f}" y="{Y(cy):.1f}" font-family="sans-serif" '
                 f'font-size="13" text-anchor="middle" fill="#0b5cab">'
                 f'{escape(n.get("text", ""))}</text>')

    for t in by.get("schematic_text", []):
        pos = t.get("position") or t.get("center")
        if not pos:
            continue
        o.append(f'<text x="{X(pos["x"]):.1f}" y="{Y(pos["y"]):.1f}" '
                 f'font-family="sans-serif" font-size="{t.get("font_size", 0.18) * PX:.0f}" '
                 f'fill="{t.get("color", "#006464")}">{escape(t.get("text", ""))}</text>')

    o.append('</g>')
    o.append(f'<text x="24" y="{H - 20:.0f}" font-family="sans-serif" '
             f'font-size="26" fill="#1b1b1b">{escape(a.title)} — schematic — '
             f'{len(by.get("schematic_component", []))} components, '
             f'{len(by.get("schematic_trace", []))} nets drawn</text>')
    o.append('</svg>')
    open(a.out, "w").write("\n".join(o))
    print(f"  {len(by.get('schematic_component', []))} components, "
          f"{len(by.get('schematic_port', []))} ports, "
          f"{len(by.get('schematic_trace', []))} traces, "
          f"{len(by.get('schematic_net_label', []))} net labels")
    print(f"  {W:.0f} x {H:.0f} px -> {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
