#!/usr/bin/env python3
"""Build simplified, presentation-grade 3D models of the Courant board stack.

    python3 docs/media/scripts/render_pcb.py   # textures first
    python3 docs/media/scripts/build_3d.py

Every board outline, drill, pad, track and component *placement* comes from the
native KiCad 10 boards. The component *bodies* are parametric stand-ins sized
from datasheet package dimensions: the vendor/actual-part STEP models that
hardware/CURRENT_DESIGN.md describes are not committed (*.step is gitignored),
so this is a look-and-layout preview, not mechanical CAD.

Outputs (docs/media/3d/):
  courant_stack.glb        mainboard + panel, mated 19.99 mm apart (colour)
  courant_mainboard.glb    mainboard alone (colour)
  courant_panel.glb        panel/interface board alone (colour)
  courant_stack.stl        same stack as one mesh, for GitHub's STL viewer
"""
import math
import os
import sys

import numpy as np
import trimesh
from PIL import Image
from shapely import affinity
from shapely.geometry import box

sys.path.insert(0, os.path.dirname(__file__))
from kicad_board import Board  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'media', '3d')
TEX = os.path.join(ROOT, 'docs', 'media', 'scripts', '.textures')

T = 1.6            # board thickness (both boards, per stack-up)
GAP = 19.99        # fully mated PCB spacing, hardware/stack/panel-stack.json

# product frame (mm, Y up, +Z toward the front panel), derived from
# hardware/stack/panel-stack.json connector positions
MAIN_XY = lambda x, y: (x - 12.0, 164.25 - y)   # noqa: E731
PANEL_XY = lambda x, y: (x, 128.5 - y)          # noqa: E731

C = {
    'black': (24, 24, 26), 'ic': (30, 30, 33), 'res': (28, 28, 28), 'cap': (196, 160, 108),
    'tin': (205, 205, 210), 'gold': (222, 184, 92), 'nylon': (236, 228, 205), 'steel': (176, 180, 186),
    'alu': (150, 154, 160), 'knob': (36, 37, 40), 'knob_fx': (52, 54, 58), 'white': (240, 240, 236),
    'led': (70, 220, 110), 'fr4': (196, 178, 120), 'ind': (64, 64, 66),
    'pot': (40, 92, 160),
}


def rgba(name, a=255):
    # glTF vertex colours are linear; the table above is sRGB
    lin = [round(255 * ((v / 255 + 0.055) / 1.055) ** 2.4) for v in C[name]]
    return lin + [a]


def colored(mesh, name, a=255):
    mesh.visual = trimesh.visual.ColorVisuals(mesh, face_colors=np.tile(rgba(name, a), (len(mesh.faces), 1)))
    return mesh


def prism(poly, z0, z1, color, a=255):
    m = trimesh.creation.extrude_polygon(poly, z1 - z0)
    m.apply_translation([0, 0, z0])
    return colored(m, color, a)


def cyl(r, z0, z1, color, sections=40):
    m = trimesh.creation.cylinder(radius=r, height=z1 - z0, sections=sections)
    m.apply_translation([0, 0, (z0 + z1) / 2])
    return colored(m, color)


def blk(x0, y0, x1, y1, z0, z1, color):
    return prism(box(x0, y0, x1, y1), z0, z1, color)


def local_pads(fp):
    """Pad centres in footprint-local, unrotated, Y-up coordinates."""
    return [(p.lx, -p.ly, p) for p in fp.pads]


def dual_row_body(fp, h, color, inset=0.35):
    pts = local_pads(fp)
    xs = np.array([x for x, _, _ in pts])
    ys = np.array([y for _, y, _ in pts])
    sx = max(p.size[0] for _, _, p in pts)
    if np.ptp(xs) >= np.ptp(ys):     # rows run along X: pads above/below
        half_w = max(np.ptp(ys) / 2 - sx / 2 - inset, 0.6)
        return [blk(xs.min() - 0.5, -half_w + ys.mean(), xs.max() + 0.5, half_w + ys.mean(), 0, h, color)]
    half_w = max(np.ptp(xs) / 2 - sx / 2 - inset, 0.6)
    return [blk(-half_w + xs.mean(), ys.min() - 0.5, half_w + xs.mean(), ys.max() + 0.5, 0, h, color)]


def chip(fp, L, W, H, body, caps=True):
    """Two-terminal chip; long axis follows the pad pair."""
    pts = local_pads(fp)
    xs = [x for x, _, _ in pts]
    ys = [y for _, y, _ in pts]
    along_x = (max(xs) - min(xs)) >= (max(ys) - min(ys))
    cx, cy = np.mean(xs), np.mean(ys)
    hl, hw = (L / 2, W / 2) if along_x else (W / 2, L / 2)
    parts = [blk(cx - hl, cy - hw, cx + hl, cy + hw, 0, H, body)]
    if caps:
        e = 0.18 * L
        if along_x:
            parts += [blk(cx - hl - 0.01, cy - hw - 0.01, cx - hl + e, cy + hw + 0.01, 0, H + 0.01, 'tin'),
                      blk(cx + hl - e, cy - hw - 0.01, cx + hl + 0.01, cy + hw + 0.01, 0, H + 0.01, 'tin')]
        else:
            parts += [blk(cx - hw - 0.01, cy - hl - 0.01, cx + hw + 0.01, cy - hl + e, 0, H + 0.01, 'tin'),
                      blk(cx - hw - 0.01, cy + hl - e, cx + hw + 0.01, cy + hl + 0.01, 0, H + 0.01, 'tin')]
    return parts


def pins(fp, z0, z1, color='gold', s=0.64):
    out = []
    for x, y, p in local_pads(fp):
        if p.kind == 'thru_hole':
            out.append(blk(x - s / 2, y - s / 2, x + s / 2, y + s / 2, z0, z1, color))
    return out


def crt_local(fp, inset=0.25):
    poly = affinity.translate(fp.courtyard(), -fp.x, -fp.y)
    poly = affinity.scale(poly, 1, -1, origin=(0, 0))
    poly = affinity.rotate(poly, -fp.rot, origin=(0, 0))
    return poly.buffer(-inset) if poly.area > 4 * inset else poly


def knob(d, h, z0, color):
    parts = [cyl(d / 2, z0, z0 + h, color, 64), cyl(d / 2 * 0.86, z0 + h, z0 + h + 0.6, color, 64)]
    parts.append(blk(-0.5, d / 2 * 0.25, 0.5, d / 2 * 0.82, z0 + h + 0.6, z0 + h + 0.75, 'white'))
    return parts


def component(fp, panel):
    n = fp.name
    ref = fp.ref or ''
    if any(k in n for k in ('hole_circle', 'smtpad', 'Unknown__', 'Mount_NPTH', 'TestPoint')):
        return []
    if '0201' in n:
        return chip(fp, 0.6, 0.3, 0.3, 'cap')
    if 'R_0603' in n:
        return chip(fp, 1.6, 0.8, 0.45, 'res')
    if 'C_0603' in n:
        return chip(fp, 1.6, 0.8, 0.8, 'cap')
    if '0805' in n:
        return chip(fp, 2.0, 1.25, 0.9, 'cap')
    if '1210' in n:
        return chip(fp, 3.2, 2.5, 1.8, 'cap')
    if 'Fuse_1206' in n:
        return chip(fp, 3.2, 1.6, 0.6, 'black')
    if 'D_SMB' in n:
        return chip(fp, 4.3, 3.6, 2.2, 'black', caps=False)
    if 'SOD123' in n:
        return chip(fp, 2.7, 1.6, 1.1, 'black', caps=False)
    if 'SOT23' in n:
        return dual_row_body(fp, 1.1, 'ic', inset=0.15)
    if 'SOIC' in n or 'TSSOP' in n:
        return dual_row_body(fp, 1.6 if 'SOIC' in n else 1.1, 'ic')
    if 'DIP6' in n:
        return dual_row_body(fp, 3.4, 'ic', inset=0.6) + pins(fp, -1.6 - 1.2, 0.6, 'tin', 0.5)
    if 'FTG256' in n:
        return [blk(-8.5, -8.5, 8.5, 8.5, 0, 0.45, 'fr4'), blk(-8.4, -8.4, 8.4, 8.4, 0.45, 1.55, 'ic')]
    if 'WQFN' in n:
        return [blk(-1.5, -1.5, 1.5, 1.5, 0, 0.8, 'ic')]
    if 'FNR4030' in n:
        return [prism(box(-1.6, -1.6, 1.6, 1.6).buffer(0.4, 4), 0, 3.0, 'ind')]
    if 'SRP7050' in n:
        return [blk(-3.5, -3.5, 3.5, 3.5, 0, 5.0, 'ind')]
    if 'ASE_3225' in n:
        return [blk(-1.6, -1.25, 1.6, 1.25, 0, 0.35, 'nylon'), blk(-1.5, -1.15, 1.5, 1.15, 0.35, 1.0, 'steel')]
    if 'Samtec_IPT1' in n:   # mainboard terminal strip, posts reach into the panel sockets
        return [prism(crt_local(fp, 0.3), 0, 6.35, 'black')] + pins(fp, 0, 15.3)
    if 'Stack_2x10' in n:    # panel IPS1 socket strip
        return [prism(crt_local(fp, 0.35), 0, 8.51, 'black')]
    if 'Molex_22_23' in n or 'Molex_22-27' in n:
        return [prism(crt_local(fp, 0.05), 0, 3.2, 'nylon')] + pins(fp, 0, 8.4)
    if 'Wurth_61201021621' in n:
        return [prism(crt_local(fp, 0.3), 0, 9.0, 'black')] + pins(fp, 0, 6.0)
    if 'Wurth_450301014042' in n:
        return [prism(crt_local(fp, 0.2), 0, 3.5, 'steel'), blk(-0.6, -0.7, 0.6, 0.7, 3.5, 5.0, 'black')]
    if 'SW_PUSH_6x6' in n:
        return [blk(-3, -3, 3, 3, 0, 3.5, 'black'), cyl(1.75, 3.5, 5.0, 'black')]
    if 'LED_D3.0' in n:
        dome = trimesh.creation.icosphere(subdivisions=3, radius=1.5)
        dome.apply_translation([0, 0, 4.2])
        return [cyl(1.9, 0, 1.0, 'led'), cyl(1.5, 1.0, 4.2, 'led'), colored(dome, 'led')]
    if 'PTV09A' in n:        # 20 mm shaft from seating plane + knob
        big = ref in ('RV1', 'RV2', 'RV3')
        return ([blk(-4.85, -5.5, 4.85, 5.5, 0, 6.8, 'pot'), blk(-4.85, -5.5, 4.85, 5.5, 6.8, 7.3, 'steel'),
                 cyl(3.0, 7.3, 20.0, 'white')] +
                knob(23.0 if big else 14.0, 12.0 if big else 10.0, 11.0, 'knob' if big else 'knob_fx'))
    if 'PEC11R' in n:
        return ([blk(-6.2, -6.7, 6.2, 6.7, 0, 6.5, 'alu'), cyl(3.5, 6.5, 13.5, 'steel'), cyl(3.0, 13.5, 20.0, 'steel')] +
                knob(18.0, 11.0, 11.0, 'knob_fx'))
    if 'PJ398SM' in n:
        hexnut = trimesh.creation.cylinder(radius=4.6, height=2.0, sections=6)
        hexnut.apply_translation([0, 0, 13.0])
        return [blk(-4.5, -7.2, 4.5, 5.6, 0, 9.0, 'black'), cyl(3.0, 9.0, 14.5, 'steel'),
                colored(hexnut, 'steel'), cyl(1.8, 14.5, 14.55, 'black')]
    if '100SP' in n:
        lever = trimesh.creation.cylinder(radius=1.2, height=11.0, sections=24)
        lever.apply_transform(trimesh.transformations.rotation_matrix(math.radians(12), [1, 0, 0]))
        lever.apply_translation([0, 1.2, 21.0])
        return [blk(-3.4, -6.35, 3.4, 6.35, 0, 9.0, 'steel'), cyl(3.0, 9.0, 16.0, 'steel'), colored(lever, 'steel')]
    # fallback: courtyard block, so nothing silently disappears
    print('  (generic body)', ref, n)
    return [prism(crt_local(fp, 0.3), 0, 1.0, 'ic')]


def place(parts, fp, xy, board_z0):
    """Footprint-local parts -> product frame; back-side parts hang below."""
    px, py = xy(fp.x, fp.y)
    out = []
    for m in parts:
        m = m.copy()
        R = trimesh.transformations.rotation_matrix(math.radians(fp.rot), [0, 0, 1])
        if fp.back:
            # KiCad already stores back-side pad positions flipped, so only
            # Z is mirrored: the part hangs from the bottom face
            m.apply_transform(np.diag([1.0, 1.0, -1.0, 1.0]))
            m.invert()
            m.apply_transform(R)
            m.apply_translation([px, py, board_z0])
        else:
            m.apply_transform(R)
            m.apply_translation([px, py, board_z0 + T])
        out.append(m)
    return out


def board_meshes(b, xy, z0, name):
    """Laminate with textured top/bottom faces."""
    x0, y0, x1, y1 = b.bounds()
    poly = affinity.scale(b.outline, 1, -1, origin=(0, 0))
    ox, oy = xy(0, 0)
    poly = affinity.translate(poly, ox, oy)
    wall = trimesh.creation.extrude_polygon(poly, T)
    wall.apply_translation([0, 0, z0])
    # keep only the side walls of the extrusion; caps get textured copies
    normals = wall.face_normals
    side = np.abs(normals[:, 2]) < 0.5
    walls = wall.submesh([np.where(side)[0]], append=True)
    colored(walls, 'fr4')
    meshes = [walls]
    verts2d, faces = trimesh.creation.triangulate_polygon(poly, engine='earcut')
    for tag, z, flip in (('top', z0 + T, False), ('bottom', z0, True)):
        v = np.column_stack([verts2d, np.full(len(verts2d), z)])
        f = faces[:, ::-1] if flip else faces
        bx = v[:, 0] - ox
        by = -(v[:, 1] - oy)
        u = (bx - x0) / (x1 - x0)
        if flip:
            u = 1 - u
        uv = np.column_stack([u, 1 - (by - y0) / (y1 - y0)])
        img = Image.open(os.path.join(TEX, f'{name}_{tag}.png')).convert('RGB')
        img.thumbnail((2400, 2400))
        mat = trimesh.visual.material.PBRMaterial(baseColorTexture=img, metallicFactor=0.0, roughnessFactor=0.75)
        m = trimesh.Trimesh(vertices=v, faces=f, process=False,
                            visual=trimesh.visual.TextureVisuals(uv=uv, material=mat))
        meshes.append(m)
    return meshes


def build_board(path, xy, z0, name, panel):
    b = Board(path)
    meshes = board_meshes(b, xy, z0, name)
    parts = []
    for fp in b.footprints:
        parts += place(component(fp, panel), fp, xy, z0)
    return b, meshes, parts


def scene_of(meshes, centre=True):
    sc = trimesh.Scene()
    for i, m in enumerate(meshes):
        sc.add_geometry(m, node_name=f'n{i}')
    if centre:
        c = sc.bounds.mean(axis=0)
        sc.apply_translation(-c)
    # glTF is Y-up: rotate our Z-up product frame
    sc.apply_transform(trimesh.transformations.rotation_matrix(-math.pi / 2, [1, 0, 0]))
    return sc


def merged(meshes):
    parts = [trimesh.Trimesh(vertices=m.vertices, faces=m.faces, process=False) for m in meshes]
    return trimesh.util.concatenate(parts)


def main():
    os.makedirs(OUT, exist_ok=True)
    _, m_board, m_parts = build_board(os.path.join(ROOT, 'hardware/courant/deliverables/courant.kicad_pcb'),
                                       MAIN_XY, 0.0, 'mainboard', False)
    _, p_board, p_parts = build_board(os.path.join(ROOT, 'hardware/panel/design/radian_panel.kicad_pcb'),
                                       PANEL_XY, T + GAP, 'panel', True)

    scene_of(m_board + m_parts).export(os.path.join(OUT, 'courant_mainboard.glb'))
    scene_of(p_board + p_parts).export(os.path.join(OUT, 'courant_panel.glb'))
    allm = m_board + m_parts + p_board + p_parts
    scene_of(allm).export(os.path.join(OUT, 'courant_stack.glb'))
    stl = merged(allm)
    stl.apply_translation(-stl.bounds.mean(axis=0))
    stl.export(os.path.join(OUT, 'courant_stack.stl'))
    for f in sorted(os.listdir(OUT)):
        print(f, round(os.path.getsize(os.path.join(OUT, f)) / 1e6, 2), 'MB')


if __name__ == '__main__':
    main()
