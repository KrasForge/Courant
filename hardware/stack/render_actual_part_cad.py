#!/usr/bin/env python3
from pathlib import Path
import subprocess, sys, json
import cadquery as cq

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
OUT=ROOT/'stack/actual_parts'
OUT.mkdir(parents=True,exist_ok=True)
PANEL=ROOT/'panel/design/radian_panel.kicad_pcb'
MAIN=ROOT/'courant/deliverables/courant.kicad_pcb'
CAD=ROOT/'panel/cad'
PRE=ROOT/'panel/previews'
sys.path.insert(0,str(ROOT/'panel/source'))
import build_cad as model

PANEL_Z=-9.6
MAIN_Z=-31.10
def run(cmd):
    subprocess.run(cmd,check=True)
def exp(board,name,refs=None,board_only=False):
    out=OUT/(name+'.step')
    cmd=['kicad-cli','pcb','export','step','-f','-o',str(out)]
    if board_only:
        # Mechanical board solid only. Component geometry comes from the native
        # KiCad component-filter exports below; skipping copper keeps the final
        # assembly light enough for interactive CAD/rendering.
        cmd += ['--board-only']
    else:
        cmd += ['--no-board-body','--component-filter',refs]
    cmd += [str(board)]
    run(cmd)
    return out
def load(path):
    return cq.importers.importStep(str(path)).val()
def ptx(s): return s.translate((0,128.5,PANEL_Z))
def mtx(s): return s.translate((-12,164.25,MAIN_Z))
def hx(c,default='#30362f'):
    if c is None:return default
    rgb=c.toTuple()[:3]
    return '#'+''.join(f'{max(0,min(255,round(v*255))):02x}' for v in rgb)

# KiCad-placed native exports.
panel_board=ptx(load(exp(PANEL,'panel_board',board_only=True)))
main_board=mtx(load(exp(MAIN,'main_board',board_only=True)))
panel_groups={
 'P_POTS':('RV1,RV2,RV3,RV4,RV5,RV6','#252724'),
 'P_ENCODER':('ENC1','#242624'),
 'P_MODE':('SW1','#242624'),
 'P_JACKS':('J301,J302,J303,J304,J305','#202220'),
 'P_LEDS':('D10,D11,D12,D13','#55a84d'),
 'P_STACK':('J100,J101','#252724'),
 'P_WURTH':('J200,JP1','#252724'),
 'P_MOLEX':('J201,J202,J306','#ded6b7'),
 'P_BUTTONS':('SW3,SW4','#252724'),
 'P_ACTIVE':('U1,U2,D1,D2,D3,D4,L1,F1,F2','#252724'),
 'P_PASSIVES':('R*,C*','#9b8d6c'),
}
main_groups={
 'M_STACK':('J17,J18','#252724'),
 'M_MOLEX':('J1,J2,J3,J4','#ded6b7'),
 'M_ICS':('U*,Y*','#252724'),
 'M_PASSIVES':('R*,C*','#9b8d6c'),
 'M_MAGNETICS':('L*','#353935'),
 'M_DIODES':('D*','#303330'),
}
items={}
# Existing enclosure shell, but remove all old native-PCB reference geometry.
shell=cq.Assembly.importStep(str(CAD/'RADIAN_P1_case_shell_updated.step'))
for c in shell.children:
    if c.name.startswith('P1_NATIVE_'): continue
    n=c.name
    fallback='#2a2f2a'
    if any(k in n.lower() for k in ['nut','screw','spacer','standoff','shim']):
        fallback='#a4a59d'
    elif 'knob' in n.lower():
        fallback='#252724'
    elif any(k in n.lower() for k in ['marker','engraving','ink']):
        fallback='#dddccd'
    items['CASE_'+n]=(c.obj.moved(c.loc),hx(c.color,fallback))

items['PANEL_BOARD']=(panel_board,'#285d48')
items['MAIN_BOARD']=(main_board,'#285d48')

for name,(refs,col) in panel_groups.items():
    s=ptx(load(exp(PANEL,name.lower(),refs=refs)))
    items[name]=(s,col)
for name,(refs,col) in main_groups.items():
    s=mtx(load(exp(MAIN,name.lower(),refs=refs)))
    items[name]=(s,col)

def export_colored_solids(items,path,name):
    # STEP color on a CadQuery compound does not survive a round trip; colors on
    # child solids do. Export every physical solid as a named colored child.
    assy=cq.Assembly(name=name)
    nsolid=0
    for nm,(shape,hexcol) in items.items():
        rgb=tuple(int(hexcol.lstrip('#')[i:i+2],16)/255 for i in (0,2,4))
        col=cq.Color(*rgb)
        solids=list(shape.Solids())
        if not solids:
            assy.add(shape,name=nm,color=col)
            nsolid+=1
            continue
        for i,s in enumerate(solids):
            assy.add(s,name=f'{nm}_{i:04d}',color=col)
            nsolid+=1
    assy.export(str(path))
    # Round-trip audit: no viewer-default-white children are allowed.
    check=cq.Assembly.importStep(str(path))
    missing=[c.name for c in check.children if c.color is None]
    if missing:
        raise RuntimeError(f'color persistence failed for {len(missing)} children: {missing[:20]}')
    print('COLORED_STEP_PASS',path,nsolid,'solids')
    return nsolid

# Electrical geometry and direct-stack/case collision validation remain the
# canonical validators; component placement comes straight from native KiCad.
# Full product CAD and previews.
export_colored_solids(items,CAD/'RADIAN_actual_parts_full_assembly.step','RADIAN_ACTUAL_PARTS_FULL')
export_colored_solids(items,CAD/'RADIAN_P1_desktop_fit_study.step','RADIAN_ACTUAL_PARTS_FULL')
export_colored_solids(items,CAD/'RADIAN_P1_case_updated.step','RADIAN_ACTUAL_PARTS_FULL')
model.render(items,PRE/'actual_parts_full_iso.png',target=(101,64,-18),camera=(300,-220,130),scale=145)
model.render(items,PRE/'actual_parts_full_side.png',target=(101,64,-18),camera=(101,-285,-18),scale=125,up=(0,0,1))

# Dedicated populated-board CAD.  These deliberately exclude the case and the
# opposite PCB so every fitted part can be inspected directly instead of being
# hidden by the product assembly.  They use the exact same KiCad-native model
# placements as the full assembly above; only the view/export grouping differs.
panel_items={n:v for n,v in items.items() if n=='PANEL_BOARD' or n.startswith('P_')}
main_items={n:v for n,v in items.items() if n=='MAIN_BOARD' or n.startswith('M_')}
export_colored_solids(panel_items,CAD/'RADIAN_actual_parts_panel_board.step','RADIAN_ACTUAL_PARTS_PANEL_BOARD')
export_colored_solids(main_items,CAD/'RADIAN_actual_parts_main_board.step','RADIAN_ACTUAL_PARTS_MAIN_BOARD')
model.render(panel_items,PRE/'actual_parts_panel_board_top.png',target=(108,64,-1),camera=(280,-185,150),scale=92)
model.render(panel_items,PRE/'actual_parts_panel_board_bottom.png',target=(108,64,-10),camera=(275,-175,-125),scale=92,up=(0,0,1))
model.render(main_items,PRE/'actual_parts_main_board_top.png',target=(88,64,-27),camera=(250,-170,105),scale=88)
model.render(main_items,PRE/'actual_parts_main_board_bottom.png',target=(88,64,-31),camera=(245,-165,-130),scale=88,up=(0,0,1))

# Board-stack-only proof uses the same actual KiCad component geometry.
stack_items={n:v for n,v in items.items() if n in {'PANEL_BOARD','MAIN_BOARD'} or n.startswith('P_') or n.startswith('M_')}
export_colored_solids(stack_items,CAD/'RADIAN_direct_stack_mated.step','RADIAN_DIRECT_STACK_ACTUAL_PARTS')
model.render(stack_items,PRE/'direct_stack_mated_iso.png',target=(101,64,-20),camera=(300,-210,120),scale=135)
model.render(stack_items,PRE/'direct_stack_mated_side.png',target=(101,64,-20),camera=(101,-260,-20),scale=120,up=(0,0,1))
close={n:v for n,v in stack_items.items() if n in {'PANEL_BOARD','MAIN_BOARD','P_STACK','M_STACK'}}
model.render(close,PRE/'direct_stack_connectors_closeup.png',target=(84,67,-20),camera=(250,-180,35),scale=95)

report={
 'status':'PASS',
 'panel_native_board':str(PANEL),
 'main_native_board':str(MAIN),
 'dedicated_populated_board_cad':{
  'panel':'panel/cad/RADIAN_actual_parts_panel_board.step',
  'main':'panel/cad/RADIAN_actual_parts_main_board.step',
 },
 'dedicated_populated_board_renders':[
  'panel/previews/actual_parts_panel_board_top.png',
  'panel/previews/actual_parts_panel_board_bottom.png',
  'panel/previews/actual_parts_main_board_top.png',
  'panel/previews/actual_parts_main_board_bottom.png',
 ],
 'panel_groups':{k:v[0] for k,v in panel_groups.items()},
 'main_groups':{k:v[0] for k,v in main_groups.items()},
 'collision_validation':'Use direct-stack-validation.json and case_direct_stack_update.json; this renderer preserves native KiCad placement.',
 'panel_transform':{'x':0,'y':128.5,'z':PANEL_Z},
 'main_transform':{'x':-12,'y':164.25,'z':MAIN_Z},
 'actual_or_package_models':[
  'Bourns PTV09A family geometry aligned to PTV09A-4020F-B103 footprint/20 mm shaft',
  'QingPu/Thonk PJ398SM open mechanical CAD with knurled nut',
  'Omron B3F-1000 package geometry',
  '3 mm green LED package geometry',
  'all selected Wurth/Molex/Samtec and mainboard package STEP models already attached in KiCad',
 ],
 'drawing_derived_remaining':['ENC1 Bourns PEC11R-4220F-S0024','SW1 E-Switch 100SP1T1B1M2REH','Samtec J100/J101/J17/J18','Molex mainboard J1-J4'],
 'note':'No generic white component envelopes are used in this final assembly; component placement comes from KiCad STEP export.'
}
(OUT/'actual_parts_report.json').write_text(json.dumps(report,indent=2)+'\n')
print('ACTUAL_PART_CAD_PASS')
print(json.dumps(report,indent=2))
