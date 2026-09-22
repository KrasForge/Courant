#!/usr/bin/env python3
from pathlib import Path
import json, sys
import cadquery as cq

ROOT=Path(__file__).resolve().parents[1]
STACK=json.loads((ROOT/'stack/panel-stack.json').read_text())
sys.path.insert(0,str(ROOT/'panel/source'))
import build_cad as panelcad

MODELS=ROOT/'stack/models'
IPT=cq.importers.importStep(str(MODELS/'Samtec_IPT1-110-06-L-D_drawing_reference.step')).val()
IPS=cq.importers.importStep(str(MODELS/'Samtec_IPS1-110-01-L-D_drawing_reference.step')).val()
GAP=STACK['mating']['fully_mated_gap_mm']

# Simplified main PCB slab using the current mainboard product-space bounds.
mainpcb=cq.Workplane('XY').box(160,100,1.6,centered=(False,False,False)).translate((8,14.25,-1.6)).val()
# Actual panel PCB outline from current panel CAD, shifted so its B-side is at z=GAP.
panelpcb=panelcad.board_shape().translate((0,0,GAP+9.6))

items={'MAIN_PCB':(mainpcb,'#2E5745'),'PANEL_PCB':(panelpcb,'#265944')}
for con in STACK['connectors']:
    x=con['panel_xy_mm']['x']; y=con['panel_xy_mm']['y']; a=con['rotation_deg']
    male=IPT.rotate((0,0,0),(0,0,1),a).translate((x,y,0))
    # Panel connector is B-side: flip about Y then rotate like the footprint.
    female=IPS.rotate((0,0,0),(0,1,0),180).rotate((0,0,0),(0,0,1),a).translate((x,y,GAP))
    items[f"{con['main_ref']}_IPT1"]=(male,'#242424')
    items[f"{con['panel_ref']}_IPS1"]=(female,'#242424')

out=ROOT/'stack/direct_stack_fit_both.png'
panelcad.render(items,out,target=(95,67,10),camera=(290,-175,115),scale=105)
panelcad.export_assy(items,ROOT/'stack/direct_stack_fit_both.step','RADIAN_DIRECT_STACK_EXACT_REFERENCE')

# Pair-A close-up, clipped down to a local board sample for readable mating detail.
con=STACK['connectors'][0]; x=con['panel_xy_mm']['x']; y=con['panel_xy_mm']['y']; a=con['rotation_deg']
main_sample=cq.Workplane('XY').box(28,38,1.6,centered=(True,True,False)).val().translate((x,y,-1.6))
panel_sample=cq.Workplane('XY').box(28,38,1.6,centered=(True,True,False)).val().translate((x,y,GAP))
male=IPT.rotate((0,0,0),(0,0,1),a).translate((x,y,0))
female=IPS.rotate((0,0,0),(0,1,0),180).rotate((0,0,0),(0,0,1),a).translate((x,y,GAP))
close={'MAIN_PCB':(main_sample,'#2E5745'),'PANEL_PCB':(panel_sample,'#265944'),'J17_IPT1':(male,'#242424'),'J100_IPS1':(female,'#242424')}
out2=ROOT/'stack/direct_stack_fit_pair_A.png'
panelcad.render(close,out2,target=(x,y,GAP/2),camera=(x+70,y-80,55),scale=32)
panelcad.export_assy(close,ROOT/'stack/direct_stack_fit_pair_A.step','RADIAN_DIRECT_STACK_PAIR_A')
print(out)
print(out2)
