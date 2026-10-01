"""Minimal reader for the native KiCad 10 .kicad_pcb boards in this repo.

Only what the presentation renders need: board outline (Edge.Cuts), tracks,
vias, filled zones, footprints with their pads, silkscreen/courtyard graphics
and reference designators. Coordinates are KiCad board millimetres (Y down).
"""
import math
import re

from shapely.geometry import LineString, Point, Polygon, box
from shapely.ops import polygonize, unary_union
from shapely import affinity

_TOK = re.compile(r'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()"]+')


def parse_sexpr(text):
    stack, cur = [], []
    for t in _TOK.findall(text):
        if t == '(':
            stack.append(cur)
            cur = []
        elif t == ')':
            done = cur
            cur = stack.pop()
            cur.append(done)
        else:
            cur.append(t[1:-1] if t.startswith('"') else t)
    return cur[0]


def kids(node, name):
    return [c for c in node if isinstance(c, list) and c and c[0] == name]


def kid(node, name):
    k = kids(node, name)
    return k[0] if k else None


def nums(node, name):
    k = kid(node, name)
    return [float(v) for v in k[1:] if not isinstance(v, list)] if k else None


def layer_of(node):
    k = kid(node, 'layer')
    return k[1] if k else None


def arc_points(start, mid, end, n=24):
    (x1, y1), (x2, y2), (x3, y3) = start, mid, end
    d = 2 * (x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2))
    if abs(d) < 1e-12:
        return [start, end]
    ux = ((x1**2 + y1**2) * (y2 - y3) + (x2**2 + y2**2) * (y3 - y1) + (x3**2 + y3**2) * (y1 - y2)) / d
    uy = ((x1**2 + y1**2) * (x3 - x2) + (x2**2 + y2**2) * (x1 - x3) + (x3**2 + y3**2) * (x2 - x1)) / d
    r = math.hypot(x1 - ux, y1 - uy)
    a1, a2, a3 = (math.atan2(y - uy, x - ux) for x, y in (start, mid, end))

    def ccw_span(a, b):
        return (b - a) % (2 * math.pi)

    if ccw_span(a1, a2) <= ccw_span(a1, a3):
        span = ccw_span(a1, a3)
    else:
        span = -ccw_span(a3, a1)
    return [(ux + r * math.cos(a1 + span * i / n), uy + r * math.sin(a1 + span * i / n)) for i in range(n + 1)]


class Footprint:
    def __init__(self, node):
        self.name = node[1]
        self.layer = layer_of(node)
        at = nums(node, 'at')
        self.x, self.y = at[0], at[1]
        self.rot = at[2] if len(at) > 2 else 0.0
        self.ref = ''
        self.value = ''
        self.ref_at = None
        self.props = {}
        for p in kids(node, 'property'):
            self.props[p[1]] = p[2]
            if p[1] == 'Reference':
                self.ref = p[2]
                self.ref_hidden = kid(p, 'hide') is not None and kid(p, 'hide')[1:] == ['yes']
                pa = nums(p, 'at')
                eff = kid(p, 'effects')
                font = kid(eff, 'font') if eff else None
                size = nums(font, 'size') if font else [1, 1]
                self.ref_at = (pa, layer_of(p), size[1] if size else 1)
            if p[1] == 'Value':
                self.value = p[2]
        self.pads = [Pad(self, p) for p in kids(node, 'pad')]
        self.graphics = []
        for kind in ('fp_line', 'fp_rect', 'fp_circle', 'fp_arc', 'fp_poly'):
            for g in kids(node, kind):
                self.graphics.append((kind, g))

    @property
    def back(self):
        return self.layer == 'B.Cu'

    def to_board(self, lx, ly):
        t = math.radians(self.rot)
        c, s = math.cos(t), math.sin(t)
        return (self.x + lx * c + ly * s, self.y - lx * s + ly * c)

    def shape(self, kind, g):
        """Return (layer, shapely geometry, stroke width) in board coords."""
        lay = layer_of(g)
        stroke = kid(g, 'stroke')
        w = nums(stroke, 'width')[0] if stroke and nums(stroke, 'width') else 0.12
        fill = kid(g, 'fill')
        filled = fill is not None and fill[1] in ('yes', 'solid')
        tb = self.to_board
        if kind == 'fp_line':
            geom = LineString([tb(*nums(g, 'start')), tb(*nums(g, 'end'))])
        elif kind == 'fp_rect':
            (x1, y1), (x2, y2) = nums(g, 'start'), nums(g, 'end')
            ring = [tb(x1, y1), tb(x2, y1), tb(x2, y2), tb(x1, y2), tb(x1, y1)]
            geom = Polygon(ring) if filled else LineString(ring)
        elif kind == 'fp_circle':
            cx, cy = nums(g, 'center')
            ex, ey = nums(g, 'end')
            c = Point(tb(cx, cy)).buffer(math.hypot(ex - cx, ey - cy), 32)
            geom = c if filled else c.exterior
        elif kind == 'fp_arc':
            pts = arc_points(nums(g, 'start'), nums(g, 'mid'), nums(g, 'end'))
            geom = LineString([tb(*p) for p in pts])
        else:
            pts = [tb(float(p[1]), float(p[2])) for p in kid(g, 'pts') if p[0] == 'xy']
            geom = Polygon(pts) if len(pts) > 2 else LineString(pts)
            if not filled and len(pts) > 2:
                geom = LineString(pts + [pts[0]])
        return lay, geom, w

    def courtyard(self):
        want = 'B.CrtYd' if self.back else 'F.CrtYd'
        parts = []
        for kind, g in self.graphics:
            lay, geom, _ = self.shape(kind, g)
            if lay == want:
                parts.append(geom)
        if parts:
            u = unary_union(parts)
            polys = list(polygonize(u)) if u.geom_type != 'Polygon' else [u]
            if polys:
                return unary_union(polys).convex_hull
            return u.convex_hull
        pads = [p.geometry() for p in self.pads]
        return unary_union(pads).convex_hull if pads else Point(self.x, self.y).buffer(0.5)


class Pad:
    def __init__(self, fp, node):
        self.fp = fp
        self.number = node[1]
        self.kind = node[2]
        self.shape = node[3]
        at = nums(node, 'at')
        self.lx, self.ly = at[0], at[1]
        self.rot = at[2] if len(at) > 2 else 0.0
        self.size = nums(node, 'size')
        self.layers = kid(node, 'layers')[1:]
        dr = kid(node, 'drill')
        self.drill = None
        if dr:
            vals = [float(v) for v in dr[1:] if not isinstance(v, list) and v != 'oval']
            self.drill = vals[0] if vals else None
        rr = nums(node, 'roundrect_rratio')
        self.rratio = rr[0] if rr else 0.25

    def on(self, side):
        return any(l in (f'{side}.Cu', '*.Cu') for l in self.layers)

    def center(self):
        return self.fp.to_board(self.lx, self.ly)

    def geometry(self):
        w, h = self.size
        if self.shape == 'circle':
            g = Point(0, 0).buffer(w / 2, 24)
        elif self.shape == 'oval':
            r = min(w, h) / 2
            g = LineString([(-(w / 2 - r), 0), (w / 2 - r, 0)] if w >= h else [(0, -(h / 2 - r)), (0, h / 2 - r)]).buffer(r, 16)
        elif self.shape == 'roundrect':
            r = min(w, h) * self.rratio
            g = box(-w / 2 + r, -h / 2 + r, w / 2 - r, h / 2 - r).buffer(r, 8)
        else:
            g = box(-w / 2, -h / 2, w / 2, h / 2)
        # pad rotation in the file is absolute (includes the footprint's)
        g = affinity.rotate(g, -self.rot, origin=(0, 0))
        cx, cy = self.center()
        return affinity.translate(g, cx, cy)


class Board:
    def __init__(self, path):
        self.root = parse_sexpr(open(path, encoding='utf-8').read())
        r = self.root
        self.footprints = [Footprint(f) for f in kids(r, 'footprint')]
        self.tracks = []
        for s in kids(r, 'segment'):
            self.tracks.append((layer_of(s), nums(s, 'start'), nums(s, 'end'), nums(s, 'width')[0]))
        self.arcs = []
        for a in kids(r, 'arc'):
            self.arcs.append((layer_of(a), arc_points(nums(a, 'start'), nums(a, 'mid'), nums(a, 'end')), nums(a, 'width')[0]))
        self.vias = [(nums(v, 'at'), nums(v, 'size')[0], nums(v, 'drill')[0]) for v in kids(r, 'via')]
        self.zones = []
        for z in kids(r, 'zone'):
            for fp in kids(z, 'filled_polygon'):
                pts = [(float(p[1]), float(p[2])) for p in kid(fp, 'pts') if p[0] == 'xy']
                if len(pts) > 2:
                    self.zones.append((layer_of(fp), Polygon(pts).buffer(0)))
        self.gr = []
        for kind in ('gr_line', 'gr_rect', 'gr_circle', 'gr_arc', 'gr_poly'):
            for g in kids(r, kind):
                self.gr.append((kind, g))
        self.texts = []
        for t in kids(r, 'gr_text'):
            at = nums(t, 'at')
            eff = kid(t, 'effects')
            font = kid(eff, 'font') if eff else None
            size = nums(font, 'size') if font else [1.5, 1.5]
            self.texts.append((t[1], at, layer_of(t), size[1]))
        self.outline = self._outline()

    def _edge_lines(self):
        lines = []
        for kind, g in self.gr:
            if layer_of(g) != 'Edge.Cuts':
                continue
            if kind == 'gr_line':
                lines.append(LineString([nums(g, 'start'), nums(g, 'end')]))
            elif kind == 'gr_arc':
                lines.append(LineString(arc_points(nums(g, 'start'), nums(g, 'mid'), nums(g, 'end'))))
            elif kind == 'gr_rect':
                (x1, y1), (x2, y2) = nums(g, 'start'), nums(g, 'end')
                lines.append(LineString([(x1, y1), (x2, y1), (x2, y2), (x1, y2), (x1, y1)]))
            elif kind == 'gr_circle':
                cx, cy = nums(g, 'center')
                ex, ey = nums(g, 'end')
                lines.append(Point(cx, cy).buffer(math.hypot(ex - cx, ey - cy), 48).exterior)
            elif kind == 'gr_poly':
                pts = [(float(p[1]), float(p[2])) for p in kid(g, 'pts') if p[0] == 'xy']
                lines.append(LineString(pts + [pts[0]]))
        return lines

    def _outline(self):
        polys = sorted(polygonize(unary_union(self._edge_lines())), key=lambda p: -p.area)
        outer = polys[0]
        holes = [p for p in polys[1:] if outer.contains(p.representative_point())]
        board = outer
        for h in holes:
            board = board.difference(h)
        # plated / non-plated drill holes go straight through the board
        drills = [Point(p.center()).buffer(p.drill / 2, 24) for f in self.footprints for p in f.pads
                  if p.drill and p.kind in ('thru_hole', 'np_thru_hole') and p.drill > 1.5]
        return board.difference(unary_union(drills)) if drills else board

    def bounds(self):
        return self.outline.bounds
