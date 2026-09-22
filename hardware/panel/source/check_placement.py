import json
from design_data import *
from export_ecad import pad_shape,board_shape
from shapely.geometry import Polygon
P=allpads();G=[pad_shape(p) for p in P];bd=board_shape();viol=[]
for i,p in enumerate(P):
 if p['kind']=='np_thru_hole':continue
 if not bd.buffer(.01).covers(G[i]):viol.append({'type':'pad_edge','pad':p['ref']+'.'+p['n'],'overlap_area':G[i].difference(bd).area})
 for j in range(i):
  q=P[j]
  common=(p['kind']!='smd' or q['kind']!='smd' or p['side']==q['side'])
  if not common:continue
  if p['net'] and p['net']==q['net']:continue
  if q['kind']=='np_thru_hole':minc=.25
  else:minc=.20
  d=G[i].distance(G[j])
  if d<minc-1e-5:viol.append({'type':'pad_clearance','a':p['ref']+'.'+p['n'],'b':q['ref']+'.'+q['n'],'mm':round(d,4),'overlap':round(G[i].intersection(G[j]).area,4)})
print(json.dumps(viol,indent=2));print('violations',len(viol));(ROOT/'reports'/'placement.json').write_text(json.dumps({'violations':viol,'scope':'Nominal pad-to-pad and pad-to-board containment only; not native KiCad DRC or physical fit.'},indent=2))
