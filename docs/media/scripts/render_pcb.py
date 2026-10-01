#!/usr/bin/env python3
"""Render presentation views of the native Courant boards.

    python3 docs/media/scripts/render_pcb.py

Writes docs/media/images/{mainboard,panel}_{top,bottom}.png (photo-style
solder-mask views) and the matching texture maps used by build_3d.py. Reads
only the canonical native KiCad files; nothing in hardware/ is modified.
"""
import os
import sys

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import PathPatch
from matplotlib.path import Path as MPath
from shapely.geometry import LineString, Point
from shapely.ops import unary_union

sys.path.insert(0, os.path.dirname(__file__))
from kicad_board import Board  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'media', 'images')
TEX = os.path.join(ROOT, 'docs', 'media', 'scripts', '.textures')

BOARDS = {
    'mainboard': os.path.join(ROOT, 'hardware/courant/deliverables/courant.kicad_pcb'),
    'panel': os.path.join(ROOT, 'hardware/panel/design/radian_panel.kicad_pcb'),
}

MASK = '#0d3b2e'       # matte dark-green solder mask over bare laminate
MASK_CU = '#16584a'    # mask over copper (tracks / pours read lighter)
ENIG = '#d8b25a'       # exposed gold pads
SILK = '#f2f2ee'
DRILL = '#0b0b0b'
EDGE = '#2a2a2a'


def geom_patches(geom, **kw):
    if geom.is_empty:
        return []
    polys = [geom] if geom.geom_type == 'Polygon' else [g for g in getattr(geom, 'geoms', []) if g.geom_type == 'Polygon']
    out = []
    for p in polys:
        verts, codes = [], []
        for ring in [p.exterior] + list(p.interiors):
            xs = list(ring.coords)
            verts += xs
            codes += [MPath.MOVETO] + [MPath.LINETO] * (len(xs) - 2) + [MPath.CLOSEPOLY]
        out.append(PathPatch(MPath(verts, codes), **kw))
    return out


def copper(board, side):
    lay = f'{side}.Cu'
    parts = [LineString([s, e]).buffer(w / 2, 8) for l, s, e, w in board.tracks if l == lay]
    parts += [LineString(pts).buffer(w / 2, 8) for l, pts, w in board.arcs if l == lay]
    parts += [z for l, z in board.zones if l == lay]
    parts += [Point(at[0], at[1]).buffer(sz / 2, 12) for at, sz, _ in board.vias]
    return unary_union(parts) if parts else None


def pads(board, side):
    out = []
    for f in board.footprints:
        for p in f.pads:
            if p.on(side) and p.kind != 'np_thru_hole':
                out.append(p.geometry())
    return unary_union(out) if out else None


def silk(board, side):
    lay = f'{side}.SilkS'
    lines = []
    for f in board.footprints:
        for kind, g in f.graphics:
            l, geom, w = f.shape(kind, g)
            if l == lay:
                lines.append(geom if geom.geom_type == 'Polygon' else geom.buffer(max(w, 0.12) / 2, 6))
    return unary_union(lines) if lines else None


def drills(board):
    out = [Point(p.center()).buffer(p.drill / 2, 16) for f in board.footprints for p in f.pads if p.drill]
    out += [Point(at[0], at[1]).buffer(d / 2, 10) for at, _, d in board.vias]
    return unary_union(out) if out else None


def draw(board, side, path, dpi, labels=True, background=None, margin=4.0):
    x0, y0, x1, y1 = board.bounds()
    w, h = x1 - x0 + 2 * margin, y1 - y0 + 2 * margin
    fig = plt.figure(figsize=(w / 25.4, h / 25.4), dpi=dpi)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(x0 - margin, x1 + margin)
    ax.set_ylim(y1 + margin, y0 - margin)  # KiCad Y grows downward
    if side == 'B':
        ax.set_xlim(x1 + margin, x0 - margin)  # look at the back: mirror X
    ax.set_aspect('equal')
    ax.axis('off')
    fig.patch.set_alpha(0 if background is None else 1)
    if background:
        fig.patch.set_facecolor(background)

    for p in geom_patches(board.outline, facecolor=MASK, edgecolor=EDGE, lw=0.6, zorder=1):
        ax.add_patch(p)
    cu = copper(board, side)
    if cu is not None:
        for p in geom_patches(cu.intersection(board.outline), facecolor=MASK_CU, edgecolor='none', zorder=2):
            ax.add_patch(p)
    pd = pads(board, side)
    if pd is not None:
        for p in geom_patches(pd, facecolor=ENIG, edgecolor='none', zorder=3):
            ax.add_patch(p)
    sk = silk(board, side)
    if sk is not None:
        sk = sk.intersection(board.outline)
        if pd is not None:
            sk = sk.difference(pd.buffer(0.1))
        for p in geom_patches(sk, facecolor=SILK, edgecolor='none', zorder=4):
            ax.add_patch(p)
    dr = drills(board)
    if dr is not None:
        for p in geom_patches(dr, facecolor=DRILL, edgecolor='none', zorder=5):
            ax.add_patch(p)

    if labels:
        for f in board.footprints:
            if not f.ref_at or getattr(f, 'ref_hidden', False):
                continue
            (pa, lay, size) = f.ref_at
            if lay != f'{side}.SilkS':
                continue
            tx, ty = f.to_board(pa[0], pa[1])
            ang = pa[2] if len(pa) > 2 else 0
            if side == 'B':
                ang = -ang
            ax.text(tx, ty, f.ref, color=SILK, ha='center', va='center', rotation=ang,
                    fontsize=size * 72 / 25.4 * 0.8, family='DejaVu Sans', zorder=6)
        for txt, at, lay, size in board.texts:
            if lay != f'{side}.SilkS':
                continue
            ang = at[2] if len(at) > 2 else 0
            ax.text(at[0], at[1], txt.replace('\\n', '\n'), color=SILK, ha='center', va='center',
                    rotation=-ang if side == 'B' else ang, fontsize=size * 72 / 25.4 * 0.8,
                    family='DejaVu Sans', weight='bold', zorder=6)

    fig.savefig(path, dpi=dpi, transparent=background is None)
    plt.close(fig)


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(TEX, exist_ok=True)
    for name, path in BOARDS.items():
        b = Board(path)
        for side, tag in (('F', 'top'), ('B', 'bottom')):
            draw(b, side, os.path.join(OUT, f'{name}_{tag}.png'), dpi=220)
            # texture: exact board bounds, no margin, opaque, no text blur
            draw(b, side, os.path.join(TEX, f'{name}_{tag}.png'), dpi=300, margin=0.0, background=MASK)
        print(name, 'footprints', len(b.footprints), 'tracks', len(b.tracks), 'bounds', [round(v, 2) for v in b.bounds()])


if __name__ == '__main__':
    main()
