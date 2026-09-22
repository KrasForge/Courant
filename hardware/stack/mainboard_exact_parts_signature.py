#!/usr/bin/env python3
import pcbnew,json,sys
from pathlib import Path
p=Path(sys.argv[1])
out=Path(sys.argv[2])
b=pcbnew.LoadBoard(str(p))
def xy(v): return [v.x,v.y]
tracks=[]
for t in b.GetTracks():
    row={'class':t.GetClass(),'net':t.GetNetname(),'layer':t.GetLayer()}
    if isinstance(t,pcbnew.PCB_VIA):
        row.update(pos=xy(t.GetPosition()),width=t.GetWidth(pcbnew.F_Cu),drill=t.GetDrillValue(),
                   top=t.TopLayer(),bottom=t.BottomLayer())
    else:
        row.update(start=xy(t.GetStart()),end=xy(t.GetEnd()),width=t.GetWidth())
    tracks.append(row)
fps=[]
for f in b.GetFootprints():
    pads=[]
    for q in f.Pads():
        pads.append({
            'num':q.GetNumber(),'net':q.GetNetname(),'pos':xy(q.GetPosition()),
            'size':xy(q.GetSize()),'drill':xy(q.GetDrillSize()),
            'layers':q.GetLayerSet().FmtHex(),'attr':int(q.GetAttribute()),
        })
    fps.append({
        'ref':f.GetReference(),'pos':xy(f.GetPosition()),
        'angle':round(f.GetOrientationDegrees(),6),'layer':f.GetLayer(),
        'pads':sorted(pads,key=lambda x:(x['num'],x['pos'])),
    })
sig={'tracks':sorted(tracks,key=lambda x:json.dumps(x,sort_keys=True)),
     'footprints':sorted(fps,key=lambda x:(x['ref'],x['pos']))}
out.write_text(json.dumps(sig,sort_keys=True,separators=(',',':')))
print(out,len(sig['tracks']),len(sig['footprints']))
