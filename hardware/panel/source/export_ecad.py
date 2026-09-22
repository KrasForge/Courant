#!/usr/bin/env python3
"""Self-contained KiCad 10 PCB + KiCad 8+ schematic writer from design_data.
No native KiCad process is invoked. Run native ERC/DRC before fabrication.
"""
from __future__ import annotations
import json, math, re, sys, collections, copy
from pathlib import Path
if __name__ == "__main__" and (Path(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
 raise SystemExit("Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.")
from design_data import *
import shapely
from shapely.geometry import Polygon, Point, LineString, box
from shapely import affinity

BROOT=uid('root')
BLOCKS=['power','controls','io','mod','service']
TITLES={'power':'01 | POWER INPUTS AND 5 V CONVERTER','controls':'02 | FRONT-PANEL CONTROLS','io':'03 | PATCH JACKS AND MIDI','mod':'04 | OPTIONAL BIPOLAR MODULATION','service':'05 | INTERNAL SERVICE ACCESS'}
Q=lambda x:json.dumps(str(x),ensure_ascii=False)
f=lambda v:f'{v:.6f}'.rstrip('0').rstrip('.') if isinstance(v,(int,float)) else str(v)
def xy(x,y):return f'(xy {f(x)} {f(H-y)})'
def ppcb(x,y):return f'{f(x)} {f(H-y)}'
def pcb_path(block):return '/'+BROOT+'/'+uid('sheet:'+block)
def pad_shape(p):
 x,y=p['X'],p['Y'];sx,sy=p['sx'],p['sy']
 if p['shape']=='circle': q=Point(0,0).buffer(sx/2,quad_segs=12)
 elif p['shape']=='oval':
  r=min(sx,sy)/2
  q=LineString([(-(sx/2-r),-(sy/2-r)),((sx/2-r),(sy/2-r))]).buffer(r,quad_segs=12)
 else:q=box(-sx/2,-sy/2,sx/2,sy/2)
 q=affinity.rotate(q,p.get('angle',0),origin=(0,0));return affinity.translate(q,x,y)
def board_shape():
 q=Polygon(OUTLINE,WINDOWS)
 for x,y,d in MOUNTS:q=q.difference(Point(x,y).buffer(d/2,quad_segs=16))
 for p in allpads():
  if p['kind']=='np_thru_hole':q=q.difference(Point(p['X'],p['Y']).buffer(float(p['drill'])/2,quad_segs=16))
 return q

def fptext(s,x,y,side,layer='SilkS',size=1.,hide=False):
 return f'(fp_text user {Q(s)} (at {f(x)} {f(y)}) (layer "{side}.{layer}"){(" hide" if hide else "")} (effects (font (size {size} {size}) (thickness 0.15)){(" (justify mirror)" if side=="B" else "")}))'

def footprint(p,lib=False):
 side='F' if lib else p['side'];libname=p['fp']['name'];ref='REF**' if lib else p['ref']
 name=libname if lib else 'RadianPanel:'+libname
 a=0 if lib else p['angle'];xx=0 if lib else p['x'];yy=0 if lib else H-p['y']
 mir=-1 if side=='B' else 1
 b=p['fp']['body'];pieces=[f'(footprint {Q(name)} (layer "{side}.Cu") (uuid {Q(uid("footprint:"+ref))})']
 if lib:pieces.append('(version 20260206) (generator "radian_panel_generator")')
 if not lib:pieces.append(f'(at {f(xx)} {f(yy)} {f(a)})')
 pieces.append(f'(property "Reference" {Q(ref)} (at 0 {f(-b[1]/2-1.5)} {f(a)}) (layer "{side}.SilkS") (effects (font (size 1 1) (thickness 0.15)){(" (justify mirror)" if side=="B" else "")}))')
 for nm,va in [('Value',p['value']),('Manufacturer',p['maker']),('MPN',p['mpn']),('Description',p['notes'])]:
  pieces.append(f'(property {Q(nm)} {Q(va)} (at 0 0 {f(a)}) (layer "{side}.Fab") (hide yes) (effects (font (size 1 1) (thickness 0.15))))')
 if not lib:
  pieces.append(f'(path {Q(pcb_path(p["block"])+"/"+p["uuid"])})')
  if p['dnp']:pieces.append('(attr smd dnp)')
 pieces.append(f'(fp_rect (start {f(-b[0]/2)} {f(-b[1]/2)}) (end {f(b[0]/2)} {f(b[1]/2)}) (stroke (width 0.1) (type default)) (fill none) (layer "{side}.Fab"))')
 # Courtyard includes the part envelope and all pad extents.
 ps=p['fp']['pads'];xmax=max([b[0]/2]+[abs(s['x'])+s['sx']/2 for s in ps])+.25;ymax=max([b[1]/2]+[abs(s['y'])+s['sy']/2 for s in ps])+.25
 pieces.append(f'(fp_rect (start {f(-xmax)} {f(-ymax)}) (end {f(xmax)} {f(ymax)}) (stroke (width 0.05) (type default)) (fill none) (layer "{side}.CrtYd"))')
 # Short corner ticks, rather than outlines crossing large through-hole pads.
 for ax,ay,dx,dy in [(-b[0]/2,-b[1]/2,1,0),(b[0]/2,b[1]/2,-1,0)]:
  pieces.append(f'(fp_line (start {f(ax)} {f(ay)}) (end {f(ax+dx*.6)} {f(ay+dy*.6)}) (stroke (width 0.15) (type default)) (layer "{side}.SilkS"))')
 for i,s in enumerate(ps):
  n=s['n'];sx,sy=s['sx'],s['sy'];lx=s['x']*mir;ly=-s['y'];kind=s['kind'];shape=s['shape']
  t=[f'(pad {Q(n)} {kind} {shape} (at {f(lx)} {f(ly)} {f(a)}) (size {f(sx)} {f(sy)})']
  if s['drill'] is not None:
   if isinstance(s['drill'],list):t.append(f'(drill oval {f(s["drill"][0])} {f(s["drill"][1])})')
   else:t.append(f'(drill {f(s["drill"])})')
  if kind=='smd':t.append(f'(layers "{side}.Cu" "{side}.Paste" "{side}.Mask")')
  else:t.append('(layers "*.Cu" "*.Mask")')
  if shape=='roundrect':t.append('(roundrect_rratio 0.20)')
  if not lib and p['nets'].get(n):t.append(f'(net {Q(p["nets"][n])})')
  if kind!='np_thru_hole':t.append('(clearance 0.2)')
  t.append(f'(uuid {Q(uid("pad:"+ref+":"+n+":"+str(i)))})');t.append(')');pieces.append(' '.join(t))
 # Stable local 3D model: one individual reference model per footprint family.
 if not lib:pieces.append(f'(model "${{KIPRJMOD}}/../cad/models/{libname}.step" (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0)))')
 pieces.append(')');return '\n'.join(pieces)

def write_pcb(tracks=None,vias=None):
 if (ROOT/"NATIVE_BASELINE.json").exists():raise RuntimeError('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')
 tracks=tracks or [];vias=vias or []
 h=['(kicad_pcb (version 20260206) (generator "radian_panel_generator") (generator_version "P1")', '(general (thickness 1.6)) (paper "A3")',
 '(layers (0 "F.Cu" signal) (4 "In1.Cu" signal) (6 "In2.Cu" signal) (2 "B.Cu" signal) (13 "F.Paste" user) (15 "B.Paste" user) (5 "F.SilkS" user) (7 "B.SilkS" user) (1 "F.Mask" user) (3 "B.Mask" user) (17 "Dwgs.User" user) (19 "Cmts.User" user) (25 "Edge.Cuts" user) (31 "F.CrtYd" user) (29 "B.CrtYd" user) (35 "F.Fab" user) (33 "B.Fab" user))',
 '(setup (pad_to_mask_clearance 0.05))',
 '(title_block (title "RADIAN Panel / Interface PCB") (date "2026-09-15") (rev "P1 DRAFT") (comment 1 "NOT FOR FABRICATION: footprint / power / thermal / physical validation outstanding"))']
 for poly in [OUTLINE]+WINDOWS:
  for i,(a,b) in enumerate(zip(poly,poly[1:]+poly[:1])):
   h.append(f'(gr_line (start {ppcb(*a)}) (end {ppcb(*b)}) (stroke (width 0.05) (type default)) (layer "Edge.Cuts") (uuid {Q(uid("edge:"+str(a)+str(b)))}) )')
 for i,(x,y,d) in enumerate(MOUNTS):
  h.append(f'(footprint "RadianPanel:Mount_NPTH" (layer "F.Cu") (at {ppcb(x,y)}) (uuid {Q(uid("mount"+str(i)))}) (attr board_only exclude_from_pos_files exclude_from_bom) (pad "" np_thru_hole circle (at 0 0) (size {d} {d}) (drill {d}) (layers "*.Cu" "*.Mask")))')
 for p in PARTS:h.append(footprint(p))
 for i,t in enumerate(tracks):
  h.append(f'(segment (start {ppcb(*t["a"])}) (end {ppcb(*t["b"])}) (width {t["width"]}) (layer {Q(t["layer"])}) (net {Q(t["net"])}) (uuid {Q(uid("track:"+str(i)))}) )')
 for i,v in enumerate(vias):
  h.append(f'(via (at {ppcb(v["x"],v["y"])}) (size {v.get("size",.7)}) (drill {v.get("drill",.3)}) (layers "F.Cu" "B.Cu") (net {Q(v["net"])}) (uuid {Q(uid("via:"+str(i)))}) )')
 # Plane fills intentionally left to KiCad; explicit status, not fake connectivity.
 for la in ['In1.Cu','In2.Cu']:
  pts=' '.join(xy(x,y) for x,y in OUTLINE)
  h.append(f'(zone (net "GND") (layer {Q(la)}) (uuid {Q(uid("plane"+la))}) (hatch edge 0.5) (connect_pads yes (clearance 0.25)) (min_thickness 0.2) (fill yes (thermal_gap 0.35) (thermal_bridge_width 0.4)) (polygon (pts {pts})))')
 for txt,x,y,sz in [('RADIAN / PANEL P1',75,116,1.4),('DRAFT - NOT FABRICATION RELEASE',75,12,1.0),('12 V DESKTOP / RACK +12 ONLY',47,69,1.),('MOD SHUNT: 1-2 UNI / 2-3 BI',157,91, .9),('LINE OUTPUTS - NOT HEADPHONES',171,12.8,.85)]:
  h.append(f'(gr_text {Q(txt)} (at {ppcb(x,y)}) (layer "B.SilkS") (effects (font (size {sz} {sz}) (thickness 0.15)) (justify mirror)) (uuid {Q(uid(txt))}))')
 h.append(')');(ROOT/'design'/'radian_panel.kicad_pcb').write_text('\n'.join(h))
 # library footprint definitions are all FRONT oriented; board instances handle side.
 seen=set()
 for p in PARTS:
  nm=p['fp']['name']
  if nm not in seen:(ROOT/'library'/'RadianPanel.pretty'/(nm+'.kicad_mod')).write_text(footprint(p,True));seen.add(nm)
 (ROOT/'design'/'fp-lib-table').write_text('(fp_lib_table (version 7) (lib (name "RadianPanel") (type "KiCad") (uri "${KIPRJMOD}/../library/RadianPanel.pretty") (options "") (descr "Project-local draft footprints; check against actual components")))\n')
 project={"meta":{"filename":"radian_panel.kicad_pro","version":1},"board":{"design_settings":{"rules":{"min_clearance":.2,"min_track_width":.2,"min_via_diameter":.6,"min_through_hole_diameter":.3,"min_hole_to_hole":.25,"min_copper_edge_clearance":.3},"defaults":{"track_width":.25}}},"net_settings":{"classes":[{"name":"Default","clearance":.2,"track_width":.25,"via_diameter":.7,"via_drill":.3},{"name":"Power","clearance":.2,"track_width":1.5,"via_diameter":.9,"via_drill":.4}],"netclass_patterns":[{"netclass":"Power","pattern":n} for n in ['VIN5','VRAW','RACK_12V','DESKTOP_12V','RACK_FUSED','DESKTOP_FUSED']],"meta":{"version":3}},"libraries":{"pinned_footprint_libs":["RadianPanel"],"pinned_symbol_libs":["RadianPanel"]}}
 (ROOT/'design'/'radian_panel.kicad_pro').write_text(json.dumps(project,indent=2))

# Schematic symbol definitions: exact pin-labelled graphs, no reliance on installed libraries.
def sym_pins(p):
 nums=list(dict.fromkeys(q['n'] for q in p['fp']['pads'] if q['n']))
 names={q['n']:q.get('name',q['n']) for q in p['fp']['pads']}
 is_pass=p['ref'].startswith(('R','C','L','F','D','TP')) and len(nums)<=2
 if is_pass:
  return [dict(n=n,name=names[n],x=(-10.16 if i==0 else 10.16),y=0,a=(0 if i==0 else 180),etype='passive') for i,n in enumerate(nums)]
 # Split into two banks for complex parts; connectors on one bank to show pin sequence.
 split=(len(nums)+1)//2 if not p['ref'].startswith('J') else len(nums)
 left=nums[:split];right=nums[split:];pins=[]
 for bank,sgn in [(left,-1),(right,1)]:
  for j,n in enumerate(bank):
   et='passive'
   if p['ref']=='U1':et={'1':'power_in','2':'output','3':'power_in','4':'input','5':'input','6':'passive'}[n]
   if p['ref']=='U2':et={'1':'output','2':'input','3':'input','4':'power_in','5':'input','6':'input','7':'output','8':'power_in'}[n]
   pins.append(dict(n=n,name=names[n],x=sgn*12.7,y=((len(bank)-1)/2-j)*2.54,a=0 if sgn==-1 else 180,etype=et))
 return pins

def symbol_definition(p,name):
 pins=sym_pins(p);ys=[abs(x['y']) for x in pins];ht=max(5.08,max(ys,default=0)+2.54)
 passive=len(pins)<=2 and p['ref'].startswith(('R','C','D','L','F','TP'))
 g=[]
 if passive and p['ref'].startswith('C'):
  for x in [-.9,.9]:g.append(f'(polyline (pts (xy {x} -2.54) (xy {x} 2.54)) (stroke (width 0.254) (type default)) (fill (type none)))')
  for a,b in [(-7.62,-.9),(.9,7.62)]:g.append(f'(polyline (pts (xy {a} 0) (xy {b} 0)) (stroke (width 0.15) (type default)) (fill (type none)))')
 elif passive and not p['ref'].startswith('TP'):
  g.append('(rectangle (start -3.81 1.52) (end 3.81 -1.52) (stroke (width 0.2) (type default)) (fill (type none)))')
  for a,b in [(-7.62,-3.81),(3.81,7.62)]:g.append(f'(polyline (pts (xy {a} 0) (xy {b} 0)) (stroke (width 0.15) (type default)) (fill (type none)))')
  if p['ref'].startswith('D'):g.append('(polyline (pts (xy -2.54 -1.52) (xy -2.54 1.52)) (stroke (width 0.3) (type default)) (fill (type none)))')
 elif passive:g.append('(circle (center 0 0) (radius 1) (stroke (width 0.15) (type default)) (fill (type none)))')
 else:g.append(f'(rectangle (start -10.16 {ht}) (end 10.16 {-ht}) (stroke (width 0.254) (type default)) (fill (type background)))')
 pinstring=[]
 for pin in pins:
  pinstring.append(f'(pin {pin["etype"]} line (at {pin["x"]} {pin["y"]} {pin["a"]}) (length 2.54) (name {Q(pin["name"])} (effects (font (size 1.0 1.0)))) (number {Q(pin["n"])} (effects (font (size 1.0 1.0)))))')
 return f'(symbol {Q(name)} (pin_names (offset 0.508)) (in_bom yes) (on_board yes) (property "Reference" {Q(re.sub("[0-9]", "",p["ref"]))} (at 0 {ht+2.54} 0) (effects (font (size 1.27 1.27)))) (property "Value" {Q(p["value"])} (at 0 {-ht-2.54} 0) (effects (font (size 1.27 1.27)))) (property "Footprint" {Q("RadianPanel:"+p["fp"]["name"])} (at 0 0 0) (effects (font (size 1.27 1.27)) hide)) (symbol {Q(name.split(":")[-1]+"_0_1")} {" ".join(g)}) (symbol {Q(name.split(":")[-1]+"_1_1")} {" ".join(pinstring)}))'

def scheme_header(title,uuid):
 return f'(kicad_sch (version 20231120) (generator "radian_panel_generator") (uuid {Q(uuid)}) (paper "A2") (title_block (title {Q(title)}) (date "2026-09-15") (rev "P1 DRAFT") (comment 1 "Native ERC, footprint verification and hardware testing REQUIRED"))'
def schtext(text,x,y,size=1.5):
 return f'(text {Q(text)} (at {f(x)} {f(y)} 0) (effects (font (size {size} {size})) (justify left top)) (uuid {Q(uid("text:"+text+str((x,y))))}))'
def write_schematic():
 if (ROOT/"NATIVE_BASELINE.json").exists():raise RuntimeError('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')
 locations={};symdefs=[]
 # Exact graph is shown with one unique symbol per designator; reusable footprint families.
 for p in PARTS:symdefs.append(symbol_definition(p,p['ref']))
 (ROOT/'library'/'RadianPanel.kicad_sym').write_text('(kicad_symbol_lib (version 20231120) (generator "radian_panel_generator")\n'+'\n'.join(symdefs)+'\n)')
 (ROOT/'design'/'sym-lib-table').write_text('(sym_lib_table (version 7) (lib (name "RadianPanel") (type "KiCad") (uri "${KIPRJMOD}/../library/RadianPanel.kicad_sym") (options "") (descr "Embedded exact pin graph for RADIAN Panel P1")))\n')
 warnings={
 'power':['12 V desktop supply replaces the earlier direct 5 V proposal. J100/J17 is the regulated 5 V direct-stack feed to the mainboard.','Diode OR prevents positive-rail backfeed; shared GND is not galvanic isolation. Unused rack pins are NC.','TPS54302 3 A rating is NOT a measured system current rating. Fuse selection / inrush / TVS / thermal review required.','Native plane refill and DRC required. 5.08 V nominal TI feedback values; never connect +12 V to main J1.'],
 'controls':['No additional pot wiper RC or LED series resistors: these are already on the RADIAN mainboard.','RV physical pin 1 = CCW/GND; physical pin 3 = CW/VREF25. This is not the main header pin order.','Encoder part changes to 20 mm shaft / 7 mm bushing. Match knob heights and verify turn direction.','SW1 logic mapping depends on installed orientation and firmware. Mechanical tab pins are intentionally NC.'],
 'io':['Pitch and Gate follow the existing mainboard front ends. LINE L/R are NOT new modular-level or headphone drivers.','WQP518MA: 1=SLEEVE, 2=NORMAL, 3=TIP. Inputs normal to ground; output normal pins intentionally NC.','MIDI uses exact Molex 22-27-2021 J306 to a short two-wire lead into the enclosure-mounted Same Sky SDS-50J. Keep DIN pin 2/shield isolated from board GND.','Input overvoltage, unpowered behavior, jack insertion shorts and output back-drive still need bench validation.'],
 'mod':['JP1 is Wurth 450301014042 SPDT: pin 1 common to pin 3 selects direct unipolar MOD_RAW.','Pin 1 common to pin 2 selects MOD_BIPOLAR. Ideal Vout = 0.5*Vin + VREF25. -5/0/+5 V -> 0/2.5/5 V.','5 V op-amp cannot reach exact rails under load. Endpoints, tolerance, saturation and calibration need testing.','Do not rescale the PITCH input implicitly. Bipolar MOD requires a matching firmware range/zero configuration.'],
 'service':['Internal-only JTAG, PROGRAM and RESET. J202 is exact Molex 22-27-2061; no additional exterior cutouts assumed.','Keep programming cables short and verify the actual programmer pinout. No level shifting is added.']}
 for bi,bl in enumerate(BLOCKS):
  pp=[p for p in PARTS if p['block']==bl];defs=[symbol_definition(p,'RadianPanel:'+p['ref']) for p in pp]
  doc=[scheme_header(TITLES[bl],uid('document:'+bl)),'(lib_symbols '+'\n'.join(defs)+')',schtext(TITLES[bl],20,20,3),schtext('RADIAN PANEL P1 | NET-LABELLED ELECTRICAL SCHEMATIC',20,30,1.5)]
  # Four columns leave room for long net names without wire ambiguity.
  cols=4;rows=math.ceil(len(pp)/cols);rowh=min(64.,290/max(1,rows));starty=72.
  for k,p in enumerate(pp):
   x=round((79+(k%cols)*141)/1.27)*1.27;y=round((starty+(k//cols)*rowh)/1.27)*1.27
   pins=sym_pins(p);ht=max(5.08,max((abs(q['y']) for q in pins),default=0)+2.54)
   # Large 16-pin rack connector gets extra body height, enough within 64mm cell.
   locations[p['ref']]={'sheet':bl,'x':x,'y':y,'height':ht,'pins':pins}
   doc.append(f'(symbol (lib_id {Q("RadianPanel:"+p["ref"])}) (at {f(x)} {f(y)} 0) (unit 1) (in_bom yes) (on_board yes) (dnp {"yes" if p["dnp"] else "no"}) (uuid {Q(p["uuid"])}) (property "Reference" {Q(p["ref"])} (at {f(x)} {f(y-ht-4)} 0) (effects (font (size 1.6 1.6)))) (property "Value" {Q(p["value"])} (at {f(x)} {f(y+ht+4)} 0) (effects (font (size 1.05 1.05)))) (property "Footprint" {Q("RadianPanel:"+p["fp"]["name"])} (at {f(x)} {f(y)} 0) (effects (font (size 1.0 1.0)) hide)) (property "MPN" {Q(p["mpn"])} (at {f(x)} {f(y)} 0) (effects (font (size 1 1)) hide)) '+ ' '.join(f'(pin {Q(pin["n"])} (uuid {Q(uid("schpin"+p["ref"]+pin["n"]))}))' for pin in pins)+ f' (instances (project "radian_panel" (path {Q(pcb_path(bl))} (reference {Q(p["ref"])}) (unit 1)))))')
   for pin in pins:
    xx=x+pin['x'];yy=y-pin['y'];net=p['nets'].get(pin['n']);sgn=-1 if pin['x']<0 else 1;ox=xx+sgn*5.08
    if net:
     doc.append(f'(wire (pts (xy {f(xx)} {f(yy)}) (xy {f(ox)} {f(yy)})) (stroke (width 0) (type default)) (uuid {Q(uid("wire:"+p["ref"]+pin["n"]))}))')
     doc.append(f'(global_label {Q(net)} (shape bidirectional) (at {f(ox)} {f(yy)} {0 if sgn<0 else 180}) (effects (font (size 1.0 1.0)) (justify right)) (uuid {Q(uid("label:"+p["ref"]+pin["n"]))}))')
    else:doc.append(f'(no_connect (at {f(xx)} {f(yy)}) (uuid {Q(uid("nc:"+p["ref"]+pin["n"]))}))')
  for i,note in enumerate(warnings[bl]):doc.append(schtext(note,20,365+i*8,1.35))
  doc.append(')');(ROOT/'design'/(bl+'.kicad_sch')).write_text('\n'.join(doc))
 root=[scheme_header('RADIAN | SINGLE PANEL / INTERFACE PCB',BROOT),'(lib_symbols)',schtext('RADIAN / PANEL P1',30,25,5),schtext('One custom front-panel PCB with direct Samtec stack to the revised FPGA mainboard. 40 HP / 3U + removable desktop dock.',30,38,2)]
 for i,bl in enumerate(BLOCKS):
  x=30+(i%2)*265;y=65+(i//2)*75
  root.append(f'(sheet (at {x} {y}) (size 235 50) (stroke (width 0.3) (type default)) (fill (color 0 0 0 0)) (uuid {Q(uid("sheet:"+bl))}) (property "Sheetname" {Q(TITLES[bl])} (at {x} {y-2} 0) (effects (font (size 2 2)) (justify left bottom))) (property "Sheetfile" {Q(bl+".kicad_sch")} (at {x} {y+52} 0) (effects (font (size 1.5 1.5)) (justify left top))) (instances (project "radian_panel" (path {Q("/"+BROOT)} (page {Q(str(i+2))})))))')
 root.extend([schtext('ENGINEERING DRAFT: not a fabrication release. Consult the latest native ERC/DRC reports.',30,320,2),schtext('Default build: unipolar PITCH and MOD; JP1 is a real SPDT selector; line-level outputs; 12 V desktop / rack +12 V to onboard 5 V conversion.',30,337,1.65),schtext('SDS-50J MIDI and Switchcraft 722A desktop inlet are the intentional chassis endpoints, each on a short harness. No extra custom carrier PCB is required.',30,350,1.65),schtext('See ../docs/README.md for explicit unverified items and the bring-up procedure.',30,363,1.65),'(sheet_instances (path "/" (page "1")))',')'])
 (ROOT/'design'/'radian_panel.kicad_sch').write_text('\n'.join(root))
 (ROOT/'design'/'schematic_layout.json').write_text(json.dumps({'parts':locations,'warnings':warnings,'titles':TITLES},indent=2))
 # Reconcile generated fields, connection grid and explicit ERC power sources.
 from native_cleanup import fix_schematics
 fix_schematics(ROOT,metadata={p['ref']:{'Description':p['notes'],'Manufacturer':p['maker']} for p in PARTS})

def sexp_parse(text):
 tokens=re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+',text)
 stack=[];root=None
 for tok in tokens:
  if tok=='(':
   node=[]
   if stack:stack[-1].append(node)
   else:
    if root is not None:raise ValueError('multiple roots')
    root=node
   stack.append(node)
  elif tok==')':
   if not stack:raise ValueError('extra close')
   stack.pop()
  else:
   if not stack:raise ValueError('atom outside root')
   stack[-1].append(json.loads(tok) if tok.startswith('"') else tok)
 if stack:raise ValueError('unclosed expression')
 return root

def main():
 save();write_schematic();write_pcb()
 checks={}
 for p in (ROOT/'design').glob('*.kicad_*'):
  if p.suffix=='.kicad_pro':json.loads(p.read_text());checks[p.name]='valid JSON';continue
  x=sexp_parse(p.read_text());checks[p.name]={'balanced_and_tokenized':True,'root':x[0]}
 (ROOT/'reports'/'syntax.json').write_text(json.dumps(checks,indent=2));print('ECAD written',len(PARTS),'parts')
if __name__=='__main__':main()
