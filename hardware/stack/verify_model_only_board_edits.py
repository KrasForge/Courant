#!/usr/bin/env python3
from pathlib import Path
import json, pcbnew, hashlib
ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
BACK=ROOT/'_backups/exact_stack_models_20260918T010444Z'

def xy(v):return (v.x,v.y)
def signature(path):
 b=pcbnew.LoadBoard(str(path))
 tracks=[]
 for t in b.GetTracks():
  row=[t.GetClass(),t.GetNetname(),xy(t.GetStart()),xy(t.GetEnd()),t.GetLayer()]
  if isinstance(t,pcbnew.PCB_VIA):
   row += [t.GetWidth(pcbnew.F_Cu),t.GetDrillValue()]
  else: row += [t.GetWidth()]
  tracks.append(row)
 fps=[]
 for f in b.GetFootprints():
  pads=[]
  for p in f.Pads():
   pads.append([p.GetNumber(),p.GetNetname(),xy(p.GetPosition()),xy(p.GetSize()),xy(p.GetDrillSize()),p.GetLayerSet().FmtHex()])
  fps.append([f.GetReference(),f.GetValue(),xy(f.GetPosition()),round(f.GetOrientationDegrees(),6),f.GetLayer(),sorted(pads,key=str)])
 return {'tracks':sorted(tracks,key=str),'footprints':sorted(fps,key=str)}

pairs=[
 ('panel',BACK/'panel/radian_panel.kicad_pcb',ROOT/'panel/design/radian_panel.kicad_pcb'),
 ('main',BACK/'main/courant.kicad_pcb',ROOT/'courant/deliverables/courant.kicad_pcb'),
]
report={}
for name,old,new in pairs:
 so=signature(old); sn=signature(new)
 report[name]={
  'electrical_geometry_unchanged':so==sn,
  'old_sha256':hashlib.sha256(old.read_bytes()).hexdigest(),
  'new_sha256':hashlib.sha256(new.read_bytes()).hexdigest(),
 }
 if so!=sn:
  raise SystemExit(name+' electrical/placement signature changed')
(ROOT/'stack/model-only-board-edit-validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
