#!/usr/bin/env python3
"""Panel P1 reference CAD from the exact PCB graph. No manufacturer STEP is asserted.
Optional --previous points to the unpacked Rev F.1 CAD package to integrate the case.
"""
from __future__ import annotations
import argparse,json,math,sys
from pathlib import Path
import cadquery as cq
from OCP.Bnd import Bnd_Box
from OCP.BRepBndLib import BRepBndLib
from design_data import ROOT,PARTS,OUTLINE,WINDOWS,MOUNTS,allpads,CONFIG
CAD=ROOT/'cad';(CAD/'models').mkdir(parents=True,exist_ok=True)

def rect(x,y,w,h,z,t):
 return cq.Workplane('XY').box(w,h,t,centered=(False,False,False)).translate((x,y,z)).val()
def cyl(x,y,z,r,h):return cq.Workplane('XY').circle(r).extrude(h).translate((x,y,z)).val()
def ring(x,y,z,ro,ri,h):return cyl(x,y,z,ro,h).cut(cyl(x,y,z-.01,ri,h+.02))
def comp(ss):return cq.Compound.makeCompound(list(ss))
def outline(poly,z,t):return cq.Workplane('XY').polyline(poly).close().extrude(t).translate((0,0,z)).val()
def bb(s):
 b=Bnd_Box();BRepBndLib.AddOptimal_s(s.wrapped,b,False,False);return list(b.Get())
def overlap(a,b):
 x=bb(a);y=bb(b)
 if any(min(x[i+3],y[i+3])-max(x[i],y[i])<1e-6 for i in range(3)):return 0.
 return abs(a.intersect(b).Volume())
def place(s,p):
 if p['side']=='B':s=s.rotate((0,0,0),(0,1,0),180)
 s=s.rotate((0,0,0),(0,0,1),p['angle'])
 return s.translate((p['x'],p['y'],-8 if p['side']=='F' else -9.6))
def localmodel(p):
 f=p['fp'];name=f['name'];w,h=f['body'];z=f['height'];out={}
 if name.startswith('TestPoint'):return {}
 if name.startswith('Bourns_PTV'):
  # Real PTV09A-series mechanical CAD, aligned to the selected
  # PTV09A-4020F-B103 rear-mount footprint. Keep shaft/pins split so the
  # enclosure clearance validator can still test the physical shaft.
  s=cq.importers.importStep(str(CAD/'models'/'Bourns_PTV09A_4020F_family_actual.step')).val()
  ss=s.Solids()
  out['body']=comp([ss[0],ss[5]])
  out['shaft']=ss[1]
  out['pins']=comp(ss[2:5])
  return out
 # Production-selected connector/switch models. These STEP files are aligned to
 # the native footprint local origin; B-side placement is applied by place().
 exact_models={
  'Wurth_61201021621_Exact_B':'Wurth_61201021621_native.step',
  'Molex_22-27-2021_J201_B':'Molex_22-27-2021_centered.step',
  'Molex_22-27-2021_J306_B':'Molex_22-27-2021_centered.step',
  'Molex_22-27-2061_J202_B':'Molex_22-27-2061_centered.step',
  'Wurth_450301014042_Exact_B':'Wurth_450301014042_native.step',
  'WQP518MA_PJ398SM_Vertical':'QingPu_PJ398SM_Knurl_actual.step',
  'SW_PUSH_6x6_P6.5x4.5':'Omron_B3F_1000_centered.step',
  'TI_DDC0006A_SOT23_6':'TPS54302_SOT23_6_package.step',
  'SOIC8_3.9x4.9_P1.27':'OPA2192_SOIC8_package.step',
  'SOT23_BAT54S':'BAT54S_SOT23_package.step',
  'Fuse_1206':'Fuse_1206_package.step',
  'D_SMB':'D_SMB_package.step',
  'R_0603':'R_0603_package.step',
  'C_0603':'C_0603_package.step',
  'C_0805':'C_0805_package.step',
  'C_1210':'C_1210_package.step',
  'LED_D3.0_P2.54':'Kingbright_L934GD_package_green_centered.step',
 }
 if name in exact_models:
  out['body']=cq.importers.importStep(str(CAD/'models'/exact_models[name])).val()
  return out
 if name.startswith('LED_'):
  out['body']=comp([cyl(0,0,7.,1.9,1),cyl(0,0,8.,1.5,3.5),cq.Solid.makeSphere(1.5,cq.Vector(0,0,11.5),angleDegrees1=0,angleDegrees2=90)])
 elif name.startswith('Header_'):
  out['body']=rect(-w/2,-h/2,w,h,0,2.54)
 elif name.startswith('Stack_2x10'):
  # Use the Samtec-drawing-derived IPS1-110-01-L-D model, including all
  # 20 socket towers and through-hole tails. This replaces the old generic
  # rectangular connector envelope in the mechanical assembly.
  model_path=ROOT.parent/'stack'/'models'/'Samtec_IPS1-110-01-L-D_drawing_reference.step'
  out['body']=cq.importers.importStep(str(model_path)).val()
 elif name.startswith('IDC_'):
  out['body']=rect(-w/2,-h/2,w,h,0,z).cut(rect(-3,-h/2+1.5,6,h-3,2,z))
 elif name.startswith('WQP'):
  # Underbody clearance is a separate NPTH in the real board.
  out['body']=rect(-w/2,-h/2,w,h,0,z)
  out['bushing']=ring(0,0,9,3,1.8,5.5)
 elif name.startswith('Bourns_PTV'):
  out['body']=rect(-w/2,-h/2,w,h,0,z)
  out['shaft']=cyl(0,0,z,3,20).cut(rect(1.5,-4,3,8,z,20.1))
 elif name.startswith('Bourns_PEC'):
  out['body']=rect(-w/2,-h/2,w,h,0,z)
  out['bushing']=cyl(0,0,6.5,3.5,7)
  out['shaft']=cyl(0,0,13.5,3,13).cut(rect(1.5,-4,3,8,13.5,13.1))
 elif name.startswith('E_Switch'):
  out['body']=rect(-w/2,-h/2,w,h,0,z)
  out['bushing']=cyl(0,0,z,3.175,6.35)
  out['shaft']=cyl(0,0,z+6.35,1.46,10.41)
 else:out['body']=rect(-w/2,-h/2,w,h,0,max(z,.2))
 # Simple pin references, not manufacturer lead-form geometry.
 pins=[]
 for q in f['pads']:
  if q['kind']=='np_thru_hole':continue
  if q['kind']=='thru_hole':
   if q['n'].startswith('MP'):
    d=q['drill'];dx,dy=d if isinstance(d,list) else (d,d)
    pins.append(rect(q['x']-dx*.32,q['y']-dy*.32,dx*.64,dy*.64,-2.5,2.6))
   else:pins.append(cyl(q['x'],q['y'],-2.6,.28, (11.1 if name.startswith(('Header_','IDC_')) else 10.2 if name.startswith('LED_') else 2.7)))
  else:pins.append(rect(q['x']-q['sx']*.36,q['y']-q['sy']*.36,q['sx']*.72,q['sy']*.72,-.025,.15))
 if pins:out['pins']=comp(pins)
 return out

def board_shape():
 s=outline(OUTLINE,-9.6,1.6)
 for q in WINDOWS:s=s.cut(outline(q,-9.7,1.8))
 tools=[]
 for x,y,d in MOUNTS:tools.append(cyl(x,y,-9.7,d/2,1.8))
 for q in allpads():
  d=q['drill']
  if d is None:continue
  if isinstance(d,list):
   angle=q['angle']+(90 if d[1]>d[0] else 0)
   tool=cq.Workplane('XY').slot2D(max(d),min(d),angle).extrude(1.8).translate((q['X'],q['Y'],-9.7)).val()
  else:tool=cyl(q['X'],q['Y'],-9.7,d/2,1.8)
  tools.append(tool)
 return s.cut(comp(tools)).clean()

def render(items,path,target=(105,64,-8),camera=(270,-200,240),scale=96,up=(0,0,1)):
 import vtk
 rr=vtk.vtkRenderer();rr.SetBackground(.924,.920,.895);rr.SetUseFXAA(True)
 win=vtk.vtkRenderWindow();win.SetOffScreenRendering(1);win.SetSize(1800,1250);win.SetMultiSamples(0);win.AddRenderer(rr)
 for name,(s,col) in items.items():
  mapper=vtk.vtkPolyDataMapper();mapper.SetInputData(s.toVtkPolyData(.05,.18,True));mapper.ScalarVisibilityOff()
  a=vtk.vtkActor();a.SetMapper(mapper);pr=a.GetProperty();pr.SetColor(*tuple(int(col.lstrip('#')[i:i+2],16)/255 for i in (0,2,4)));pr.SetAmbient(.25);pr.SetDiffuse(.7);pr.SetSpecular(.2);pr.SetSpecularPower(30);rr.AddActor(a)
 rr.AutomaticLightCreationOff()
 for xyz,power in [((-100,230,360),.9),((330,-200,250),.65),((100,40,-250),.45)]:
  l=vtk.vtkLight();l.SetLightTypeToSceneLight();l.SetPosition(*xyz);l.SetFocalPoint(*target);l.SetIntensity(power);rr.AddLight(l)
 cam=rr.GetActiveCamera();cam.SetPosition(*camera);cam.SetFocalPoint(*target);cam.SetViewUp(*up);cam.ParallelProjectionOn();cam.SetParallelScale(scale);rr.ResetCameraClippingRange();win.Render()
 im=vtk.vtkWindowToImageFilter();im.SetInput(win);im.SetInputBufferTypeToRGB();im.ReadFrontBufferOff();im.Update();wr=vtk.vtkPNGWriter();wr.SetFileName(str(path));wr.SetInputConnection(im.GetOutputPort());wr.Write();win.Finalize()

def export_assy(items,path,name):
 assy=cq.Assembly(name=name)
 for nm,(s,c) in items.items():
  col=tuple(int(c.lstrip('#')[i:i+2],16)/255 for i in (0,2,4));assy.add(s,name=nm,color=cq.Color(*col))
 assy.export(str(path));return assy

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--previous',type=Path);a=ap.parse_args()
 items={};shapes={};board=board_shape();items['P1_BOARD']=(board,'#265944');shapes['P1_BOARD']=board
 saved=set()
 for p in PARTS:
  local=localmodel(p);nn=p['fp']['name']
  if local and nn not in saved:
   cq.exporters.export(comp(local.values()),str(CAD/'models'/(nn+'.step')));saved.add(nn)
  if not local and nn not in saved:
   # A zero-height copper pad has no physical model; the PCB still carries the net.
   cq.exporters.export(cyl(0,0,0,.8,.025),str(CAD/'models'/(nn+'.step')));saved.add(nn)
  for k,s in local.items():
   nm=p['ref']+'_'+k;ss=place(s,p);color='#A3A899' if k in ['pins','bushing','shaft'] else '#ADC873' if p['ref'] in ['D10','D11','D12','D13'] else '#30362F'
   if p['ref'].startswith(('R','C')) and k=='body':color='#7E7862'
   items[nm]=(ss,color);shapes[nm]=ss
 print('Board and component references built',flush=True)
 cq.exporters.export(board,str(CAD/'RADIAN_P1_bare_board.step'))
 cq.exporters.export(board,str(CAD/'RADIAN_P1_fit_template.stl'),tolerance=.04,angularTolerance=.14)
 export_assy(items,CAD/'RADIAN_P1_populated_reference.step','RADIAN_PANEL_P1_REFERENCE')
 render(items,ROOT/'previews'/'panel_pcb_3d.png')
 report={'scope':'Reference-envelope CAD only. No manufacturer STEP or component lead-form certification. Zero nominal intersections is not fit approval.','board_valid':board.isValid(),'board_solids':len(board.Solids()),'board_bounds_mm':bb(board),'component_reference_count':len(PARTS),'body_only_mechanical_checks':{},'reference_parts_valid':all(s.isValid() for s in shapes.values()),'mainboard_modified':False,'native_KiCad_3D_import':'NOT RUN; local model alignments require native 3D viewer validation'}
 if a.previous:
  old=a.previous;step=old/'step';load=lambda n:cq.importers.importStep(str(step/(n+'.step'))).val()
  keep=['panel','grille','patch_strip','midi_insert','mode_blank','rear_guard','desktop_dock','dock_nuts_reference','corner_support_BL','corner_support_BR','corner_support_TL','corner_support_TR','spacers_reference','midi_support','midi_socket_reference','engraving_reference','accent_reference','patch_ink_reference','mode_ink_reference','screw_heads_reference']
  case={n:load(n) for n in keep}
  case['panel']=case['panel'].cut(comp([cyl(x,y,-.1,1.35,2.2) for x,y in [(24,14),(55,14)]]))
  case['mode_blank']=case['mode_blank'].cut(cyl(150.5,84.5,1.9,3.3,2.2))
  newmounts=comp([ring(x,y,-8,2.5,1.1,8) for x,y,d in MOUNTS]);case['P1_panel_standoffs_REFERENCE']=newmounts
  case['P1_encoder_rear_spacer']=ring(42,43,-1.5,5,3.6,1.5)
  case['P1_jack_rear_shims']=comp([ring(186.5,y,1,4.5,3.1,1) for y in [99,81,63,45,27]])
  case['P1_mode_rear_spacer']=ring(150.5,84.5,.89,5,3.3,1.11)
  case['P1_encoder_nut_REFERENCE']=comp([ring(42,43,2,6,3.6,.5),ring(42,43,2.5,5,3.6,2)])
  case['P1_jack_nuts_REFERENCE']=comp([ring(186.5,y,4,4.5,3.1,.5).fuse(ring(186.5,y,4.5,4.3,3.1,1.5)) for y in [99,81,63,45,27]])
  case['P1_mode_nut_REFERENCE']=ring(150.5,84.5,4,4.5,3.3,2)
  # Knob references only, with a deeper shaft cavity for the revised encoder.
  knobs=[];markers=[]
  for x,y,r in [(42,84,11.5),(80,84,11.5),(118,84,11.5),(42,43,13)]:
   knobs.append(cyl(x,y,6,r,16).cut(cyl(x,y,5.9,3.7,14.6)))
   markers.append(rect(x-.5,y+r-4,1,3,22.01,.05))
  case['P1_knobs_REFERENCE']=comp(knobs);case['P1_markers_REFERENCE']=comp(markers)
  for n,s in case.items():
   color=('#874B40' if n=='panel' else '#D1EB1A' if n=='accent_reference' else '#DDDCCD' if n in ['engraving_reference','patch_ink_reference','mode_ink_reference','P1_markers_REFERENCE'] else '#A3A899' if any(k in n for k in ['nut','spacer','standoff']) else '#292F2A')
   items[n]=(s,color)
  # Export updated flat parts; existing dock remains unchanged.
  for n in ['panel','mode_blank','P1_encoder_rear_spacer','P1_jack_rear_shims','P1_mode_rear_spacer']:
   cq.exporters.export(case[n],str(CAD/(n+'.step')))
  print('Importing unchanged mainboard for fit checks',flush=True)
  mainboard=cq.importers.importStep(str(old/'references'/'pcb_source_aligned.step')).val();items['MAINBOARD_UNCHANGED']=(mainboard,'#2E5745')
  main_solids=[(q,bb(q)) for q in mainboard.Solids()]
  print('Imported main solids',len(main_solids),flush=True)
  def overlap_main(s):
   b=bb(s);total=0.
   for q,d in main_solids:
    if all(min(b[i+3],d[i+3])-max(b[i],d[i])>1e-6 for i in range(3)):total+=abs(s.intersect(q).Volume())
   return total
  tested={'new_board':board}
  for n,s in shapes.items():
   if n!='P1_BOARD' and not n.endswith('_pins'):tested[n]=s
  # Check the new card and all bodies against prior enclosure parts and the mainboard.
  clashes=[]
  for n,s in tested.items():
   print('Fit checking',n,flush=True)
   for k in ['panel','grille','patch_strip','midi_insert','mode_blank','rear_guard','desktop_dock','corner_support_BL','corner_support_BR','corner_support_TL','corner_support_TR','midi_support','midi_socket_reference']:
    v=overlap(s,case[k])
    if v>1e-4:clashes.append({'new':n,'existing':k,'volume_mm3':round(v,5)})
   v=overlap_main(s)
   if v>1e-4:clashes.append({'new':n,'existing':'MAINBOARD','volume_mm3':round(v,5)})
  report['body_only_mechanical_checks']={'positive_volume_intersections':clashes,'exclusions':['leads, solder fillets, cables, fastener threads, torques and inserted plugs','DIN support is retained as a provisional bracket; its socket retention without the former carrier PCB is not validated','generic mating headers are separately bounded, not exact purchased assemblies']}
  mating=[]
  for p in PARTS:
   if p['side']=='B' and p['ref'].startswith('J') and p['ref']!='JP1':
    w,h=p['fp']['body'];s=rect(p['x']-w/2-.4,p['y']-h/2-.5,w+.8,h+1,-25.6,16)
    # Non-shrouded single-row mates are represented by their width, not wire bend volume.
    v=overlap_main(s)
    if v>1e-4:mating.append({'reference':p['ref'],'volume_mm3':round(v,5)})
  report['assumed_16mm_panel_header_envelope_vs_mainboard']=mating
  print('New fit clashes:',clashes,'mated clashes:',mating,flush=True)
  print('Exporting desktop fit-study STEP',flush=True)
  export_assy(items,CAD/'RADIAN_P1_desktop_fit_study.step','RADIAN_P1_DESKTOP_FIT_STUDY')
  render(items,ROOT/'previews'/'desktop_fit_study.png',target=(101,64,-16),camera=(310,-230,300),scale=110)
  # Side-by-side geometry is not faked: lift panel and front controls +60, board +35.
  exploded={}
  for n,(s,c) in items.items():
   if n in ['desktop_dock','dock_nuts_reference','MAINBOARD_UNCHANGED','rear_guard','spacers_reference'] or n.startswith('corner_support'):dz=0
   elif n in shapes:dz=40
   else:dz=65
   exploded[n]=(s.translate((0,0,dz)),c)
  render(exploded,ROOT/'previews'/'stack_exploded.png',target=(101,64,15),camera=(345,-250,245),scale=150)
  report['desktop_dock_geometry']='unchanged from Rev F.1; inlet cutout, strain relief and feet remain provisional'
  report['panel_changes']=['two new M2.5 clearance holes at 24,14 and 55,14','6.6 mm mode-switch bore in existing raised insert','existing shaft and jack locations retained']
 (ROOT/'reports'/'cad_fit_checks.json').write_text(json.dumps(report,indent=2));print('CAD done',flush=True)
if __name__=='__main__':main()
