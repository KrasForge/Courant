#!/usr/bin/env python3
"""Export the canonical panel graph/geometry as a tscircuit input snapshot."""
from __future__ import annotations
import json
from pathlib import Path
from design_data import PARTS, OUTLINE, WINDOWS, MOUNTS, CONFIG, STACK

ROOT = Path(__file__).resolve().parents[1]
CENTER = STACK["panel_product_center_mm"]
CX, CY = CENTER["x"], CENTER["y"]

def pt(p):
    return {"x": p[0] - CX, "y": p[1] - CY}

def part_record(p):
    pads = []
    for i, q in enumerate(p["fp"]["pads"], 1):
        pads.append({**q, "port": f"pin{i}", "net": p["nets"].get(q["n"])})
    return {
        "ref": p["ref"], "value": p["value"], "block": p["block"],
        "x": p["x"] - CX, "y": p["y"] - CY,
        "side": "bottom" if p["side"] == "B" else "top",
        "rotation": p["angle"], "body": p["fp"]["body"], "pads": pads,
    }
data = {
    "revision": CONFIG["revision"],
    "status": CONFIG["status"],
    "center_product_mm": CENTER,
    "outline": [pt(p) for p in OUTLINE],
    "windows": [[pt(p) for p in poly] for poly in WINDOWS],
    "mounts": [{"x": x-CX, "y": y-CY, "diameter": d} for x,y,d in MOUNTS],
    "parts": [part_record(p) for p in PARTS],
    "stack": STACK,
}
out = ROOT / "tscircuit-design.json"
out.write_text(json.dumps(data, indent=2) + "\n")
print(out, len(data["parts"]), "parts")
