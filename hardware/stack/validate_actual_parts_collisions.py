#!/usr/bin/env python3
from pathlib import Path
import json,time
import cadquery as cq

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
D=ROOT/'stack/actual_parts'
CASE=ROOT/'panel/cad/RADIAN_P1_case_shell_updated.step'
PANEL_T=(0.0,128.5,-9.6)
MAIN_T=(-12.0,164.25,-31.10)

def load(fn,t):
    return cq.importers.importStep(str(D/fn)).val().translate(t)

case_assy=cq.Assembly.importStep(str(CASE))
physical_case_names={
    'panel','mode_blank','rear_guard','desktop_dock',
    'corner_support_BL','corner_support_BR','corner_support_TL','corner_support_TR',
    'midi_support'
}
physical_case={c.name:c.obj.moved(c.loc) for c in case_assy.children if c.name in physical_case_names}

panel_enclosure={
    'panel_pots':load('panel-pots-raw.step',PANEL_T),
    'panel_encoder':load('panel-encoder-raw.step',PANEL_T),
    'panel_mode':load('panel-mode-raw.step',PANEL_T),
    'panel_jacks':load('panel-jacks-only-raw.step',PANEL_T),
    'panel_leds':load('panel-leds-only-raw.step',PANEL_T),
}
enclosure_clashes=[]
for gn,g in panel_enclosure.items():
    bg=g.BoundingBox()
    for cn,c in physical_case.items():
        bc=c.BoundingBox()
        if bg.xmax<bc.xmin or bc.xmax<bg.xmin or bg.ymax<bc.ymin or bc.ymax<bg.ymin or bg.zmax<bc.zmin or bc.zmax<bg.zmin:
            continue
        v=abs(g.intersect(c).Volume())
        if v>1e-5:
            enclosure_clashes.append({'component_group':gn,'case_solid':cn,'volume_mm3':round(v,7)})

main_files=[
    'main-board-raw.step','main-ics-only-raw.step','main-service-connectors-raw.step',
    'main-resistors-raw.step','main-capacitors-raw.step','main-diodes-raw.step',
    'main-inductors-raw.step','main-oscillators-raw.step'
]
main_non_samtec=cq.Compound.makeCompound([load(f,MAIN_T) for f in main_files])
panel_files=[
    'panel-pots-raw.step','panel-encoder-raw.step','panel-mode-raw.step',
    'panel-jacks-only-raw.step','panel-leds-only-raw.step','panel-wurth-raw.step',
    'panel-molex-raw.step','panel-buttons-raw.step','panel-ics-raw.step',
    'panel-resistors-raw.step','panel-capacitors-raw.step','panel-power-discretes-raw.step'
]
panel_main_clashes=[]
overlap=0.0
for fn in panel_files:
    g=load(fn,PANEL_T)
    # cheap Z bbox prune
    bg=g.BoundingBox(); bm=main_non_samtec.BoundingBox()
    if bg.zmax<bm.zmin or bg.zmin>bm.zmax:
        continue
    v=abs(g.intersect(main_non_samtec).Volume())
    overlap+=v
    if v>1e-5:
        panel_main_clashes.append({'file':fn,'volume_mm3':round(v,7)})

raw_panel=cq.importers.importStep(str(D/'panel-board-raw.step')).val().BoundingBox()
raw_main=cq.importers.importStep(str(D/'main-board-raw.step')).val().BoundingBox()
panel_back=PANEL_T[2]+raw_panel.zmin
main_front=MAIN_T[2]+raw_main.zmax
gap=panel_back-main_front

report={
    'status':'PASS' if abs(gap-19.99)<0.001 and not enclosure_clashes and not panel_main_clashes else 'FAIL',
    'physical_pcb_faces':{
        'panel_back_z_mm':round(panel_back,4),
        'main_front_z_mm':round(main_front,4),
        'gap_mm':round(gap,4),
        'target_mm':19.99,
    },
    'actual_components_vs_physical_enclosure_clashes':enclosure_clashes,
    'non_samtec_panel_vs_main_clashes':panel_main_clashes,
    'non_samtec_panel_vs_main_overlap_mm3':round(overlap,7),
    'notes':[
        'Reference nuts, shims, standoffs, inks and PCB visualization layers are excluded from enclosure clash classification.',
        'The intentionally mated Samtec J100/J101 to J17/J18 pair is excluded from panel-vs-main clash classification.'
    ]
}
out=ROOT/'stack/actual-parts-collision-validation.json'
out.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
if report['status']!='PASS': raise SystemExit(1)
