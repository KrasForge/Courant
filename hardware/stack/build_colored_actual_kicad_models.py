#!/usr/bin/env python3
from pathlib import Path
import cadquery as cq

ROOT=Path('/home/ik/ChatGPT/Courant')
MODELS=ROOT/'hardware/panel/cad/models'

METAL=(0.72,0.74,0.76)
DARK=(0.055,0.060,0.065)
INDUCTOR=(0.10,0.105,0.11)
GOLD=(0.78,0.55,0.15)

SPECS={
    'Bourns_PTV09A_4020F_family_actual.step':[
        METAL,METAL,METAL,METAL,METAL,DARK],
    'Bourns_PEC11R_4220F_S0024_drawing_reference.step':[
        METAL,METAL,METAL,METAL,METAL,METAL,METAL,METAL,METAL,METAL],
    'E_Switch_100SP1T1B1M2REH_drawing_reference.step':[
        DARK,METAL,METAL,METAL,METAL,METAL],
    'Bourns_SRP7050TA_100M_drawing_reference.step':[
        INDUCTOR,METAL,METAL],
    'TestPoint_D2.step':[GOLD],
}

def colorize(src, colors):
    path=MODELS/src
    shape=cq.importers.importStep(str(path)).val()
    solids=list(shape.Solids())
    if len(solids)!=len(colors):
        raise RuntimeError(f'{src}: expected {len(colors)} solids, got {len(solids)}')
    out=path.with_name(path.stem+'_colored.step')
    assy=cq.Assembly(name=path.stem+'_COLORED')
    for i,(solid,rgb) in enumerate(zip(solids,colors)):
        assy.add(solid,name=f'{path.stem}_{i:02d}',color=cq.Color(*rgb))
    assy.export(str(out))
    check=cq.Assembly.importStep(str(out))
    missing=[c.name for c in check.children if c.color is None]
    if missing:
        raise RuntimeError(f'{out}: colors did not persist: {missing}')
    before=shape.BoundingBox()
    after=cq.importers.importStep(str(out)).val().BoundingBox()
    a=(before.xmin,before.ymin,before.zmin,before.xmax,before.ymax,before.zmax)
    b=(after.xmin,after.ymin,after.zmin,after.xmax,after.ymax,after.zmax)
    if max(abs(x-y) for x,y in zip(a,b)) > 1e-6:
        raise RuntimeError(f'{out}: geometry bbox changed: {a} -> {b}')
    print('COLORED_MODEL_PASS',out,len(solids))

for src,colors in SPECS.items():
    colorize(src,colors)
