#!/usr/bin/env python3
import sys, pcbnew
from collections import defaultdict, deque
P='/home/ik/ChatGPT/Courant/hardware/panel/design/radian_panel.kicad_pcb'
net=sys.argv[1]; layer=pcbnew.B_Cu if sys.argv[2]=='B' else pcbnew.F_Cu
old=(float(sys.argv[3]),float(sys.argv[4])); cut=(float(sys.argv[5]),float(sys.argv[6]))
b=pcbnew.LoadBoard(P)
def key(p):return (round(pcbnew.ToMM(p.x),3),round(pcbnew.ToMM(p.y),3))
tracks=[t for t in b.GetTracks() if not isinstance(t,pcbnew.PCB_VIA) and t.GetNetname()==net and t.GetLayer()==layer]
adj=defaultdict(list)
for t in tracks:
    a=key(t.GetStart());c=key(t.GetEnd());adj[a].append((c,t));adj[c].append((a,t))
q=deque([old]);prev={old:None};pedge={}
while q:
    u=q.popleft()
    if u==cut:break
    for v,t in adj[u]:
        if v not in prev:prev[v]=u;pedge[v]=t;q.append(v)
if cut not in prev:raise SystemExit(f'no path {net} {old}->{cut}')
kill=[];cur=cut
while cur!=old:kill.append(pedge[cur]);cur=prev[cur]
for t in kill:b.Remove(t)
pcbnew.SaveBoard(P,b,True)
print(net,'removed',len(kill),'segments')
