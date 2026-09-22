#!/usr/bin/env python3
"""Trim pad-crossing decorative footprint ticks; preserve all copper and labels."""
from pathlib import Path
import math,json
from native_cleanup import parse,render,children,child,val,properties,number

def hits(a,b,m):return a[0]<=b[2]+m and b[0]-m<=a[2] and a[1]<=b[3]+m and b[1]-m<=a[3]
def strip(fp):
    angle=float(child(fp,'at')[3]) if child(fp,'at') and len(child(fp,'at'))>3 else 0
    boxes=[]
    for p in children(fp,'pad'):
        a=child(p,'at');x,y=map(float,a[1:3]);sx,sy=map(float,child(p,'size')[1:3])
        pa=float(a[3]) if len(a)>3 else 0
        theta=math.radians(pa-angle);c,s=abs(math.cos(theta)),abs(math.sin(theta))
        dx,dy=(sx*c+sy*s)/2,(sx*s+sy*c)/2;boxes.append((x-dx,y-dy,x+dx,y+dy))
    bad=[]
    for g in children(fp,'fp_line'):
        if val(child(g,'layer')[1]) not in ['F.SilkS','B.SilkS']:continue
        a=list(map(float,child(g,'start')[1:3]));b=list(map(float,child(g,'end')[1:3]))
        rect=(min(a[0],b[0]),min(a[1],b[1]),max(a[0],b[0]),max(a[1],b[1]))
        width=float(child(child(g,'stroke'),'width')[1])
        if any(hits(rect,p,.20+width/2) for p in boxes):bad.append(g)
    for g in bad:fp.remove(g)
    return len(bad)

def position_labels(board):
    # Placement-specific positions: refuse to apply them to a different floorplan.
    moves={'U1':((34,103.5),(37.1,103.5)), 'C1':((31,110.5),(31,113)),
           'U2':((151,61.5),(149,54)), 'D1':((44,63.5),(48,66.2)),
           'J101':((43,56.25),(43,59.45)), 'JP1':((165.5,40.5),(165.5,44.5))}
    for fp in children(board,'footprint'):
        ref=properties(fp).get('Reference')
        if ref not in moves:continue
        at=child(fp,'at');x,y=map(float,at[1:3]);expected,target=moves[ref]
        assert math.dist((x,y),expected)<1e-5,'Changed placement: '+ref
        a=math.radians(float(at[3]) if len(at)>3 else 0);dx,dy=target[0]-x,target[1]-y
        field=next(f for f in children(fp,'property') if val(f[1])=='Reference')
        fa=child(field,'at');fa[1:3]=[number(dx*math.cos(a)-dy*math.sin(a)),number(dx*math.sin(a)+dy*math.cos(a))]
    for text in children(board,'gr_text'):
        label=val(text[1]);target=None
        if label.startswith('12 V DESKTOP'):target=(82,111)
        elif label.startswith('MOD SHUNT:'):target=(145.5,30.5)
        elif label.startswith('LINE OUTPUTS'):target=(136,112)
        if target:child(text,'at')[1:3]=[number(v) for v in target]

def clean(root):
    root=Path(root).resolve();target=root/'design/radian_panel.kicad_pcb';board=parse(target.read_text())
    stats={'board':{},'library':{}}
    for fp in children(board,'footprint'):
        n=strip(fp)
        if n:stats['board'][properties(fp).get('Reference','')]=n
    position_labels(board)
    target.write_text(render(board)+'\n')
    for file in sorted((root/'library/RadianPanel.pretty').glob('*.kicad_mod')):
        fp=parse(file.read_text());n=strip(fp)
        if n:
            stats['library'][file.stem]=n;file.write_text(render(fp)+'\n')
    (root/'reports/silk_tick_cleanup.json').write_text(json.dumps(stats,indent=2))
    print('Removed only decorative ticks:',stats)

if __name__=='__main__':
    import sys
    clean(sys.argv[1])
