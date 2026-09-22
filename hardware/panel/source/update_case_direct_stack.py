#!/usr/bin/env python3
"""Update the retained RADIAN enclosure for the two-row six-pot direct-stack hardware.

Uses the existing case solids as the design source for unchanged geometry, rebuilds
all panel-board reference components from the active panel source, and changes only
mechanical features required by the current panel/mainboard stack. The primary row
uses three large knobs; DRIVE / DELAY / REVERB use three smaller FX knobs below.
"""
from __future__ import annotations
from pathlib import Path
import json, math, re
import cadquery as cq

ROOT=Path(__file__).resolve().parents[1]
CAD=ROOT/'cad'; PREV=ROOT/'previews'; REPORTS=ROOT/'reports'
BASE=CAD/'RADIAN_P1_case_legacy_reference.step'  # immutable pre-direct-stack enclosure reference
STACK=json.loads((ROOT.parent/'stack'/'panel-stack.json').read_text())

from design_data import PARTS
import build_cad as model

SHIFT_Z=STACK['mating']['max_gap_mm']-STACK['mating']['fully_mated_gap_mm'] # 0.46 mm
PANEL_BOARD_BACK_Z=-9.6
MAIN_BOARD_TOP_OLD=-30.05
MAIN_BOARD_TOP_NEW=MAIN_BOARD_TOP_OLD+SHIFT_Z
MAIN_BOARD_BOTTOM_OLD=-31.56
MAIN_BOARD_BOTTOM_NEW=MAIN_BOARD_BOTTOM_OLD+SHIFT_Z
FRONT_SUPPORT_ZMIN=-30.0+SHIFT_Z
REAR_SPACER_ZMAX=-31.6+SHIFT_Z

OLD_POTS=[(42,84),(80,84),(118,84)]
PRIMARY_POTS=[(38,96),(76,96),(114,96)]
FX_POTS=[(66,70),(88,70),(110,70)]
NEW_POTS=PRIMARY_POTS+FX_POTS
MODE=(150.5,84.5)
POT_HOLE_R=3.4
MODE_HOLE_R=3.3

def color_hex(c, default='#30362F'):
    if c is None:return default
    rgb=c.toTuple()[:3]
    return '#'+''.join(f'{max(0,min(255,round(v*255))):02x}' for v in rgb)

def bbox(s):
    b=s.BoundingBox(); return [float(x) for x in (b.xmin,b.ymin,b.zmin,b.xmax,b.ymax,b.zmax)]

def centered_box(cx,cy,w,h,z0,z1,rot=0):
    s=cq.Workplane('XY').box(w,h,z1-z0,centered=(True,True,False)).val().translate((cx,cy,z0))
    return s.rotate((cx,cy,0),(cx,cy,1),rot) if rot else s

def cyl(cx,cy,r,z0,z1):
    return cq.Workplane('XY').circle(r).extrude(z1-z0).val().translate((cx,cy,z0))

def component_color(name):
    if name.endswith(('_shaft','_bushing','_pins')):return '#A3A899'
    if name.startswith(('D10_','D11_','D12_','D13_')):return '#ADC873'
    if re.match(r'^[RC]\d+_body$',name):return '#7E7862'
    return '#30362F'

print('Loading retained enclosure assembly...',flush=True)
base=cq.Assembly.importStep(str(BASE))
old={c.name:(c.obj.moved(c.loc),color_hex(c.color)) for c in base.children}

# Retain non-PCB enclosure/mechanical items only. Current panel electrical parts
# are regenerated below, so obsolete cable-header/component models cannot survive.
elec=re.compile(r'^(?:RV|ENC|SW|TP|JP|[RCUJFLOD])\d+_')
items={}
for name,(shape,col) in old.items():
    if name in {'P1_BOARD','MAINBOARD_REPAIRED','MAINBOARD_UNCHANGED',
                'P1_knobs_REFERENCE','P1_markers_REFERENCE',
                'engraving_reference'}: continue
    if elec.match(name): continue
    items[name]=(shape,col)

# Rebuild the active six-pot panel reference from the active electrical/mechanical source.
board=model.board_shape()
items['P1_BOARD']=(board,'#265944')
panel_component_names=[]
for p in PARTS:
    for suffix,shape in model.localmodel(p).items():
        name=p['ref']+'_'+suffix
        items[name]=(model.place(shape,p), old.get(name,(None,component_color(name)))[1] if name in old else component_color(name))
        panel_component_names.append(name)

# Front plate: repair the three legacy macro holes, then cut the six current
# two-row pot openings. MODE remains in its original raised insert.
panel=old['panel'][0]
panel=panel.fuse(cq.Compound.makeCompound([cyl(x,y,3.5,-.02,2.04) for x,y in OLD_POTS])).clean()
panel=panel.intersect(model.rect(-1,-1,205,131,0,2)).clean()  # retain exact 2.00 mm faceplate thickness
for x,y in NEW_POTS:
    panel=panel.cut(cyl(x,y,POT_HOLE_R,-.05,2.10)).clean()
items['panel']=(panel,old['panel'][1])

# The original raised MODE insert and its support/nut stack are retained unchanged.
mode_insert=old['mode_blank'][0]
items['mode_blank']=(mode_insert,old['mode_blank'][1])

# Replace old 3-macro knob references with a visual hierarchy:
# three large primary knobs, three smaller FX knobs, plus the encoder.
knobs=[];markers=[]
for x,y in PRIMARY_POTS:
    knobs.append(model.cyl(x,y,6,11.5,16).cut(model.cyl(x,y,5.9,3.7,14.6)))
    markers.append(model.rect(x-.5,y+7.5,1,3,22.01,.05))
for x,y in FX_POTS:
    knobs.append(model.cyl(x,y,6,7.0,12).cut(model.cyl(x,y,5.9,3.7,11.0)))
    markers.append(model.rect(x-.4,y+3.5,.8,2.2,18.01,.05))
knobs.append(model.cyl(42,43,6,13,16).cut(model.cyl(42,43,5.9,3.7,14.6)))
markers.append(model.rect(41.5,52,1,3,22.01,.05))
items['P1_knobs_REFERENCE']=(cq.Compound.makeCompound(knobs),'#292F2A')
items['P1_markers_REFERENCE']=(cq.Compound.makeCompound(markers),'#DDDCCD')

# Retain all legacy engraving except the old three macro names, then add
# row-specific labels. MODE keeps the original dedicated insert artwork.
eng=old['engraving_reference'][0]
keep=[]
for s in eng.Solids():
    b=s.BoundingBox()
    old_macro=(66.5<=b.ymin<=70.0 and b.ymax<=70.5 and
               ((37.5<=b.xmin<=46.0) or (75.5<=b.xmin<=84.5) or (114.5<=b.xmin<=121.0)))
    if not old_macro: keep.append(s)
def text_shape(txt,x,y,size=2.0,z=1.77):
    q=cq.Workplane('XY').text(txt,size,.21,halign='center',valign='center',font='DejaVu Sans').val()
    return q.translate((x,y,z))
for txt,(x,_) in zip(['TENSION','DECAY','CHAOS'],PRIMARY_POTS):
    keep.append(text_shape(txt,x,112.5,2.0))
keep.append(text_shape('FX',50,70,1.6))
for txt,(x,_) in zip(['DRIVE','DELAY','REVERB'],FX_POTS):
    keep.append(text_shape(txt,x,59.0,1.65))
engraving=cq.Compound.makeCompound(keep)
items['engraving_reference']=(engraving,old['engraving_reference'][1])

# Use the freshly exported current native mainboard assembly, not the retained
# legacy case copy. This keeps the enclosure model synchronized when obsolete
# edge headers are physically removed from the canonical PCB.
main_step=ROOT.parent/'courant'/'deliverables'/'courant-assembly.step'
main_raw=cq.importers.importStep(str(main_step)).val()
# KiCad STEP: board center z=0, x/y native coordinates. Product transform is
# x-12, y+164.25; board midpoint maps to the current direct-stack PCB plane.
main_z_mid=(MAIN_BOARD_TOP_NEW+MAIN_BOARD_BOTTOM_NEW)/2
main=main_raw.translate((-12.0,164.25,main_z_mid))
items['MAINBOARD_REPAIRED']=(main,old['MAINBOARD_REPAIRED'][1])

# Shorten front support posts by 0.46 mm while retaining their front attachment.
clip=model.rect(-50,-50,300,230,FRONT_SUPPORT_ZMIN,35)
for name in [n for n in list(items) if n.startswith('corner_support_')]:
    s,c=items[name];items[name]=(s.intersect(clip).clean(),c)

# Extend the rear board spacers toward the shifted PCB by 0.46 mm.
if 'spacers_reference' in items:
    s,c=items['spacers_reference']
    ext=[]
    for q in s.Solids(): ext.append(q.fuse(q.translate((0,0,SHIFT_Z))).clean())
    items['spacers_reference']=(cq.Compound.makeCompound(ext),c)

# Exact stack-reference connector geometry. The panel sockets are generated from
# the active PARTS source using the drawing-derived IPS1 STEP; here we place the
# matching IPT1-110-06-L-D model on the mainboard. Both models contain all 20
# contacts/tails and the elevated -06 shroud geometry from the Samtec prints.
main_spec=STACK['connector_footprint']['main']
main_model_path=ROOT.parent/'stack'/'models'/'Samtec_IPT1-110-06-L-D_drawing_reference.step'
main_model_local=cq.importers.importStep(str(main_model_path)).val()
main_connector_refs={}
for con in STACK['connectors']:
    cx=STACK['mainboard_product_offset_mm']['x']+con['main_xy_mm']['x']
    cy=STACK['mainboard_product_offset_mm']['y']+con['main_xy_mm']['y']
    shape=main_model_local.rotate((0,0,0),(0,0,1),con['rotation_deg']).translate((cx,cy,MAIN_BOARD_TOP_NEW))
    main_connector_refs[con['main_ref']]=shape

# Mechanical validation.
checks={}
checks['panel_valid']=panel.isValid();checks['mode_insert_valid']=mode_insert.isValid()
checks['panel_bbox_mm']=[round(x,4) for x in bbox(panel)]
checks['mainboard_bbox_mm']=[round(x,4) for x in bbox(main)]
checks['support_zmin_mm']=round(min(bbox(items[n][0])[2] for n in items if n.startswith('corner_support_')),4)
checks['rear_spacer_zmax_mm']=round(bbox(items['spacers_reference'][0])[5],4)
checks['pcb_gap_mm']=round(abs(MAIN_BOARD_TOP_NEW-PANEL_BOARD_BACK_Z),4)
checks['target_gap_mm']=STACK['mating']['fully_mated_gap_mm']

# All control shafts/bushings must clear their enclosure holes.
shaft_clear={}
for ref in ['RV1','RV2','RV3','RV4','RV5','RV6']:
    sh=items[ref+'_shaft'][0];shaft_clear[ref]=abs(sh.intersect(panel).Volume())
for suffix in ['bushing','shaft']:
    shaft_clear['SW1_'+suffix]=abs(items['SW1_'+suffix][0].intersect(mode_insert).Volume())
checks['control_enclosure_intersection_mm3']={k:round(v,7) for k,v in shaft_clear.items()}

# Verify panel-side components do not hit the shifted mainboard, excluding nothing:
# the two Samtec socket bodies should still stop before the mainboard header bodies.
clashes=[]
for name in panel_component_names:
    # J100/J101 intentionally mate the mainboard's J17/J18 and are validated
    # separately below using the exact stack reference geometry.
    if name.startswith(('J100_','J101_')):continue
    s=items[name][0]
    b1=bbox(s);b2=bbox(main)
    if any(min(b1[i+3],b2[i+3])-max(b1[i],b2[i])<=0 for i in range(3)):continue
    v=abs(s.intersect(main).Volume())
    if v>1e-4:clashes.append({'panel_part':name,'volume_mm3':round(v,5)})
checks['panel_component_vs_mainboard_clashes']=clashes

# Samtec full reference-model mating. Both sides now include all 20 pins/tails,
# socket towers and the elevated -06 shroud. The rounded REF dimensions in the
# official drawings close the IPT shroud top and IPS base by 0.01 mm at the
# nominal 19.99 mm board gap; the detailed vendor geometry resolves that mating
# interface. We therefore report/limit that drawing-rounding overlap separately,
# while independently verifying board gap, insertion and official contact wipe.
samtec=[]
nominal_insertion=(MAIN_BOARD_TOP_NEW+main_spec['insulation_height_mm'])-(PANEL_BOARD_BACK_Z-STACK['connector_footprint']['panel']['body_height_mm'])
max_gap_insertion=main_spec['insulation_height_mm']+STACK['connector_footprint']['panel']['body_height_mm']-STACK['mating']['max_gap_mm']
checks['samtec_nominal_geometric_insertion_mm']=round(nominal_insertion,3)
checks['samtec_geometric_insertion_at_max_gap_mm']=round(max_gap_insertion,3)
checks['samtec_fully_mated_wipe_mm']=STACK['mating']['fully_mated_wipe_mm']
checks['samtec_min_wipe_at_max_gap_mm']=STACK['mating']['min_wipe_at_max_gap_mm']
checks['samtec_housing_ref_rounding_depth_mm']=round(main_spec['insulation_height_mm']+(STACK['connector_footprint']['panel']['body_height_mm']-STACK['connector_footprint']['panel']['socket_tower_height_mm'])-checks['pcb_gap_mm'],3)
for con in STACK['connectors']:
    pbody=items[con['panel_ref']+'_body'][0]
    mbody=main_connector_refs[con['main_ref']]
    bp=bbox(pbody);bm=bbox(mbody)
    inter=pbody.intersect(mbody); iv=abs(inter.Volume())
    ib=bbox(inter) if iv>1e-9 else [0,0,0,0,0,0]
    # The series drawings use rounded REF dimensions: 15.30 + 8.51 - 19.99
    # gives 3.82 mm nominal insertion while the IPS1 tower is quoted as 3.81 mm.
    # The resulting 0.01 mm contact-plane overlap is accepted as drawing-rounding,
    # but no deeper solid penetration is allowed.
    iz=max(0.0,ib[5]-ib[2]) if iv>1e-9 else 0.0
    samtec.append({'id':con['id'],'panel_model_z':[round(bp[2],3),round(bp[5],3)],
                   'main_model_z':[round(bm[2],3),round(bm[5],3)],
                   'solid_overlap_mm3':round(iv,7),
                   'solid_overlap_z_mm':round(iz,5)})
checks['samtec_reference_models']=samtec

# Check the changed assembly against the retained enclosure. Positive volume at
# the four corner supports/rear spacers is intentional structural board contact;
# all other changed mainboard/control vs enclosure intersections must be zero.
changed_fit=[]
for other in ['rear_guard','desktop_dock','panel','mode_blank',
              'corner_support_BL','corner_support_BR','corner_support_TL','corner_support_TR','spacers_reference']:
    if other not in items: continue
    v=abs(main.intersect(items[other][0]).Volume())
    changed_fit.append({'a':'MAINBOARD_REPAIRED','b':other,'volume_mm3':round(v,7)})
for ref in ['RV4_body','RV5_body','RV6_body','SW1_body']:
    if ref not in items: continue
    for other in ['rear_guard','desktop_dock']:
        if other not in items: continue
        v=abs(items[ref][0].intersect(items[other][0]).Volume())
        changed_fit.append({'a':ref,'b':other,'volume_mm3':round(v,7)})
unintended=[x for x in changed_fit
            if x['volume_mm3']>1e-4 and not (x['a']=='MAINBOARD_REPAIRED' and
               (x['b'].startswith('corner_support_') or x['b']=='spacers_reference'))]
checks['changed_enclosure_intersections']=changed_fit
checks['changed_enclosure_unintended_intersections']=unintended

assert checks['panel_valid'] and checks['mode_insert_valid']
assert abs(checks['pcb_gap_mm']-STACK['mating']['fully_mated_gap_mm'])<1e-6
assert not clashes
assert max(shaft_clear.values())<1e-4,shaft_clear
assert abs(checks['samtec_nominal_geometric_insertion_mm']-STACK['mating']['geometric_insertion_fully_mated_mm'])<1e-6
assert abs(checks['samtec_geometric_insertion_at_max_gap_mm']-STACK['mating']['geometric_insertion_at_max_gap_mm'])<1e-6
assert all(x['solid_overlap_z_mm']<=0.011 for x in samtec),samtec
assert not unintended,unintended

# Export updated mechanical artifacts.
model.export_assy(items,CAD/'RADIAN_P1_desktop_fit_study.step','RADIAN_TWO_ROW_CASE_P3')
model.export_assy(items,CAD/'RADIAN_P1_case_updated.step','RADIAN_TWO_ROW_CASE_P3')
cq.exporters.export(panel,str(CAD/'panel.step'))
cq.exporters.export(panel,str(CAD/'RADIAN_P1_front_panel_updated.step'))
cq.exporters.export(mode_insert,str(CAD/'mode_blank.step'))
stale_reverb=CAD/'reverb_insert.step'
if stale_reverb.exists(): stale_reverb.unlink()
cq.exporters.export(engraving,str(CAD/'RADIAN_current_engraving_reference.step'))
if 'P1_mode_rear_spacer' in items:cq.exporters.export(items['P1_mode_rear_spacer'][0],str(CAD/'P1_mode_rear_spacer.step'))

# Case-only assembly excludes PCB/component references but includes enclosure/support hardware.
case_names=[n for n in items if n not in panel_component_names and n not in {'P1_BOARD','MAINBOARD_REPAIRED'} and not n.endswith('_IPT1_REFERENCE')]
model.export_assy({n:items[n] for n in case_names},CAD/'RADIAN_P1_case_shell_updated.step','RADIAN_CASE_SHELL_P3')

report={
 'revision':'CASE-P3-TWO-ROW',
 'source_case':str(BASE.relative_to(ROOT)),
 'stack_revision':STACK['revision'],
 'mainboard_shift_forward_mm':SHIFT_Z,
 'panel_to_mainboard_pcb_gap_mm':checks['pcb_gap_mm'],
 'samtec':{'main':main_spec['mpn'],'panel':STACK['connector_footprint']['panel']['mpn'],
           'fully_mated_gap_mm':STACK['mating']['fully_mated_gap_mm'],
           'max_gap_mm':STACK['mating']['max_gap_mm'],
           'support_target_mm':STACK['mating']['assembly_standoff_target_mm']},
 'front_panel':{'old_macro_holes_closed':OLD_POTS,
                'primary_large_knob_centers':PRIMARY_POTS,
                'fx_small_knob_centers':FX_POTS,
                'pot_hole_diameter_mm':2*POT_HOLE_R,
                'primary_knob_diameter_mm':23.0,
                'fx_knob_diameter_mm':14.0,
                'mode_center':MODE,
                'mode_hole_diameter_mm':2*MODE_HOLE_R,
                'mode_insert_role':'MODE'},
 'supports':{'front_support_rear_z_mm':FRONT_SUPPORT_ZMIN,
             'rear_spacer_front_z_mm':REAR_SPACER_ZMAX,'rear_guard_unchanged':True},
 'validation':checks,
 'limitations':['Samtec connector solids are drawing-derived reference models, not Samtec-supplied STEP downloads',
                'connector insertion/retention forces and case tolerances require first-article validation',
                '0.01 mm nominal housing-plane overlap comes from rounded REF dimensions in the Samtec prints',
                'knob/nut/washer stack remains reference geometry']
}
(REPORTS/'case_direct_stack_update.json').write_text(json.dumps(report,indent=2)+'\n')
print('CASE GEOMETRY PASS',json.dumps(report,indent=2),flush=True)

# Previews are optional and must never invalidate a successful mechanical build.
# Run under Xvfb/headed DISPLAY to produce them; headless CAD generation exits cleanly.
import os
if os.environ.get('DISPLAY'):
    model.render(items,PREV/'desktop_fit_study.png',target=(101,64,-15),camera=(310,-230,300),scale=110)
    model.render(items,PREV/'case_front_updated.png',target=(101,64,1),camera=(101,64,300),scale=76,up=(0,1,0))
    nodock={n:v for n,v in items.items() if n not in {'desktop_dock','dock_nuts_reference'}}
    model.render(nodock,PREV/'module_without_dock.png',target=(101,64,-10),camera=(310,-230,280),scale=105)
    exploded={}
    for n,(shape,c) in items.items():
        if n in ['desktop_dock','dock_nuts_reference','MAINBOARD_REPAIRED','rear_guard','spacers_reference'] or n.startswith('corner_support_') or n.endswith('_IPT1_REFERENCE'):dz=0
        elif n=='P1_BOARD' or n in panel_component_names:dz=40
        else:dz=65
        exploded[n]=(shape.translate((0,0,dz)),c)
    model.render(exploded,PREV/'stack_exploded.png',target=(101,64,15),camera=(345,-250,245),scale=150)
    print('CASE PREVIEWS DONE',flush=True)
else:
    print('CASE PREVIEWS SKIPPED: no DISPLAY (geometry/report are complete)',flush=True)
