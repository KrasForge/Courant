#!/usr/bin/env python3
import pcbnew
from collections import defaultdict, deque
P='/home/ik/ChatGPT/Courant/hardware/panel/design/radian_panel.kicad_pcb'
b=pcbnew.LoadBoard(P)

# Move the no-component Tag-Connect target into the former MIDI carrier window.
j=next(f for f in b.GetFootprints() if f.GetReference()=='J202')
j.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(105),pcbnew.FromMM(98)))

def key(p): return (round(pcbnew.ToMM(p.x),3),round(pcbnew.ToMM(p.y),3))
def trim_path(net,layer,old_end,cut):
    tracks=[t for t in b.GetTracks()
            if not isinstance(t,pcbnew.PCB_VIA)
            and t.GetNetname()==net and t.GetLayer()==layer]
    adj=defaultdict(list)
    for t in tracks:
        a=key(t.GetStart()); c=key(t.GetEnd())
        adj[a].append((c,t)); adj[c].append((a,t))
    q=deque([old_end]); prev={old_end:None}; pedge={}
    while q:
        u=q.popleft()
        if u==cut:break
        for v,t in adj[u]:
            if v not in prev:
                prev[v]=u;pedge[v]=t;q.append(v)
    if cut not in prev: raise RuntimeError(f'no path {net} {old_end}->{cut}')
    kill=[]; cur=cut
    while cur!=old_end:
        kill.append(pedge[cur]);cur=prev[cur]
    seen=set(); unique=[]
    for t in kill:
        u=str(t.m_Uuid)
        if u not in seen:
            seen.add(u); unique.append(t)
    for t in unique:b.Remove(t)
    print(net,'removed',len(unique),'tail segments')

trim_path('JTAG_TMS',pcbnew.B_Cu,(124.65,99.5),(115.5,93.0))
trim_path('JTAG_TDI',pcbnew.B_Cu,(127.19,99.5),(111.0,102.5))
trim_path('JTAG_TCK',pcbnew.F_Cu,(132.27,99.5),(111.5,103.0))
trim_path('JTAG_TDO',pcbnew.F_Cu,(129.73,99.5),(111.0,102.5))
pcbnew.SaveBoard(P,b,True)
print('J202 relocated and JTAG tails trimmed')
