#!/usr/bin/env python3
from pathlib import Path
import cadquery as cq, json

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
D=ROOT/'stack/actual_parts'
CAD=ROOT/'panel/cad'

PANEL_Z=-9.6
MAIN_Z=-31.10
def load(n): return cq.importers.importStep(str(D/(n+'.step'))).val()
def pt(s): return s.translate((0,128.5,PANEL_Z))
def mt(s): return s.translate((-12,164.25,MAIN_Z))
def ov(a,b):
    ba=a.BoundingBox();bb=b.BoundingBox()
    if ba.xmax<=bb.xmin or bb.xmax<=ba.xmin or ba.ymax<=bb.ymin or bb.ymax<=ba.ymin or ba.zmax<=bb.zmin or bb.zmax<=ba.zmin:
        return 0.0
    return abs(a.intersect(b).Volume())

P={
 'pots':pt(load('p_pots')),
 'encoder':pt(load('p_encoder')),
 'mode':pt(load('p_mode')),
 'jacks':pt(load('p_jacks')),
 'leds':pt(load('p_leds')),
 'wurth':pt(load('p_wurth')),
 'molex':pt(load('p_molex')),
 'buttons':pt(load('p_buttons')),
 'active':pt(load('p_active')),
 'passives':pt(load('p_passives')),
 'stack':pt(load('p_stack')),
 'board':pt(load('panel_board')),
}
M={
 'molex':mt(load('m_molex')),
 'ics':mt(load('m_ics')),
 'passives':mt(load('m_passives')),
 'magnetics':mt(load('m_magnetics')),
 'diodes':mt(load('m_diodes')),
 'stack':mt(load('m_stack')),
 'board':mt(load('main_board')),
}

clashes=[]
for pn,ps in P.items():
    if pn in {'stack','board'}: continue
    for mn,ms in M.items():
        v=ov(ps,ms)
        if v>1e-4: clashes.append({'panel':pn,'main':mn,'mm3':round(v,6)})
# Main non-stack components must also clear the panel PCB itself.
for mn,ms in M.items():
    if mn in {'stack','board'}: continue
    v=ov(ms,P['board'])
    if v>1e-4: clashes.append({'panel':'board','main':mn,'mm3':round(v,6)})
# Panel non-stack components must clear the main PCB itself.
for pn,ps in P.items():
    if pn in {'stack','board'}: continue
    v=ov(ps,M['board'])
    if v>1e-4: clashes.append({'panel':pn,'main':'board','mm3':round(v,6)})

# Enclosure collision only against rear/dock solids; faceplate intersections
# with shafts/jack bushings are intentional and handled by existing case checks.
shell=cq.Assembly.importStep(str(CAD/'RADIAN_P1_case_shell_updated.step'))
case={}
for c in shell.children:
    if c.name in {'rear_guard','desktop_dock'}:
        case[c.name]=c.obj.moved(c.loc)
case_clashes=[]
for side,groups in [('panel',P),('main',M)]:
    for gn,gs in groups.items():
        if gn in {'board'}: continue
        for cn,cs in case.items():
            v=ov(gs,cs)
            if v>1e-4: case_clashes.append({'side':side,'group':gn,'case':cn,'mm3':round(v,6)})

report={
 'status':'PASS' if not clashes and not case_clashes else 'FAIL',
 'panel_main_unintended_clashes':clashes,
 'rear_guard_or_dock_clashes':case_clashes,
 'intentional_stack_overlap':'P_STACK <-> M_STACK excluded; validated by direct-stack-validation.json',
}
out=D/'actual_part_collision_report.json'
out.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
if report['status']!='PASS': raise SystemExit(2)
