#!/usr/bin/env python3
"""Engineering previews from the same pad/track graph, not a generative render."""
from pathlib import Path
import json,math,html,textwrap
import shapely
from shapely.geometry import Point,Polygon,LineString
from shapely import affinity
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
import cairosvg,fitz
from design_data import *
from export_ecad import board_shape,pad_shape,sym_pins
E=lambda x:html.escape(str(x))

def geom_path(g):
 if g.is_empty:return ''
 if hasattr(g,'geoms'):return ' '.join(geom_path(a) for a in g.geoms)
 def ring(r):
  pts=list(r.coords);return 'M'+' L'.join(f'{x:.5f},{H-y:.5f}' for x,y in pts)+' Z'
 return ring(g.exterior)+' '+' '.join(ring(r) for r in g.interiors)

def svg_header(view='0 0 220 152',w=2200,h=1520):
 return [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="{view}">', '<style>text{font-family:DejaVu Sans,sans-serif} .mono{font-family:DejaVu Sans Mono,monospace}</style>']
def pcb_svg(side='F'):
 r=json.load(open(ROOT/'design'/'routing.json'));s=svg_header();s.append('<rect width="220" height="152" fill="#edece6"/>')
 s.append('<text x="12" y="9" font-size="3.9" font-weight="bold">RADIAN / PANEL P1</text>')
 s.append(f'<text x="12" y="14" font-size="1.9">{side}.Cu • ENGINEERING DRAFT • 4 layers / 1.6 mm • front-panel coordinates</text>')
 s.append('<g transform="translate(2,12)">')
 s.append(f'<path d="{geom_path(board_shape())}" fill="#244e40" stroke="#122e28" stroke-width=".25" fill-rule="evenodd"/>')
 for t in r['tracks']:
  if t['layer']!=side+'.Cu':continue
  s.append(f'<path d="M{t["a"][0]},{H-t["a"][1]} L{t["b"][0]},{H-t["b"][1]}" stroke="#cca275" stroke-width="{t["width"]}" stroke-linecap="round" fill="none"/>')
 for p in PARTS:
  if p['side']!=side:continue
  bx,by=p['fp']['body'];b=Polygon([(-bx/2,-by/2),(bx/2,-by/2),(bx/2,by/2),(-bx/2,by/2)])
  b=affinity.rotate(b,p['angle']);b=affinity.translate(b,p['x'],p['y'])
  s.append(f'<path d="{geom_path(b)}" fill="#1a2723" fill-opacity=".56" stroke="#b4cdb6" stroke-width=".15"/>')
  # Reference labels match physical placements. Body-based centre shown without fictional silk claims.
  s.append(f'<text x="{p["x"]}" y="{H-p["y"]-by/2-1.2}" font-size="1.2" text-anchor="middle" fill="#f4f2d8">{E(p["ref"])}</text>')
 for p in allpads():
  if p['kind']=='smd' and p['side']!=side:continue
  if p['kind']=='np_thru_hole':continue
  g=pad_shape(p);s.append(f'<path d="{geom_path(g)}" fill="#d9c386" stroke="#1e3d30" stroke-width=".08"/>')
  if p['drill'] is not None:
   pp=dict(p)
   if isinstance(p['drill'],list):pp.update(sx=p['drill'][0],sy=p['drill'][1],shape='oval')
   else:pp.update(sx=p['drill'],sy=p['drill'],shape='circle')
   s.append(f'<path d="{geom_path(pad_shape(pp))}" fill="#131a17"/>')
 for v in r['vias']:
  s.append(f'<circle cx="{v["x"]}" cy="{H-v["y"]}" r="{v["size"]/2}" fill="#d5c792"/><circle cx="{v["x"]}" cy="{H-v["y"]}" r="{v["drill"]/2}" fill="#18261e"/>')
 s.append('<text x="85" y="87" text-anchor="middle" font-size="2.2" fill="#314f42">DIN / CRADLE WINDOW</text>')
 s.append('<text x="133" y="87" text-anchor="middle" font-size="1.8" fill="#314f42">VENT</text>')
 for txt,x,y in [('PITCH',42,86),('DECAY',80,86),('TIMBRE',118,86)]:
  if side=='F':s.append(f'<text x="{x}" y="{H-y}" font-size="1.15" fill="#cad5c4" text-anchor="middle">{txt}</text>')
 s.append('</g>')
 s.append('<text x="12" y="143" font-size="1.9" font-weight="bold">NATIVE KiCad ERC / DRC / GND refill + physical fit + power tests remain mandatory.</text>')
 s.append('<text x="12" y="148" font-size="1.65">This view is generated from the actual draft pad and routed-track geometry. It is not a fabrication approval.</text>')
 s.append('</svg>');txt='\n'.join(s);path=ROOT/'previews'/f'pcb_{side}.svg';path.write_text(txt);cairosvg.svg2png(bytestring=txt.encode(),write_to=str(path.with_suffix('.png')))

# PDF pages intentionally mirror the explicit native net-labelled schematic.
def schematic_pdf():
 fonts=Path('/usr/share/fonts/truetype/dejavu')
 pdfmetrics.registerFont(TTFont('DV',str(fonts/'DejaVuSans.ttf')))
 pdfmetrics.registerFont(TTFont('DVB',str(fonts/'DejaVuSans-Bold.ttf')))
 sf=72/25.4;c=canvas.Canvas(str(ROOT/'docs'/'RADIAN_Panel_P1_schematic.pdf'),pagesize=(594*sf,420*sf));c.setTitle('RADIAN Panel P1 — electrical schematic review')
 layout=json.load(open(ROOT/'design'/'schematic_layout.json'))
 def text(t,x,y,sz=1.5,font='DV',col='#283b35',align='left'):
  c.setFillColor(HexColor(col));c.setFont(font,sz*sf)
  fn={'left':c.drawString,'right':c.drawRightString,'center':c.drawCentredString}[align];fn(x*sf,(420-y)*sf,t)
 def line(x1,y1,x2,y2,col='#416b55',width=.18):
  c.setStrokeColor(HexColor(col));c.setLineWidth(width*sf);c.line(x1*sf,(420-y1)*sf,x2*sf,(420-y2)*sf)
 for b in ['power','controls','io','mod','service']:
  text('RADIAN / PANEL P1',20,20,4.,'DVB');text(layout['titles'][b],20,31,2.5,'DVB')
  text('Exact pin/net graph • named nets connect across sheets • generated review drawing, not a native KiCad plot',20,40,1.7)
  pp=[p for p in PARTS if p['block']==b]
  for p in pp:
   loc=layout['parts'][p['ref']];x=loc['x'];y=loc['y'];ht=loc['height'];pins=loc['pins']
   passive=len(pins)<=2 and p['ref'].startswith(('R','C','D','L','F','TP'))
   text(p['ref'],x,y-ht-4,2.,'DVB',align='center')
   if passive:
    if p['ref'].startswith('C'):
     line(x-.9,y-2.5,x-.9,y+2.5,'#604b42',.35);line(x+.9,y-2.5,x+.9,y+2.5,'#604b42',.35)
     line(x-10.16,y,x-.9,y);line(x+.9,y,x+10.16,y)
    else:
     c.setStrokeColor(HexColor('#604b42'));c.setLineWidth(.25*sf);c.rect((x-3.81)*sf,(420-y-1.52)*sf,7.62*sf,3.04*sf)
     line(x-10.16,y,x-3.81,y);line(x+3.81,y,x+10.16,y)
     if p['ref'].startswith('D'):line(x-2.54,y-1.52,x-2.54,y+1.52,'#604b42',.4)
   else:
    c.setFillColor(HexColor('#f4f2e9'));c.setStrokeColor(HexColor('#604b42'));c.setLineWidth(.25*sf);c.rect((x-10.16)*sf,(420-y-ht)*sf,20.32*sf,2*ht*sf,fill=1)
   for pin in pins:
    xx=x+pin['x'];yy=y-pin['y'];sgn=-1 if pin['x']<0 else 1;end=xx+sgn*5.08;net=p['nets'].get(pin['n'])
    if not passive:
     line(xx,yy,x+sgn*10.16,yy,'#604b42');text(pin['name'],x+sgn*9.2,yy+.35,1.0,align='left' if sgn<0 else 'right');text(pin['n'],xx-sgn*.6,yy-.65,.85,align='center')
    if net:
     line(xx,yy,end,yy)
     text(net,end+sgn*1.,yy+.5,1.18,col='#245b42',align='right' if sgn<0 else 'left')
    else:line(xx-1,yy-1,xx+1,yy+1,'#a34d42');line(xx-1,yy+1,xx+1,yy-1,'#a34d42')
   text(p['value'],x,y+ht+4,1.35,align='center')
  for i,note in enumerate(layout['warnings'][b]):text(note,20,365+i*8,1.65)
  line(20,401,574,401,'#9bafa3',.25);text('ENGINEERING DRAFT — NOT FOR FABRICATION',20,409,1.8,'DVB',col='#874b40');text(b.upper(),574,409,1.5,align='right')
  c.showPage()
 c.save()
 doc=fitz.open(ROOT/'docs'/'RADIAN_Panel_P1_schematic.pdf')
 for idx in [0,1,3]:doc[idx].get_pixmap(matrix=fitz.Matrix(.85,.85)).save(str(ROOT/'previews'/f'schematic_{idx+1}.png'))

def drilling_dxf():
 # Plain ASCII DXF, mm. Projection uses panel's +Y-up CAD axes.
 rows=['0','SECTION','2','HEADER','9','$INSUNITS','70','4','0','ENDSEC','0','SECTION','2','ENTITIES']
 def line(a,b,layer):rows.extend(['0','LINE','8',layer,'10',str(a[0]),'20',str(a[1]),'30','0','11',str(b[0]),'21',str(b[1]),'31','0'])
 for poly in [OUTLINE]+WINDOWS:
  for a,b in zip(poly,poly[1:]+poly[:1]):line(a,b,'BOARD_EDGE')
 for x,y,d in MOUNTS:rows.extend(['0','CIRCLE','8','MOUNT_NPTH','10',str(x),'20',str(y),'30','0','40',str(d/2)])
 # PCB hole centres/major dimensions listed separately to avoid pretending slots are circles.
 for p in allpads():
  if p['drill'] is None:continue
  if isinstance(p['drill'],list):
   line((p['X']-.5,p['Y']),(p['X']+.5,p['Y']),'SLOT_CENTRE');line((p['X'],p['Y']-.5),(p['X'],p['Y']+.5),'SLOT_CENTRE')
  else:rows.extend(['0','CIRCLE','8','COMPONENT_DRILL','10',str(p['X']),'20',str(p['Y']),'30','0','40',str(p['drill']/2)])
 rows.extend(['0','ENDSEC','0','EOF']);(ROOT/'cad'/'RADIAN_panel_P1_outline_reference.dxf').write_text('\n'.join(rows)+'\n')
 with (ROOT/'docs'/'drill_reference.csv').open('w',newline='') as f:
  w=csv.writer(f);w.writerow(['Reference','Pin','X_panel_mm','Y_panel_mm','Drill_mm_or_slot_xy','Type'])
  for p in allpads():
   if p['drill'] is not None:w.writerow([p['ref'],p['n'],p['X'],p['Y'],p['drill'],p['kind']])
if __name__=='__main__':
 pcb_svg('F');pcb_svg('B');schematic_pdf();drilling_dxf();print('Review previews/PDF/DXF written.')
