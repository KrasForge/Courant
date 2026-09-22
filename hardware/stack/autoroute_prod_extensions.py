#!/usr/bin/env python3
import math, heapq
from pathlib import Path
import pcbnew

P=Path('/home/ik/ChatGPT/Courant/hardware/panel/design/radian_panel.kicad_pcb')
b=pcbnew.LoadBoard(str(P))
STEP=.25
NEW_W=.25
CLEAR=.20
EXTRA=.04
PAD_INFLATE=CLEAR+NEW_W/2+EXTRA

def mm(v): return pcbnew.ToMM(v)
def iu(v): return pcbnew.FromMM(v)
def vec(x,y): return pcbnew.VECTOR2I(iu(x),iu(y))
def pad_by(ref,net):
    f=next(x for x in b.GetFootprints() if x.GetReference()==ref)
    return next(p for p in f.Pads() if p.GetNetname()==net)
def pos(item):
    p=item.GetPosition(); return (mm(p.x),mm(p.y))
def point_seg_dist(x,y,x1,y1,x2,y2):
    dx=x2-x1;dy=y2-y1
    if dx==0 and dy==0:return math.hypot(x-x1,y-y1)
    t=max(0,min(1,((x-x1)*dx+(y-y1)*dy)/(dx*dx+dy*dy)))
    return math.hypot(x-(x1+t*dx),y-(y1+t*dy))
def board_ok(x,y):
    if not (18.45<=x<=198.05 and 10.95<=y<=118.05): return False
    # Remaining service cutout.
    if 116.05<=x<=149.95 and 79.55<=y<=93.45:return False
    # Mid-board right-side neck is absent between these y extents.
    if 162.05<=x<=171.95 and 19.05<=y<=109.45:return False
    return True
def make_blocked(net, region):
    xmin,xmax,ymin,ymax=region
    nx=int(round((xmax-xmin)/STEP))+1
    ny=int(round((ymax-ymin)/STEP))+1
    blocked=set()
    def cell(i,j):return (xmin+i*STEP,ymin+j*STEP)
    def mark_box(ax,bx,ay,by):
        i0=max(0,int(math.floor((ax-xmin)/STEP)));i1=min(nx-1,int(math.ceil((bx-xmin)/STEP)))
        j0=max(0,int(math.floor((ay-ymin)/STEP)));j1=min(ny-1,int(math.ceil((by-ymin)/STEP)))
        for i in range(i0,i1+1):
            for j in range(j0,j1+1):blocked.add((i,j))
    # Board voids/edges.
    for i in range(nx):
        for j in range(ny):
            x,y=cell(i,j)
            if not board_ok(x,y):blocked.add((i,j))
    # Pads on B.Cu; own-net copper is legal.
    for f in b.GetFootprints():
        for p in f.Pads():
            if not p.IsOnLayer(pcbnew.B_Cu):continue
            if p.GetNetname()==net:continue
            q=p.GetPosition(); sx=mm(p.GetSize().x);sy=mm(p.GetSize().y)
            cx,cy=mm(q.x),mm(q.y)
            mark_box(cx-sx/2-PAD_INFLATE,cx+sx/2+PAD_INFLATE,
                     cy-sy/2-PAD_INFLATE,cy+sy/2+PAD_INFLATE)
    # Existing B.Cu tracks and all vias; own-net copper is legal.
    for t in b.GetTracks():
        if t.GetNetname()==net:continue
        if isinstance(t,pcbnew.PCB_VIA):
            q=t.GetPosition();cx,cy=mm(q.x),mm(q.y)
            try:w=mm(t.GetWidth(pcbnew.B_Cu))
            except:w=.8
            r=w/2+PAD_INFLATE
            i0=max(0,int((cx-r-xmin)//STEP));i1=min(nx-1,int(math.ceil((cx+r-xmin)/STEP)))
            j0=max(0,int((cy-r-ymin)//STEP));j1=min(ny-1,int(math.ceil((cy+r-ymin)/STEP)))
            for i in range(i0,i1+1):
                for j in range(j0,j1+1):
                    x,y=cell(i,j)
                    if math.hypot(x-cx,y-cy)<=r:blocked.add((i,j))
        elif t.GetLayer()==pcbnew.B_Cu:
            a=t.GetStart();c=t.GetEnd();x1,y1,x2,y2=mm(a.x),mm(a.y),mm(c.x),mm(c.y)
            r=mm(t.GetWidth())/2+PAD_INFLATE
            i0=max(0,int(math.floor((min(x1,x2)-r-xmin)/STEP)));i1=min(nx-1,int(math.ceil((max(x1,x2)+r-xmin)/STEP)))
            j0=max(0,int(math.floor((min(y1,y2)-r-ymin)/STEP)));j1=min(ny-1,int(math.ceil((max(y1,y2)+r-ymin)/STEP)))
            for i in range(i0,i1+1):
                for j in range(j0,j1+1):
                    x,y=cell(i,j)
                    if point_seg_dist(x,y,x1,y1,x2,y2)<=r:blocked.add((i,j))
    return blocked,nx,ny
def astar(net,start,goal,region):
    xmin,xmax,ymin,ymax=region
    blocked,nx,ny=make_blocked(net,region)
    def snap(p):
        return (max(0,min(nx-1,round((p[0]-xmin)/STEP))),
                max(0,min(ny-1,round((p[1]-ymin)/STEP))))
    s=snap(start);g=snap(goal)
    blocked.discard(s);blocked.discard(g)
    dirs=[(1,0,1),(-1,0,1),(0,1,1),(0,-1,1),
          (1,1,math.sqrt(2)),(1,-1,math.sqrt(2)),(-1,1,math.sqrt(2)),(-1,-1,math.sqrt(2))]
    pq=[(0,0,s,None)];dist={(s,None):0};prev={}
    end=None
    while pq:
        _,cost,u,last=heapq.heappop(pq)
        if cost!=dist.get((u,last)):continue
        if u==g:end=(u,last);break
        for dx,dy,base in dirs:
            v=(u[0]+dx,u[1]+dy)
            if v[0]<0 or v[0]>=nx or v[1]<0 or v[1]>=ny or v in blocked:continue
            turn=0 if last is None or last==(dx,dy) else .08
            nc=cost+base+turn
            key=(v,(dx,dy))
            if nc<dist.get(key,1e99):
                dist[key]=nc;prev[key]=(u,last)
                hx=v[0]-g[0];hy=v[1]-g[1]
                heapq.heappush(pq,(nc+math.hypot(hx,hy),nc,v,(dx,dy)))
    if end is None:raise RuntimeError(f'no route for {net} {start}->{goal}')
    cells=[];cur=end
    while True:
        cells.append(cur[0])
        if cur[0]==s and cur[1] is None:break
        cur=prev[cur]
    cells.reverse()
    pts=[(xmin+i*STEP,ymin+j*STEP) for i,j in cells]
    # Keep only direction changes.
    out=[pts[0]]
    lastdir=None
    for i in range(1,len(pts)):
        dx=round((pts[i][0]-pts[i-1][0])/STEP);dy=round((pts[i][1]-pts[i-1][1])/STEP)
        d=(dx,dy)
        if lastdir is not None and d!=lastdir:out.append(pts[i-1])
        lastdir=d
    out.append(pts[-1])
    # exact endpoints
    if out[0]!=start:out=[start]+out
    if out[-1]!=goal:out.append(goal)
    return out
def add_track(net,pts,width=NEW_W):
    n=b.FindNet(net)
    for a,c in zip(pts,pts[1:]):
        if math.hypot(c[0]-a[0],c[1]-a[1])<.01:continue
        t=pcbnew.PCB_TRACK(b);t.SetNet(n);t.SetLayer(pcbnew.B_Cu);t.SetWidth(iu(width))
        t.SetStart(vec(*a));t.SetEnd(vec(*c));b.Add(t)
def add_via(net,p,width=.65,drill=.3):
    v=pcbnew.PCB_VIA(b);v.SetNet(b.FindNet(net));v.SetPosition(vec(*p))
    v.SetWidth(iu(width));v.SetDrill(iu(drill));v.SetLayerPair(pcbnew.F_Cu,pcbnew.B_Cu);b.Add(v)

# Routes join the preserved, already-validated legacy endpoints.
routes=[
 ('JTAG_TMS',pos(pad_by('J202','JTAG_TMS')),(124.65,99.5),(120,161,93.55,108)),
 ('JTAG_TDI',pos(pad_by('J202','JTAG_TDI')),(127.19,99.5),(120,161,93.55,108)),
 ('JTAG_TDO',pos(pad_by('J202','JTAG_TDO')),(129.73,99.5),(120,161,93.55,108)),
 ('JTAG_TCK',pos(pad_by('J202','JTAG_TCK')),(132.27,99.5),(120,161,93.55,108)),
 ('V3V3',pos(pad_by('J202','V3V3')),(137.35,99.5),(120,161,93.55,108)),
 ('MIDI4',pos(pad_by('J306','MIDI4')),(58.77,89.5),(54,90,67.6,103)),
 ('MIDI5',pos(pad_by('J306','MIDI5')),(54 and 56.23,89.5),(54,90,67.6,103)),
 ('DESKTOP_12V',pos(pad_by('J201','DESKTOP_12V')),(27.27,76.5),(19,105,67.6,104)),
]
escapes={
 'JTAG_TMS':(156.27,93.8),
 'JTAG_TDI':(155.0,98.2),
 'JTAG_TDO':(153.73,93.8),
 'JTAG_TCK':(155.0,93.8),
 'V3V3':(156.27,98.2),
}
for net,start,goal,region in routes:
    ast_start=escapes.get(net,start)
    pts=astar(net,ast_start,goal,region)
    if ast_start!=start:
        pts=[start,ast_start]+pts[1:]
    print(net,len(pts),pts)
    add_track(net,pts)
    if net in {'JTAG_TDO','JTAG_TCK','DESKTOP_12V'}:
        add_via(net,goal,.65 if net!='DESKTOP_12V' else .8,.3 if net!='DESKTOP_12V' else .35)

# Ground target goes straight into the existing internal GND planes.
g=pos(pad_by('J202','GND'))
vg=(153.73,99.0)
add_track('GND',[g,vg])
add_via('GND',vg,.7,.3)

pcbnew.SaveBoard(str(P),b,True)
print('AUTO_ROUTE_DONE')
