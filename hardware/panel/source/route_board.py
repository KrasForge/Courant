#!/usr/bin/env python3
"""Conservative 0.25 mm two-outer-layer draft router, inner layers reserved for GND.
This is NOT KiCad's DRC/router. Routed results must undergo native clearance,
thermal, impedance, return-path, mask and manufacturing review.
"""
import json, math, heapq, time, itertools
import numpy as np
import shapely
from shapely.geometry import Point, LineString
from design_data import *
from export_ecad import pad_shape,board_shape,write_pcb,write_schematic
STEP=.25; NX=821;NY=521;LAYERS=['F.Cu','B.Cu'];CLEAR=.22
PADS=allpads();PG=[pad_shape(p) for p in PADS];BOARD=board_shape()
TRACKS=[];VIAS=[];OBJS=[];LOG=[]

def relevant(p,layer):return p['kind']!='smd' or p['side']==('F' if layer==0 else 'B')
def indices(g):
 a,b,c,d=g.bounds
 return max(0,int(math.floor(a/STEP))),max(0,int(math.floor(b/STEP))),min(NX-1,int(math.ceil(c/STEP))),min(NY-1,int(math.ceil(d/STEP)))
def stamp(a,g,value=True):
 x0,y0,x1,y1=indices(g)
 if x1<x0 or y1<y0:return
 xx=np.arange(x0,x1+1)*STEP; yy=np.arange(y0,y1+1)*STEP
 mask=shapely.intersects_xy(g,xx[None,:],yy[:,None])
 view=a[y0:y1+1,x0:x1+1];view[mask]=value
inside={}
def getinside(r):
 if r not in inside:
  inside[r]=shapely.contains_xy(BOARD.buffer(-r),np.arange(NX)[None,:]*STEP,np.arange(NY)[:,None]*STEP)
 return inside[r]
def copper(t):return LineString([t['a'],t['b']]).buffer(t['width']/2,cap_style='round',quad_segs=6)
def addtrack(a,b,net,width,layer):
 if math.dist(a,b)<.00001:return
 t={'a':[round(float(x),6) for x in a],'b':[round(float(x),6) for x in b],'net':net,'width':width,'layer':layer};TRACKS.append(t);OBJS.append((net,LAYERS.index(layer),copper(t)))
def addvia(x,y,net,size=.7,drill=.3):
 if any(math.hypot(x-v['x'],y-v['y'])<.01 and v['net']==net for v in VIAS):return
 v={'x':round(float(x),6),'y':round(float(y),6),'net':net,'size':size,'drill':drill};VIAS.append(v)
 g=Point(x,y).buffer(size/2,quad_segs=10)
 OBJS.extend([(net,0,g),(net,1,g)])
def clear_geom(g,net,layer,margin=CLEAR):
 if not BOARD.buffer(.0001).covers(g.buffer(.30)):return False
 for p,pg in zip(PADS,PG):
  if relevant(p,layer) and (p['net']!=net or p['net'] is None) and g.distance(pg)<margin-1e-6:return False
 for n,l,og in OBJS:
  if l==layer and n!=net and g.distance(og)<margin-1e-6:return False
 return True

# Local ground stitching. Grounds deliberately depend on native inner-plane refill.
def ground_stitching():
 for p,g in zip(PADS,PG):
  if p['net']!='GND' or p['kind']!='smd':continue
  layer=0 if p['side']=='F' else 1;found=0
  power=p['ref'] in ['U1','C1','C2','C4','C5','C7','D3']
  size,drill=(.8,.4) if power else (.7,.3)
  candidates=[]
  for r in [.85,1.1,1.4,1.8,2.25,2.8,3.3]:
   for a in range(0,360,45):
    x=round((p['X']+r*math.cos(math.radians(a)))/STEP)*STEP;y=round((p['Y']+r*math.sin(math.radians(a)))/STEP)*STEP
    vg=Point(x,y).buffer(size/2,quad_segs=10)
    if vg.intersects(g):continue
    if not all(clear_geom(vg,'GND',l) for l in [0,1]):continue
    # Do not put unfilled vias inside any SMD/NPTH pad, even on their own net.
    if any(vg.intersects(qg) for q,qg in zip(PADS,PG) if q['kind'] in ['smd','np_thru_hole']):continue
    st=LineString([(p['X'],p['Y']),(x,y)]).buffer(.35/2)
    if clear_geom(st,'GND',layer):candidates.append((math.hypot(x-p['X'],y-p['Y']),x,y))
  for _,x,y in sorted(set(candidates)):
   if any(math.hypot(x-v['x'],y-v['y'])<size+.25 for v in VIAS):continue
   addtrack((p['X'],p['Y']),(x,y),'GND',.35,LAYERS[layer]);addvia(x,y,'GND',size,drill);found+=1
   if found>=(2 if power else 1):break
  if found==0:LOG.append({'type':'ground_stitch_failed','pad':p['ref']+'.'+p['n']})

# Wide power routes use short, explicit narrow escapes from the SOT23 pins.
SPECIAL={}
def make_special():
 for net,n,pts in [('SW','2',[(32.9,25),(31.0,25)]),('VRAW','3',[(32.9,24.05),(31.4,24.05),(31.4,22.95)])]:
  okay=all(clear_geom(LineString([a,b]).buffer(.35/2),net,0) for a,b in zip(pts,pts[1:]))
  if not okay:LOG.append({'type':'special_escape_blocked','net':net});continue
  for a,b in zip(pts,pts[1:]):addtrack(a,b,net,.35,'F.Cu')
  SPECIAL[('U1',n)]=dict(X=pts[-1][0],Y=pts[-1][1],kind='smd',side='F',net=net,ref='U1',n=n)

cachedpad={}
def blocks(net,width):
 rad=width/2+CLEAR
 b=np.stack([~getinside(.30+width/2)]*2)
 if net=='SW':
  from shapely.geometry import box
  avoid=box(33.2,23.55,34.8,26.45).buffer(width/2+.2)
  for l in [0,1]:stamp(b[l],avoid)
 cachekey=round(rad,5)
 if cachekey not in cachedpad:cachedpad[cachekey]=[g.buffer(rad,quad_segs=6) for g in PG]
 for p,g in zip(PADS,cachedpad[cachekey]):
  if p['net']==net and p['net'] is not None:continue
  for l in [0,1]:
   if relevant(p,l):stamp(b[l],g)
 for n,l,g in OBJS:
  if n!=net:stamp(b[l],g.buffer(rad,quad_segs=6))
 # Via centre mask with complete two-sided pad and trace clearance.
 vb=~getinside(.7)
 for p,g in zip(PADS,PG):
  if p['net']!=net or p['kind'] in ['smd','np_thru_hole']:stamp(vb,g.buffer(.57,quad_segs=6))
 for n,l,g in OBJS:
  if n!=net:stamp(vb,g.buffer(.57,quad_segs=6))
 pth=np.zeros((NY,NX),bool)
 for p,g in zip(PADS,PG):
  if p['net']==net and p['kind']=='thru_hole':stamp(pth,g.buffer(-.25))
 return b,vb,pth

def endpoint(p,b):
 layers=[0,1] if p['kind']=='thru_hole' else ([0] if p['side']=='F' else [1])
 # Exact pad centres aren't always on grid. Choose a clear, nearby connected grid point.
 opts=[];ix=int(round(p['X']/STEP));iy=int(round(p['Y']/STEP))
 for l in layers:
  for dx,dy in [(0,0)]+list(itertools.product(range(-2,3),repeat=2)):
   xx=ix+dx;yy=iy+dy
   if not (0<=xx<NX and 0<=yy<NY) or b[l,yy,xx]:continue
   d=math.hypot(xx*STEP-p['X'],yy*STEP-p['Y'])
   if d>.55:continue
   if clear_geom(LineString([(p['X'],p['Y']),(xx*STEP,yy*STEP)]).buffer(.125),p['net'],l):opts.append((d,l,xx,yy))
 return sorted(set(opts))[:4]
MOVES=[(-1,0,1),(1,0,1),(0,-1,1),(0,1,1),(-1,-1,1.41421356),(-1,1,1.41421356),(1,-1,1.41421356),(1,1,1.41421356)]
def astar(start,end,net,width,flayers=None,maxsteps=350000):
 b,vb,pth=blocks(net,width);es=endpoint(start,b);ee=endpoint(end,b)
 if flayers is not None:es=[s for s in es if s[1] in flayers];ee=[s for s in ee if s[1] in flayers]
 if not es or not ee:return None,'endpoint blocked',0
 goals={(l,x,y) for _,l,x,y in ee};gx=np.mean([x for _,_,x,_ in ee]);gy=np.mean([y for _,_,_,y in ee]);area=NX*NY
 def enc(l,x,y):return l*area+y*NX+x
 def dec(n):l,rem=divmod(n,area);y,x=divmod(rem,NX);return l,x,y
 def heur(x,y):dx=abs(x-gx);dy=abs(y-gy);return max(dx,dy)+.4142*min(dx,dy)
 gscore={};prev={};heap=[];count=0
 for _,l,x,y in es:
  n=enc(l,x,y);gscore[n]=0;prev[n]=None;heapq.heappush(heap,(heur(x,y),0,n))
 closed=set()
 while heap:
  f0,g0,n=heapq.heappop(heap)
  if n in closed:continue
  closed.add(n);count+=1;l,x,y=dec(n)
  if (l,x,y) in goals:
   path=[]
   while n is not None:path.append(dec(n));n=prev[n]
   return path[::-1],None,count
  if count>maxsteps:return None,'search limit',count
  for dx,dy,cost in MOVES:
   xx=x+dx;yy=y+dy
   if xx<0 or xx>=NX or yy<0 or yy>=NY or b[l,yy,xx]:continue
   if dx and dy and (b[l,y,xx] or b[l,yy,x]):continue
   nn=enc(l,xx,yy);ng=g0+cost
   if ng<gscore.get(nn,1e99):gscore[nn]=ng;prev[nn]=n;heapq.heappush(heap,(ng+heur(xx,yy),ng,nn))
  if flayers is None and (pth[y,x] or (not vb[y,x] and not b[1-l,y,x])):
   nn=enc(1-l,x,y);ng=g0+(.05 if pth[y,x] else 18.)
   if ng<gscore.get(nn,1e99):gscore[nn]=ng;prev[nn]=n;heapq.heappush(heap,(ng+heur(x,y),ng,nn))
 return None,'no path',count

def commit(path,start,end,net,width):
 l,x,y=path[0];addtrack((start['X'],start['Y']),(x*STEP,y*STEP),net,width,LAYERS[l])
 segstart=(x*STEP,y*STEP);lastdir=None;prev=(l,x,y)
 for p in path[1:]:
  ll,xx,yy=p;pl,px,py=prev
  if ll!=pl:
   addtrack(segstart,(px*STEP,py*STEP),net,width,LAYERS[pl]);segstart=(xx*STEP,yy*STEP);lastdir=None
   if not any(q['kind']=='thru_hole' and q['net']==net and g.contains(Point(px*STEP,py*STEP)) for q,g in zip(PADS,PG)):
    addvia(px*STEP,py*STEP,net)
  else:
   dr=(xx-px,yy-py)
   if lastdir is not None and dr!=lastdir:addtrack(segstart,(px*STEP,py*STEP),net,width,LAYERS[ll]);segstart=(px*STEP,py*STEP)
   lastdir=dr
  prev=p
 ll,xx,yy=path[-1];addtrack(segstart,(xx*STEP,yy*STEP),net,width,LAYERS[ll]);addtrack((xx*STEP,yy*STEP),(end['X'],end['Y']),net,width,LAYERS[ll])

def net_nodes(net):return [SPECIAL.get((p['ref'],p['n']),p) for p in PADS if p['net']==net and p['kind']!='np_thru_hole']
def is_heavy(net,p):
 if net=='SW':return p['ref'] in ['U1','L1']
 if net=='VIN5':return p['ref'] in ['L1','C4','C5','J100']
 if net=='VRAW':return p['ref'] in ['D1','D2','D3','C1','C2','C7','U1']
 return net in ['RACK_12V','DESKTOP_12V','RACK_FUSED','DESKTOP_FUSED']

def route_net(net):
 nodes=net_nodes(net)
 if len(nodes)<2:return
 heavy=[p for p in nodes if is_heavy(net,p)]
 light=[p for p in nodes if not is_heavy(net,p)]
 ordered=heavy[:] if heavy else nodes[:]
 connected=[ordered.pop(0)];failed=[]
 phases=[ordered,light[:]] if heavy else [ordered]
 for phase in phases:
  while phase:
   _,ii,jj=min((math.hypot(a['X']-b['X'],a['Y']-b['Y']),i,j) for i,a in enumerate(phase) for j,b in enumerate(connected))
   a=phase.pop(ii);b=connected[jj]
   wide=bool(heavy) and is_heavy(net,a) and is_heavy(net,b)
   width=(1.6 if net=='VIN5' else 1.2 if net in ['VRAW','SW'] else 1.3) if wide else .25
   t0=time.time();path,err,n=astar(a,b,net,width,[0] if wide else None)
   if path:
    commit(path,a,b,net,width);connected.append(a)
   else:failed.append(a)
   LOG.append({'net':net,'from':a['ref']+'.'+a['n'],'to':b['ref']+'.'+b['n'],'width':width,'success':path is not None,'reason':err,'expanded':n,'seconds':round(time.time()-t0,2)})
   print(net,a['ref']+'.'+a['n'],'->',b['ref']+'.'+b['n'],width,'OK' if path else err,flush=True)
 # Failed nodes aren't marked connected. Ratlines remain explicit for honest handoff.

def main():
 ground_stitching();make_special()
 nets=set(p['net'] for p in PADS if p['net'])-{'GND'}
 priority=['SW','BOOT','FB','FF_TOP','EN','VIN5','VRAW','RACK_FUSED','DESKTOP_FUSED','RACK_12V','DESKTOP_12V','VREF25','VREF_BUF','MOD_SUM','MOD_FB','MOD_BIPOLAR']
 order=[n for n in priority if n in nets]+sorted(nets-set(priority),key=lambda n:sum(math.hypot(p['X']-net_nodes(n)[0]['X'],p['Y']-net_nodes(n)[0]['Y']) for p in net_nodes(n)))
 for net in order:
  route_net(net)
  (ROOT/'design'/'routing.json').write_text(json.dumps({'tracks':TRACKS,'vias':VIAS},indent=2));(ROOT/'reports'/'routing_log.json').write_text(json.dumps(LOG,indent=2))
  write_pcb(TRACKS,VIAS)
 write_schematic();save()
 print('TOTAL',len(TRACKS),'tracks',len(VIAS),'vias; failed',sum(1 for x in LOG if x.get('success') is False),flush=True)
if __name__=='__main__':main()
