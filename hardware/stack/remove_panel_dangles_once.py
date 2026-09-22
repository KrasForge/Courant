#!/usr/bin/env python3
import json,re,sys,pcbnew
from pathlib import Path
ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
BOARD=ROOT/'panel/design/radian_panel.kicad_pcb'
REPORT=ROOT/'panel/reports/native/production-parts-prune.json'
TARGET={'DESKTOP_12V','MIDI4','MIDI5','JTAG_TCK','JTAG_TDO','JTAG_TDI','JTAG_TMS','V3V3'}
d=json.loads(REPORT.read_text())
items=[]
for v in d.get('violations',[]):
    if v.get('type') not in {'track_dangling','via_dangling'}: continue
    for item in v.get('items',[]):
        desc=item.get('description','')
        m=re.search(r'(?:Track|Via) \[([^\]]+)\]',desc)
        net=m.group(1) if m else ''
        items.append((item.get('uuid'),net,desc))
foreign=[x for x in items if x[1] not in TARGET]
if foreign:
    print('FOREIGN',foreign);sys.exit(2)
if not items:
    print('NO_DANGLES');sys.exit(0)
b=pcbnew.LoadBoard(str(BOARD)); by={t.m_Uuid.AsString():t for t in b.GetTracks()}
missing=[];removed=[]
for uid,net,desc in items:
    t=by.get(uid)
    if t is None:missing.append(uid);continue
    removed.append((uid,net));b.Remove(t)
if missing:
    print('MISSING',missing);sys.exit(3)
pcbnew.SaveBoard(str(BOARD),b,True)
print('REMOVED',len(removed),removed)
