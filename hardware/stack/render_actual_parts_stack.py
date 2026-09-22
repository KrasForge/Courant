#!/usr/bin/env python3
from pathlib import Path
import json
import cadquery as cq
from OCP.Bnd import Bnd_Box
from OCP.BRepBndLib import BRepBndLib

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
D=ROOT/'stack/actual_parts'
OUT_CAD=ROOT/'panel/cad'
OUT_PRE=ROOT/'panel/previews'

# Raw KiCad STEP uses x=native-x, y=-native-y, board B-face z=0.
# Product transforms are derived from the native board contracts.
PANEL_T=(0.0,128.5,-9.6)         # panel B PCB face = -9.60 mm
MAIN_T=(-12.0,164.25,-31.10)     # main F PCB face = -29.59 mm (raw top=1.51)
TARGET_GAP=19.99

groups=[
 ('panel_board','panel-board-raw.step',PANEL_T,'#285C45'),
 ('panel_pots','panel-pots-raw.step',PANEL_T,'#313531'),
 ('panel_encoder','panel-encoder-raw.step',PANEL_T,'#444744'),
 ('panel_mode','panel-mode-raw.step',PANEL_T,'#323432'),
 ('panel_jacks','panel-jacks-only-raw.step',PANEL_T,'#202321'),
 ('panel_leds','panel-leds-only-raw.step',PANEL_T,'#49A65B'),
 ('panel_samtec','panel-samtec-raw.step',PANEL_T,'#181A19'),
 ('panel_wurth','panel-wurth-raw.step',PANEL_T,'#252826'),
 ('panel_molex','panel-molex-raw.step',PANEL_T,'#E6E1CF'),
 ('panel_buttons','panel-buttons-raw.step',PANEL_T,'#252525'),
 ('panel_ics','panel-ics-raw.step',PANEL_T,'#222422'),
 ('panel_resistors','panel-resistors-raw.step',PANEL_T,'#B6A47E'),
 ('panel_capacitors','panel-capacitors-raw.step',PANEL_T,'#A9825B'),
 ('panel_power_discretes','panel-power-discretes-raw.step',PANEL_T,'#4A4741'),

 ('main_board','main-board-raw.step',MAIN_T,'#20573F'),
 ('main_ics','main-ics-only-raw.step',MAIN_T,'#222422'),
 ('main_service_connectors','main-service-connectors-raw.step',MAIN_T,'#E6E1CF'),
 ('main_samtec','main-samtec-raw.step',MAIN_T,'#181A19'),
 ('main_resistors','main-resistors-raw.step',MAIN_T,'#B6A47E'),
 ('main_capacitors','main-capacitors-raw.step',MAIN_T,'#A9825B'),
 ('main_diodes','main-diodes-raw.step',MAIN_T,'#252525'),
 ('main_inductors','main-inductors-raw.step',MAIN_T,'#474A47'),
 ('main_oscillators','main-oscillators-raw.step',MAIN_T,'#BFC4C5'),
]

def bbox(shape):
    b=shape.BoundingBox()
    return [b.xmin,b.ymin,b.zmin,b.xmax,b.ymax,b.zmax]

def load():
    out={}
    for name,fn,t,col in groups:
        p=D/fn
        if not p.exists(): raise RuntimeError(f'missing {p}')
        s=cq.importers.importStep(str(p)).val().translate(t)
        out[name]=(s,col)
    return out

def export(items,path):
    assy=cq.Assembly(name='RADIAN_ACTUAL_PARTS_STACK')
    for name,(shape,c) in items.items():
        rgb=tuple(int(c.lstrip('#')[i:i+2],16)/255 for i in (0,2,4))
        assy.add(shape,name=name,color=cq.Color(*rgb))
    assy.export(str(path))

def render(items,path,camera,target=(105,64,-13),scale=100,up=(0,0,1)):
    import vtk
    rr=vtk.vtkRenderer();rr.SetBackground(.92,.92,.90);rr.SetUseFXAA(True)
    win=vtk.vtkRenderWindow();win.SetOffScreenRendering(1);win.SetSize(1800,1250);win.SetMultiSamples(0);win.AddRenderer(rr)
    for name,(s,c) in items.items():
        mapper=vtk.vtkPolyDataMapper();mapper.SetInputData(s.toVtkPolyData(.04,.15,True));mapper.ScalarVisibilityOff()
        a=vtk.vtkActor();a.SetMapper(mapper)
        rgb=tuple(int(c.lstrip('#')[i:i+2],16)/255 for i in (0,2,4))
        p=a.GetProperty();p.SetColor(*rgb);p.SetAmbient(.22);p.SetDiffuse(.72);p.SetSpecular(.28);p.SetSpecularPower(35)
        rr.AddActor(a)
    rr.AutomaticLightCreationOff()
    for xyz,power in [((-120,240,330),.95),((350,-210,210),.70),((80,40,-220),.35)]:
        l=vtk.vtkLight();l.SetLightTypeToSceneLight();l.SetPosition(*xyz);l.SetFocalPoint(*target);l.SetIntensity(power);rr.AddLight(l)
    cam=rr.GetActiveCamera();cam.SetPosition(*camera);cam.SetFocalPoint(*target);cam.SetViewUp(*up);cam.ParallelProjectionOn();cam.SetParallelScale(scale)
    rr.ResetCameraClippingRange();win.Render()
    im=vtk.vtkWindowToImageFilter();im.SetInput(win);im.SetInputBufferTypeToRGB();im.ReadFrontBufferOff();im.Update()
    w=vtk.vtkPNGWriter();w.SetFileName(str(path));w.SetInputConnection(im.GetOutputPort());w.Write();win.Finalize()

items=load()
export(items,OUT_CAD/'RADIAN_actual_parts_stack.step')
render(items,OUT_PRE/'actual_parts_stack_iso.png',(300,-205,205),scale=104)
render(items,OUT_PRE/'actual_parts_stack_side.png',(310,64,-12),scale=92,up=(0,0,1))
render(items,OUT_PRE/'actual_parts_panel_closeup.png',(260,-125,155),target=(108,65,-2),scale=78)

pb=bbox(items['panel_board'][0]); mb=bbox(items['main_board'][0])

# OCC expands transformed STEP bounding boxes by representation tolerances.
# The physical PCB-face gap must therefore use the *raw* KiCad board faces and
# the exact product transforms rather than transformed OCC bounding boxes.
raw_pb=cq.importers.importStep(str(D/'panel-board-raw.step')).val().BoundingBox()
raw_mb=cq.importers.importStep(str(D/'main-board-raw.step')).val().BoundingBox()
panel_back_face=PANEL_T[2]+raw_pb.zmin
main_front_face=MAIN_T[2]+raw_mb.zmax
gap=panel_back_face-main_front_face

# Detailed boolean collision validation is kept in a separate, lightweight
# validator so the renderer does not duplicate a high-memory OCC workload.
collision_path=ROOT/'stack/actual-parts-collision-validation.json'
if not collision_path.exists():
    raise RuntimeError('run validate_actual_parts_collisions.py before rendering')
collision=json.loads(collision_path.read_text())
enclosure_clashes=collision['actual_components_vs_physical_enclosure_clashes']
panel_main_clashes=collision['non_samtec_panel_vs_main_clashes']
panel_main_overlap=collision['non_samtec_panel_vs_main_overlap_mm3']

status='PASS' if (
    collision['status']=='PASS' and
    abs(gap-TARGET_GAP)<0.001 and
    not enclosure_clashes and
    not panel_main_clashes
) else 'FAIL'

report={
 'status':status,
 'assembly':'panel/cad/RADIAN_actual_parts_stack.step',
 'panel_board_occ_bbox_mm':[round(x,4) for x in pb],
 'main_board_occ_bbox_mm':[round(x,4) for x in mb],
 'physical_faces':{
   'panel_back_face_z_mm':round(panel_back_face,4),
   'main_front_face_z_mm':round(main_front_face,4),
   'pcb_face_gap_mm':round(gap,4),
   'target_gap_mm':TARGET_GAP,
   'method':'raw KiCad STEP board faces + exact product transforms; transformed OCC bounding boxes are not used for face spacing'
 },
 'actual_part_collision_validation':{
   'component_vs_physical_enclosure_clashes':enclosure_clashes,
   'non_samtec_panel_vs_main_clashes':panel_main_clashes,
   'non_samtec_panel_vs_main_overlap_mm3':round(panel_main_overlap,7)
 },
 'group_bboxes_mm':{n:[round(x,3) for x in bbox(s)] for n,(s,_) in items.items()},
 'model_policy':{
   'native_placement':'all component geometry is exported component-filtered by KiCad from the canonical .kicad_pcb files, so PCB placement/orientation is native',
   'real_open_models':['panel RV1-RV6 PTV09A family body with selected 20 mm shaft','panel J301-J305 PJ398SM open mechanical CAD','panel SW3/SW4 Omron B3F model'],
   'package_accurate_models':['LED 3 mm green package','TPS54302 SOT-23-6','OPA2192 SOIC-8','BAT54S SOT-23','standard passives/fuses/SMB packages','mainboard IC/passive package models'],
   'drawing_reference_models':['Samtec J17/J18/J100/J101','Molex J1-J4','panel PEC11R encoder','panel E-Switch MODE','panel SRP7050TA inductor'],
   'not_claimed_as_vendor_step':'drawing-reference models above remain explicit mechanical references, not manufacturer STEP downloads'
 }
}
(ROOT/'stack/actual-parts-render-validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
if status!='PASS':
    raise SystemExit('ACTUAL_PARTS_STACK_VALIDATION_FAILED')
print('ACTUAL_PARTS_STACK_RENDER_PASS')
