#!/usr/bin/env python3
"""Build drawing-derived 3D reference models for the RADIAN direct stack.

These are NOT Samtec-supplied STEP files. They are mechanical reference models
constructed from Samtec's official IPT1/IPS1 marketing prints and mated-view
drawing so KiCad/case CAD can represent the actual -06/-01 stack geometry,
all 20 contacts, solder tails, and mating cavities.

Official sources:
- IPT1 series print: https://suddendocs.samtec.com/prints/ipt1-1xx-xx-xx-d-xx-mkt.pdf
- IPS1 series print: https://suddendocs.samtec.com/prints/ips1-1xx-xx-xx-d-xx-mkt.pdf
- IPT1 recommended PCB layout:
  https://suddendocs.samtec.com/prints/ipt1-1xx-xx-x-d-xxx_ipt1-1xx-xx-x-d-ra-xxx-mkt.pdf
- IPS1 recommended PCB layout: https://suddendocs.samtec.com/prints/ips1-th.pdf
- Mated views: https://suddendocs.samtec.com/prints/ipx1%20mated%20document-mkt.pdf
"""
from pathlib import Path
import json
import cadquery as cq

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "models"
OUT.mkdir(parents=True, exist_ok=True)

# Common 2x10 geometry, centered on the footprint origin.
PITCH = 2.54
ROW_X = (-1.27, 1.27)
COL_Y = tuple(-11.43 + i * PITCH for i in range(10))

# Manufacturer drawing dimensions (mm).
IPT = {
    "part": "IPT1-110-06-L-D",
    "body_width": 5.08,
    "body_length": 25.908,     # (10 * 2.54) + 0.508
    "shroud_height": 6.35,     # .250 REF
    "insulation_height": 15.30,# B for lead style -06
    "tail": 2.35,              # C for -06 / DigiKey post length
    "pin_square": 0.64,        # .025 SQ
    "mating_contact": 3.94,    # .155 REF
    "hole": 1.02,              # recommended PCB layout
}
IPS = {
    "part": "IPS1-110-01-L-D",
    "body_width": 4.95,
    "body_length": 25.781,     # (10 * 2.54) + 0.381
    "height": 8.51,            # .335 REF
    "tower": 3.81,             # .150 REF
    "tail": 2.54,              # .100 REF
    "tail_x": 0.79,            # .031 REF
    "tail_y": 0.41,            # .016 REF
    "hole": 1.04,              # recommended PCB layout
}

MATED = {
    "fully_mated_board_gap": 19.99,
    "max_board_gap": 20.45,
    "fully_mated_wipe": 0.84,
    "min_wipe_at_max_gap": 0.38,
}

BLACK = cq.Color(0.08, 0.08, 0.08)
GOLD = cq.Color(0.78, 0.58, 0.16)
TIN = cq.Color(0.70, 0.72, 0.74)


def box(w, d, h, x=0.0, y=0.0, z=0.0):
    return cq.Workplane("XY").box(w, d, h, centered=(True, True, False)).translate((x, y, z)).val()


def pin_centres():
    # Numbering matches the Samtec print / mainboard footprint:
    # 1,2 at one end; 19,20 at the other.
    out = []
    n = 1
    for y in COL_Y:
        for x in ROW_X:
            out.append((n, x, y))
            n += 1
    return out


def build_ipt():
    assy = cq.Assembly(name=IPT["part"])

    # The -06 style is elevated: the 6.35 mm shroud occupies the top of a
    # 15.30 mm insulation height, so its lower face is 8.95 mm above the PCB.
    z0 = IPT["insulation_height"] - IPT["shroud_height"]

    # 20 individually-shrouded contact cells. The cavity/tower dimensions are
    # reference-envelope details; the externally controlled dimensions above
    # come directly from the Samtec print.
    cell_outer = 2.54
    cell_cavity = 2.16
    shells = []
    for _, x, y in pin_centres():
        outer = box(cell_outer, cell_outer, IPT["shroud_height"], x, y, z0)
        inner = box(cell_cavity, cell_cavity, IPT["shroud_height"] + 0.2, x, y, z0 - 0.1)
        shells.append(outer.cut(inner))

    # Add thin end walls to reach the exact 25.908 mm overall body length.
    extra = (IPT["body_length"] - 10 * PITCH) / 2
    shells.append(box(IPT["body_width"], extra, IPT["shroud_height"], 0, -(12.7 + extra/2), z0))
    shells.append(box(IPT["body_width"], extra, IPT["shroud_height"], 0, +(12.7 + extra/2), z0))
    assy.add(cq.Compound.makeCompound(shells), name="shroud", color=BLACK)

    # All 20 .025" square contacts, including the 2.35 mm solder tails.
    # Top ends at the 15.30 mm insulation-height plane.
    contacts = [
        box(IPT["pin_square"], IPT["pin_square"],
            IPT["insulation_height"] + IPT["tail"], x, y, -IPT["tail"])
        for _, x, y in pin_centres()
    ]
    assy.add(cq.Compound.makeCompound(contacts), name="contacts_20", color=GOLD)
    return assy


def build_ips():
    assy = cq.Assembly(name=IPS["part"])
    base_h = IPS["height"] - IPS["tower"]

    # Base block with clearance apertures at every contact.
    base = box(IPS["body_width"], IPS["body_length"], base_h, 0, 0, 0)
    for _, x, y in pin_centres():
        base = base.cut(box(1.00, 1.00, base_h + 0.2, x, y, -0.1))
    assy.add(base, name="base", color=BLACK)

    # 20 individual socket towers with visible mating openings.
    tower_outer = 1.90
    tower_cavity = 0.92
    towers = []
    for _, x, y in pin_centres():
        outer = box(tower_outer, tower_outer, IPS["tower"], x, y, base_h)
        inner = box(tower_cavity, tower_cavity, IPS["tower"] + 0.2, x, y, base_h - 0.1)
        towers.append(outer.cut(inner))
    assy.add(cq.Compound.makeCompound(towers), name="socket_towers_20", color=BLACK)

    # All 20 through-hole solder tails. The print specifies .79 x .41 mm REF.
    tails = [
        box(IPS["tail_x"], IPS["tail_y"], IPS["tail"], x, y, -IPS["tail"])
        for _, x, y in pin_centres()
    ]
    assy.add(cq.Compound.makeCompound(tails), name="tails_20", color=TIN)
    return assy


def main():
    ipt = build_ipt()
    ips = build_ips()

    ipt_path = OUT / "Samtec_IPT1-110-06-L-D_drawing_reference.step"
    ips_path = OUT / "Samtec_IPS1-110-01-L-D_drawing_reference.step"
    ipt.export(str(ipt_path))
    ips.export(str(ips_path))

    insertion = IPT["insulation_height"] + IPS["height"] - MATED["fully_mated_board_gap"]
    insertion_max_gap = IPT["insulation_height"] + IPS["height"] - MATED["max_board_gap"]

    meta = {
        "status": "drawing-derived mechanical reference; not vendor-supplied STEP",
        "sources": {
            "ipt_print": "https://suddendocs.samtec.com/prints/ipt1-1xx-xx-xx-d-xx-mkt.pdf",
            "ips_print": "https://suddendocs.samtec.com/prints/ips1-1xx-xx-xx-d-xx-mkt.pdf",
            "ipt_footprint": "https://suddendocs.samtec.com/prints/ipt1-1xx-xx-x-d-xxx_ipt1-1xx-xx-x-d-ra-xxx-mkt.pdf",
            "ips_footprint": "https://suddendocs.samtec.com/prints/ips1-th.pdf",
            "mated": "https://suddendocs.samtec.com/prints/ipx1%20mated%20document-mkt.pdf",
        },
        "ipt": IPT,
        "ips": IPS,
        "mated": MATED,
        "contacts_per_connector": 20,
        "nominal_geometric_insertion_mm": round(insertion, 3),
        "geometric_insertion_at_max_gap_mm": round(insertion_max_gap, 3),
        "models": [ipt_path.name, ips_path.name],
    }
    (OUT / "samtec_direct_stack_reference.json").write_text(json.dumps(meta, indent=2) + "\n")

    print(ipt_path)
    print(ips_path)
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
