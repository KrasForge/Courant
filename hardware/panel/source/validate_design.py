#!/usr/bin/env python3
"""Independent nominal-geometry and electrical-graph checks (NOT native DRC)."""
import json,csv,hashlib,math,collections,itertools
from pathlib import Path
import numpy as np
import shapely
from shapely.geometry import Point,LineString,Polygon
from shapely.strtree import STRtree
from design_data import *
from export_ecad import pad_shape,board_shape,sexp_parse


def main():
 d=json.load(open(ROOT/'design'/'routing.json'));ps=allpads();bd=board_shape();items=[]
 for i,p in enumerate(ps):
  if p['kind']=='np_thru_hole':continue
  ls=['F.Cu','B.Cu','In1.Cu','In2.Cu'] if p['kind']=='thru_hole' else [p['side']+'.Cu']
  items.append({'id':f'pad {p["ref"]}.{p["n"]}#{i}','net':p['net'],'layers':ls,'geom':pad_shape(p),'pad':True})
 for i,t in enumerate(d['tracks']):items.append({'id':f'track {i}','net':t['net'],'layers':[t['layer']],'geom':LineString([t['a'],t['b']]).buffer(t['width']/2,quad_segs=12),'pad':False})
 for i,v in enumerate(d['vias']):items.append({'id':f'via {i}','net':v['net'],'layers':['F.Cu','B.Cu','In1.Cu','In2.Cu'],'geom':Point(v['x'],v['y']).buffer(v['size']/2,quad_segs=16),'pad':False})
 geom=[x['geom'] for x in items];tree=STRtree(geom);viol=[];ed=[]
 for i,a in enumerate(items):
  if not bd.buffer(1e-6).covers(a['geom']):ed.append({'id':a['id'],'kind':'outside outline or in cutout','area':a['geom'].difference(bd).area})
  elif a['geom'].distance(bd.boundary)<.3-1e-5:ed.append({'id':a['id'],'kind':'edge < 0.3 mm','distance':round(a['geom'].distance(bd.boundary),5)})
  for j in tree.query(a['geom'].buffer(.201)):
   j=int(j)
   if j>=i:continue
   b=items[j]
   if a['net'] is not None and a['net']==b['net']:continue
   if not set(a['layers'])&set(b['layers']):continue
   dd=a['geom'].distance(b['geom'])
   if dd<.20-1e-5:viol.append({'a':a['id'],'b':b['id'],'nets':[a['net'],b['net']],'distance':round(dd,5),'overlap_area':round(a['geom'].intersection(b['geom']).area,6)})
 # Track/via connectivity for all NON-GND nets; intentional component internals not shorted.
 parent=list(range(len(items)))
 def find(i):
  while parent[i]!=i:parent[i]=parent[parent[i]];i=parent[i]
  return i
 def join(i,j):
  a=find(i);b=find(j)
  if a!=b:parent[b]=a
 for i,a in enumerate(items):
  if not a['net']:continue
  for j in tree.query(a['geom'].buffer(.002)):
   j=int(j)
   if j>=i:continue
   b=items[j]
   if a['net']==b['net'] and set(a['layers'])&set(b['layers']) and a['geom'].distance(b['geom'])<=.002:join(i,j)
 nets={}
 for i,a in enumerate(items):
  if a['net'] and a['pad']:nets.setdefault(a['net'],{}).setdefault(find(i),[]).append(a['id'])
 gaps={n:list(v.values()) for n,v in nets.items() if n!='GND' and len(v)>1}
 report={'scope':'Custom nominal pad/track/via geometry and exact design graph, NOT native KiCad ERC/DRC, not thermal/signal integrity/manufacturing approval','components':len(PARTS),'pads':len(ps),'nets':len(nets),'tracks':len(d['tracks']),'vias':len(d['vias']),'routed_length_mm':sum(math.dist(t['a'],t['b']) for t in d['tracks']),'minimum_rule_mm':.2,'copper_edge_rule_mm':.3,'copper_clearance_violations':viol,'copper_edge_violations':ed,'disconnected_non_ground_nets':gaps,'ground_status':'Inner GND zone definitions provided. Native KiCad refill required; GND connectivity is not claimed by this test.','native_erc':'NOT RUN','native_drc':'NOT RUN','bench_tests':'NOT RUN','power_budget':'3 A IC target only; system capability not verified'}
 # Pin-for-pin boundary against the uploaded CSV.
 src=ROOT/'reference'/'courant-panel-interface.csv'
 if not src.exists():src=Path('/mnt/data/courant-panel-interface.csv')
 rr=list(csv.DictReader(src.open()));miss=[]
 for r in rr:
  k=int(r['Connector'][1:]);n=int(r['Pin']);exp=MAP[k][n-1]
  if exp!=r['Net']:miss.append(r)
 report['mainboard_pin_crosscheck']={'checked':len(rr),'mismatches':miss}
 # Parse the emitted native files, extract the pin/net graph separately, and match graph data.
 pcb=sexp_parse((ROOT/'design'/'radian_panel.kicad_pcb').read_text());fp_errors=[];stored=0
 for node in pcb:
  if not isinstance(node,list) or node[0]!='footprint':continue
  ref=next((z[2] for z in node if isinstance(z,list) and z[0]=='property' and z[1]=='Reference'),None)
  if not ref:continue
  part=next((p for p in PARTS if p['ref']==ref),None)
  if part is None:continue
  stored+=1
  for pad in [z for z in node if isinstance(z,list) and z[0]=='pad']:
   pin=pad[1];got=next((z[1] for z in pad if isinstance(z,list) and z[0]=='net'),None)
   exp=part['nets'].get(pin)
   if got!=exp:fp_errors.append({'reference':ref,'pin':pin,'actual':got,'expected':exp})
 report['native_pcb_pin_net_crosscheck']={'footprints':stored,'mismatches':fp_errors}
 syntax={}
 for path in list((ROOT/'design').glob('*.kicad_sch'))+list((ROOT/'library'/'RadianPanel.pretty').glob('*.kicad_mod'))+[ROOT/'library'/'RadianPanel.kicad_sym']:
  try:
   node=sexp_parse(path.read_text());ids=[]
   def walk(x):
    if isinstance(x,list):
     if x and x[0]=='uuid':ids.append(x[1])
     for z in x:walk(z)
   walk(node);dups=[x for x,c in collections.Counter(ids).items() if c>1]
   syntax[str(path.relative_to(ROOT))]={'balanced':True,'duplicate_uuids':dups}
  except Exception as e:syntax[str(path.relative_to(ROOT))]={'error':str(e)}
 report['syntax']=syntax
 (ROOT/'reports'/'electrical_geometry_checks.json').write_text(json.dumps(report,indent=2))
 print(json.dumps({k:report[k] for k in ['components','pads','nets','tracks','vias','routed_length_mm','copper_clearance_violations','copper_edge_violations','disconnected_non_ground_nets','native_pcb_pin_net_crosscheck']},indent=2))
 # Evaluate the IDEAL resistor equations independently of PCB wiring; headroom not idealized away in text.
 rng=np.random.default_rng(7);n=20000;r20=200e3*(1+rng.uniform(-.001,.001,n));r21=100e3*(1+rng.uniform(-.001,.001,n));r22=200e3*(1+rng.uniform(-.001,.001,n));rg=10e3*(1+rng.uniform(-.001,.001,n));rf=10e3*(1+rng.uniform(-.001,.001,n));den=1/r20+1/r21+1/r22;gain=(1+rf/rg)/(r20*den);zero=(1+rf/rg)*2.5/(r21*den)
 dc={'model':'Ideal DC resistor network only. Not SPICE, no op-amp macro-model, no switching converter transient simulation. Monte Carlo assumes independent uniform resistor errors +/-0.1%.','mod_nominal_gain':.5,'mod_nominal_zero_V':2.5,'gain_range_sampled':[float(gain.min()),float(gain.max())],'zero_range_sampled_V':[float(zero.min()),float(zero.max())],'rail_endpoint_warning':'Nominal -5/+5 V maps to supply rails: real output swing and loading reduce usable endpoint range. Calibrate/limit firmware range.','power_feedback_nominal_V':.596*(1+(100000+49.9)/13300),'power_EN_at_VRAW_11V':11*105e3/(511e3+105e3),'inductor_ripple_nominal_A_at_VIN12':(.596*(1+(100000+49.9)/13300))*(1-.596*(1+(100000+49.9)/13300)/12)/(10e-6*400e3),'input_power_formula':'I_RACK = (Vout * Iout)/(VIN * converter_efficiency) + housekeeping; unknown actual FPGA load and efficiency'}
 (ROOT/'reports'/'ideal_dc_checks.json').write_text(json.dumps(dc,indent=2))
if __name__=='__main__':main()
