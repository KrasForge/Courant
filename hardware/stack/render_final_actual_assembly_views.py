#!/usr/bin/env python3
from pathlib import Path
import cadquery as cq
import vtk

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
STEP=ROOT/'panel/cad/RADIAN_actual_parts_full_assembly.step'
OUT=ROOT/'panel/previews'
OUT.mkdir(parents=True,exist_ok=True)

assy=cq.Assembly.importStep(str(STEP))
children=[]
for c in assy.children:
    shape=c.obj.moved(c.loc)
    color=c.color.toTuple()[:3] if c.color else (0.2,0.2,0.2)
    children.append((c.name,shape,color))

def render(path,camera,target=(104,64,-12),scale=108,case_opacity=.18):
    rr=vtk.vtkRenderer(); rr.SetBackground(.94,.94,.925); rr.SetUseFXAA(True)
    win=vtk.vtkRenderWindow(); win.SetOffScreenRendering(1); win.SetSize(1800,1250); win.SetMultiSamples(0); win.AddRenderer(rr)
    for name,shape,rgb in children:
        mapper=vtk.vtkPolyDataMapper(); mapper.SetInputData(shape.toVtkPolyData(.04,.15,True)); mapper.ScalarVisibilityOff()
        actor=vtk.vtkActor(); actor.SetMapper(mapper)
        p=actor.GetProperty(); p.SetColor(*rgb)
        p.SetOpacity(case_opacity if name.startswith('CASE_') else 1.0)
        p.SetAmbient(.22); p.SetDiffuse(.72); p.SetSpecular(.25); p.SetSpecularPower(35)
        rr.AddActor(actor)
    rr.AutomaticLightCreationOff()
    for xyz,power in [((-120,240,340),.95),((350,-210,220),.72),((80,40,-220),.35)]:
        l=vtk.vtkLight(); l.SetLightTypeToSceneLight(); l.SetPosition(*xyz); l.SetFocalPoint(*target); l.SetIntensity(power); rr.AddLight(l)
    cam=rr.GetActiveCamera(); cam.SetPosition(*camera); cam.SetFocalPoint(*target); cam.SetViewUp(0,0,1)
    cam.ParallelProjectionOn(); cam.SetParallelScale(scale)
    rr.ResetCameraClippingRange(); win.SetAlphaBitPlanes(1); win.Render()
    im=vtk.vtkWindowToImageFilter(); im.SetInput(win); im.SetInputBufferTypeToRGB(); im.ReadFrontBufferOff(); im.Update()
    w=vtk.vtkPNGWriter(); w.SetFileName(str(path)); w.SetInputConnection(im.GetOutputPort()); w.Write(); win.Finalize()
    print(path)

render(OUT/'actual_parts_full_assembly_iso.png',(305,-205,210),scale=110,case_opacity=.18)
render(OUT/'actual_parts_full_assembly_side.png',(315,64,-10),scale=94,case_opacity=.15)
render(OUT/'actual_parts_full_assembly_front.png',(104,-260,65),target=(104,64,-4),scale=82,case_opacity=.22)
print('FINAL_ACTUAL_ASSEMBLY_VIEWS_PASS',len(children),'colored solids')
