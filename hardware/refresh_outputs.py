#!/usr/bin/env python3
"""Refresh review exports from the repaired native PCBs, never from router intermediates."""
from pathlib import Path
import argparse,collections,csv,hashlib,json,os,shutil,subprocess,tempfile,zipfile
ROOT=Path(__file__).resolve().parent
CLI=os.environ.get('BACKPLANE_KICAD_CLI') or os.environ.get('KICAD_CLI') or shutil.which('kicad-cli')
LOG=[]
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(args):
 cmd=[str(CLI)]+[str(x) for x in args]
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=240)
 LOG.append({'command':cmd,'exit_code':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
 if r.returncode:raise RuntimeError('Command failed: '+str(cmd)+'\n'+r.stdout+r.stderr)
 return r

def checked(board,reports,schematic=None):
 reports.mkdir(parents=True,exist_ok=True)
 if schematic:
  run(['sch','erc','--severity-all','--exit-code-violations','--format','json','-o',reports/'erc.json',schematic])
 args=['pcb','drc','--refill-zones','--all-track-errors','--severity-all','--exit-code-violations','--format','json','-o',reports/'drc.json']
 if schematic:args.append('--schematic-parity')
 run(args+[board]);d=json.loads((reports/'drc.json').read_text())
 if d['violations'] or d['unconnected_items'] or d.get('schematic_parity'):raise RuntimeError('Nonempty DRC report')
 if schematic:run(['sch','export','netlist','--format','kicadxml','-o',reports/'netlist.xml',schematic])
 print('NATIVE CHECKS PASS',board,flush=True)

def svg(board,path,layers,mirror=False):
 path.parent.mkdir(parents=True,exist_ok=True)
 args=['pcb','export','svg','--mode-single','--exclude-drawing-sheet','--fit-page-to-board','--layers',layers,'-o',path]
 if mirror:args.append('--mirror')
 run(args+[board])
 if shutil.which('magick'):
  r=subprocess.run(['magick','-background','white','-density','200',str(path),'-flatten','-resize','2000x',str(path.with_suffix('.png'))],capture_output=True,text=True,timeout=120)
  if r.returncode:raise RuntimeError(r.stderr)

def fabricate(board,folder,copper_layers,stem,protel):
 folder.mkdir(parents=True,exist_ok=True)
 layers=copper_layers+',F.Mask,B.Mask,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,Edge.Cuts'
 args=['pcb','export','gerbers','--check-zones','--subtract-soldermask','--layers',layers,'-o',str(folder)+'/']
 if not protel:args.append('--no-protel-ext')
 run(args+[board])
 run(['pcb','export','drill','--format','excellon','--excellon-units','mm','--excellon-separate-th','--generate-map','--map-format','pdf','-o',str(folder)+'/',board])
 run(['pcb','export','pos','--format','csv','--units','mm','--side','both','-o',folder/(stem+'-pos.csv'),board])
 (folder/'REVIEW_ONLY.txt').write_text('Regenerated from the repaired native PCB. NOT a production release.\nERC/DRC do not establish component correctness, power/thermal/fault behaviour, FPGA operation or physical fit.\n')

def bundle(folder,path,board):
 data={'source_board':str(board.relative_to(ROOT)),'source_sha256':digest(board),'review_only':True,'files':{p.name:digest(p) for p in sorted(folder.iterdir()) if p.is_file() and p.name!='MANIFEST.json'}}
 (folder/'MANIFEST.json').write_text(json.dumps(data,indent=2))
 with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
  for p in sorted(folder.iterdir()):
   if p.is_file():z.write(p,p.name)
 with zipfile.ZipFile(path) as z:assert z.testzip() is None

def metadata(board,folder,panel=False):
 import pcbnew as pcb
 b=pcb.LoadBoard(str(board));fps={f.GetReference():f for f in b.GetFootprints() if f.GetReference()}
 nets=collections.defaultdict(list)
 for f in b.GetFootprints():
  for p in f.Pads():
   if p.GetNetname():nets[p.GetNetname()].append(f.GetReference()+'.'+p.GetNumber())
 out=folder/('radian_panel-netlist.txt' if panel else 'courant-netlist.txt')
 text=['Current repaired native board: '+board.name,str(len(nets))+' nets']
 for name,ps in sorted(nets.items()):text.extend(['',name+' ('+str(len(ps))+')']+['    '+p for p in sorted(ps)])
 out.write_text('\n'.join(text)+'\n')
 if panel:
  path=folder/'BOM.csv';rows=list(csv.DictReader(path.open()));fields=list(rows[0])
  for row in rows:
   f=fps[row['Reference']];row.update(Value=f.GetValue(),Footprint=f.GetFPIDAsString(),Side='B' if f.GetLayer()==pcb.B_Cu else 'F',X_panel_mm=pcb.ToMM(f.GetPosition().x),Y_panel_mm=128.5-pcb.ToMM(f.GetPosition().y))
 else:
  path=folder/'courant-bom.csv';old=list(csv.DictReader(path.open()));fields=list(old[0]);groups={}
  for row in old:
   for ref in row['Reference(s)'].split(','):
    ref=ref.strip()
    # Native board is authoritative: retired/DNP footprints removed from the
    # board must also disappear from regenerated BOM metadata.
    if ref not in fps:continue
    f=fps[ref];r=dict(row);r.update(Value=f.GetValue(),Footprint=f.GetFPIDAsString(),Side='bottom' if f.GetLayer()==pcb.B_Cu else 'top')
    key=tuple(r[k] for k in fields if k not in ('Reference(s)','Qty'))
    if key not in groups:groups[key]=[r,[]]
    groups[key][1].append(ref)
  rows=[]
  for r,refs in groups.values():r.update({'Reference(s)':','.join(refs),'Qty':len(refs)});rows.append(r)
 with path.open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
 return {'footprints':len(list(b.GetFootprints())),'tracks':sum(not isinstance(t,pcb.PCB_VIA) for t in b.GetTracks()),'vias':sum(isinstance(t,pcb.PCB_VIA) for t in b.GetTracks()),'nets':len(nets)}

def mainboard():
 m=ROOT/'courant';src=m/'deliverables';b=src/'courant.kicad_pcb';dist=m/'dist';dist.mkdir(exist_ok=True)
 before=digest(b);checked(b,src/'native_checks')
 for name in ('courant','courant.routed'):
  shutil.copy2(b,dist/(name+'.kicad_pcb'));shutil.copy2(src/'courant.kicad_pro',dist/(name+'.kicad_pro'))
 shutil.copytree(src/'RadianMain.pretty',dist/'RadianMain.pretty',dirs_exist_ok=True);shutil.copy2(src/'fp-lib-table',dist/'fp-lib-table')
 routed=dist/'courant.routed.kicad_pcb';checked(routed,dist/'native_checks')
 run(['pcb','drc','--refill-zones','--all-track-errors','--severity-all','--exit-code-violations','--format','report','-o',dist/'courant.drc.rpt',routed])
 counts=metadata(b,src);shutil.copy2(src/'courant-netlist.txt',dist/'courant.netlist.txt')
 fabricate(routed,dist/'fab','F.Cu,In1.Cu,In2.Cu,In3.Cu,In4.Cu,B.Cu','courant',False)
 shutil.copy2(src/'courant-bom.csv',dist/'fab/courant-bom.csv')
 bundle(dist/'fab',dist/'courant-fab.zip',b)
 svg(b,dist/'courant-top.svg','F.Cu,F.Silkscreen,Edge.Cuts')
 svg(b,dist/'courant-bottom.svg','B.Cu,B.Silkscreen,Edge.Cuts',True)
 svg(b,dist/'route-inner.svg','In1.Cu,In2.Cu,In3.Cu,In4.Cu,Edge.Cuts')
 for dest,source in [('route-top','courant-top'),('route-bottom','courant-bottom')]:
  for ext in ('.svg','.png'):shutil.copy2(dist/(source+ext),dist/(dest+ext))
 shutil.copy2(dist/'courant-top.svg',dist/'courant.pcb.svg')
 shutil.copy2(src/'courant-schematic.svg',dist/'courant.schematic.svg')
 run(['pcb','export','dxf','--mode-single','--output-units','mm','--layers','Edge.Cuts','--output',src/'courant-outline.dxf',b])
 run(['pcb','export','pdf','--mode-single','--black-and-white','--sketch-pads-on-fab-layers','--layers','Edge.Cuts,F.Fab,F.Silkscreen','--output',src/'courant-mechanical.pdf',b])
 assert digest(b)==before
 print('MAINBOARD EXPORTS DONE',counts,flush=True)
 return {'board_sha256':before,'counts':counts}

def panelboard():
 p=ROOT/'panel';b=p/'design/radian_panel.kicad_pcb';s=p/'design/radian_panel.kicad_sch';before=digest(b)
 checked(b,p/'reports/native',s);counts=metadata(b,p/'docs',panel=True)
 fabricate(b,p/'fab','F.Cu,In1.Cu,In2.Cu,B.Cu','radian_panel',True)
 shutil.copy2(p/'docs/BOM.csv',p/'fab/BOM.csv');bundle(p/'fab',p/'radian_panel-fab.zip',b)
 for side in ('F','B'):svg(b,p/'previews'/('pcb_'+side+'.svg'),side+'.Cu,'+side+'.Silkscreen,Edge.Cuts',side=='B')
 run(['sch','export','pdf','--output',p/'docs/RADIAN_Panel_P1_schematic.pdf',s])
 run(['sch','export','svg','--output',str(p/'previews/schematic')+'/',s])
 for n,name in [(1,'power'),(2,'controls'),(4,'mod')]:
  source=p/'previews/schematic'/(name+'.svg')
  if source.exists() and shutil.which('magick'):
   r=subprocess.run(['magick','-background','white','-density','160',str(source),'-flatten','-resize','2400x',str(p/'previews'/('schematic_'+str(n)+'.png'))],capture_output=True,text=True,timeout=120)
   if r.returncode:raise RuntimeError(r.stderr)
 run(['pcb','export','dxf','--mode-single','--output-units','mm','--layers','Edge.Cuts','--output',p/'cad/RADIAN_panel_P1_outline_reference.dxf',b])
 assert digest(b)==before
 print('PANEL EXPORTS DONE',counts,flush=True)
 return {'board_sha256':before,'counts':counts}

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--board',choices=('all','mainboard','panel'),default='all');a=ap.parse_args()
 if not CLI:raise RuntimeError('Set BACKPLANE_KICAD_CLI or install kicad-cli')
 results={};log=ROOT/'CURRENT_EXPORTS.json'
 try:
  if a.board in ('all','mainboard'):results['mainboard']=mainboard()
  if a.board in ('all','panel'):results['panel']=panelboard()
 finally:log.write_text(json.dumps({'review_only':True,'results':results,'commands':LOG},indent=2))
if __name__=='__main__':main()
