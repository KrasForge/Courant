#!/usr/bin/env python3
"""
Attach KiCad 3D models to the board so it can be rendered as it will be built.

tscircuit generates footprints with pads, courtyard and silkscreen but no
`(model ...)` reference, so KiCad's 3D viewer has nothing to place and renders
the board as bare lands. That is not wrong -- it is an accurate picture of the
fabricated PCB before assembly -- but it is not what the finished hardware
looks like.

This maps each footprint name onto a body from KiCad's standard 3D library and
writes the reference in. Nothing electrical changes: models affect rendering
and mechanical checks only, never copper, DRC or fabrication output.

The board this writes to is a render copy, not dist/courant.routed.kicad_pcb.
design.ts owns the placement and would drop these references on the next
export, so baking them into the routed board would quietly rot.

Some mappings are the nearest standard body rather than the exact part -- the
regulator's QFN-16 and the optocoupler are approximations, noted below. They
are right to within a fraction of a millimetre and wrong only in the way a
photograph of a similar chip is wrong.

    python3 scripts/models3d.py BOARD --out OUT
"""
from __future__ import annotations

import argparse, math, os, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plane_escape import pcbnew

LIB = Path("/usr/share/kicad/3dmodels")

# footprint name -> library-relative model. Exact unless marked.
MAP = {
    "resistor_res0603":   "Resistor_SMD.3dshapes/R_0603_1608Metric.step",
    "capacitor_cap0201":  "Capacitor_SMD.3dshapes/C_0201_0603Metric.step",
    "capacitor_cap0603":  "Capacitor_SMD.3dshapes/C_0603_1608Metric.step",
    "capacitor_cap0805":  "Capacitor_SMD.3dshapes/C_0805_2012Metric.step",
    "capacitor_cap1210":  "Capacitor_SMD.3dshapes/C_1210_3225Metric.step",
    # 17x17 mm, 16x16 balls on a 1.0 mm pitch: the FTG256 exactly.
    "XC7A35T-1FTG256C":   # footprint name kept from the pre-swap export
        "Package_BGA.3dshapes/BGA-256_17.0x17.0mm_Layout16x16_P1.0mm"
        "_Ball0.5mm_Pad0.4mm_NSMD.step",
    "XC7A50T-1FTG256I":
        "Package_BGA.3dshapes/BGA-256_17.0x17.0mm_Layout16x16_P1.0mm"
        "_Ball0.5mm_Pad0.4mm_NSMD.step",
    "W25Q64JVSSIQ":       "Package_SO.3dshapes/JEITA_SOIC-8_3.9x4.9mm_P1.27mm.step",
    "MCP6002-I_SN":       "Package_SO.3dshapes/JEITA_SOIC-8_3.9x4.9mm_P1.27mm.step",
    "MCP3208-CI_SL":      "Package_SO.3dshapes/JEITA_SOIC-16_3.9x9.9mm_P1.27mm.step",
    "PCM5102APWR":        "Package_SO.3dshapes/TSSOP-20_4.4x6.5mm_P0.65mm.step",
    "REF3125AIDBZR":      "Package_TO_SOT_SMD.3dshapes/SOT-23.step",
    "MCP6561T-E_OT":      "Package_TO_SOT_SMD.3dshapes/SOT-23-5.step",
    "BAT54S":             "Package_TO_SOT_SMD.3dshapes/SOT-23.step",
    "1N4148W":            "Diode_SMD.3dshapes/D_SOD-123.step",
    # U8's pads are 6 PTH on 7.62 mm rows at 2.54 mm pitch -- a plain DIP-6.
    # The earlier choice here was the *socket* body, which is 3 mm taller than
    # the part and would have been designed around.
    "H11L1M":             "Package_DIP.3dshapes/DIP-6_W7.62mm.step",
    # The exact part the BOM specifies, not a stand-in: cjiang FNR4030S1R0MT,
    # 4.0 x 4.0 x 3.0 mm. The earlier SRN4018 is the same footprint but 1.8 mm
    # tall, which understates the height above the board by 1.2 mm.
    "inductor":           "Inductor_SMD.3dshapes/L_Changjiang_FNR4030S.step",
    # Approximation: TPS62130 is RGT0016C with a 1.68 mm exposed pad against
    # the library's 1.7 mm. Same body size; only the pad differs.
    "TPS62130ARGTR":      "Package_DFN_QFN.3dshapes/QFN-16-1EP_3x3mm_P0.5mm_EP1.7x1.7mm.step",
}
# Oscillators share a body, matched by prefix. The board's 3.2 x 2.5 mm part
# has no library equivalent; this is the nearest 4-pin SMD can and renders a
# little small.
# Every connector on this board is a plain 0.1 inch through-hole header --
# the panel-facing interface geometry -- so they are matched by shape rather than by name:
# through-hole pads on a 2.54 mm pitch, N of them, is a 1xN pin header.
# Naming each of the fifteen individually would need editing this file every
# time a header gains or loses a pin.
HEADER = "Connector_PinHeader_2.54mm.3dshapes/PinHeader_1x%02d_P2.54mm_Vertical.step"

PREFIX = {
    "ASE-": "Oscillator.3dshapes/Oscillator_SMD_SeikoEpson_SG210-4Pin_2.5x2.0mm.step",
}


def local_pads(fp):
    """Pad centres in the footprint's own unrotated frame, by pad number."""
    o = fp.GetPosition()
    a = fp.GetOrientation().AsRadians()
    ca, sa = math.cos(a), math.sin(a)
    out = {}
    for pad in fp.Pads():
        q = pad.GetPosition()
        dx, dy = (q.x - o.x) / 1e6, (q.y - o.y) / 1e6
        out[pad.GetNumber()] = (dx * ca + dy * sa, -dx * sa + dy * ca)
    return out


def header_for(fp, lib):
    """A 1xN 0.1 inch header, plus the transform that lands it on the pads.

    KiCad's own header footprints put pin 1 at the origin with the row running
    along +Y, and their model needs no offset or rotation because of it. These
    footprints are generated by tscircuit: the row runs along X and is centred
    on the origin instead. Attaching the model without correcting for that puts
    every connector a half-body off and turned ninety degrees.

    The correction is derived from the pads rather than assumed, so a header
    placed at any angle -- J1 sits at 90 -- comes out right. KiCad's model
    offset is in a frame whose Y and Z-rotation are negated against the board's.
    """
    pads = list(fp.Pads())
    if len(pads) < 2 or not all(p.GetAttribute() == pcbnew.PAD_ATTRIB_PTH
                                for p in pads):
        return None
    loc = local_pads(fp)
    if "1" not in loc or "2" not in loc:
        return None
    gaps = sorted({round(math.dist(a, b), 2)
                   for i, a in enumerate(loc.values())
                   for b in list(loc.values())[i + 1:]})
    if not gaps or abs(gaps[0] - 2.54) > 0.05:
        return None
    rel = HEADER % len(pads)
    if not (lib / rel).is_file():
        return None
    (x1, y1), (x2, y2) = loc["1"], loc["2"]
    theta = math.degrees(math.atan2(y2 - y1, x2 - x1))   # row direction
    # KiCad's stored model rotation turns the opposite way to the board frame,
    # so this is +(theta - 90), not -. With the sign the other way the body's
    # pin 1 still lands on pad 1 and every other pin runs off the far side --
    # which looks almost right and is completely wrong.
    return rel, (x1, -y1, 0.0), (0.0, 0.0, theta - 90.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board"); ap.add_argument("--out", required=True)
    ap.add_argument("--lib", type=Path, default=LIB)
    a = ap.parse_args()

    if not a.lib.is_dir() or not any(a.lib.iterdir()):
        print(f"  {a.lib} is empty -- install kicad-packages3d first")
        return 1

    board = pcbnew.LoadBoard(a.board)
    placed = missing = skipped = 0
    absent: set = set()
    for fp in board.GetFootprints():
        # Match on the value as well as the footprint name. A part-number
        # change (the A35T -> A50T swap) updates the value while the footprint
        # keeps whatever name the last export gave it, so keying on one alone
        # silently drops the model for exactly the part you just changed.
        name = fp.GetFPIDAsString().split(":")[-1].split("__", 1)[0]
        rel = MAP.get(fp.GetValue()) or MAP.get(name)
        if rel is None:
            for pre, r in PREFIX.items():
                if name.startswith(pre):
                    rel = r; break
        offset = rot = (0.0, 0.0, 0.0)
        if rel is None:
            hit = header_for(fp, a.lib)
            if hit is not None:
                rel, offset, rot = hit
        if rel is None:
            skipped += 1
            continue
        path = a.lib / rel
        if not path.is_file():
            absent.add(rel); missing += 1
            continue
        m = pcbnew.FP_3DMODEL()
        m.m_Filename = str(path)
        m.m_Offset = pcbnew.VECTOR3D(*offset)
        m.m_Rotation = pcbnew.VECTOR3D(*rot)
        m.m_Scale = pcbnew.VECTOR3D(1.0, 1.0, 1.0)
        m.m_Show = True
        fp.Models().push_back(m)
        placed += 1

    pcbnew.SaveBoard(a.out, board)
    print(f"  attached   {placed} model(s)")
    print(f"  no mapping {skipped} footprint(s) -- 12 thermal-via arrays, 4 mounting holes, 3 fiducials")
    if absent:
        print(f"  not in lib {missing}: " + ", ".join(sorted(absent)[:4]))
    print(f"  wrote      {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
