#!/usr/bin/env python3
from pathlib import Path
import cadquery as cq
import vtk
from PIL import Image

ROOT=Path('/home/ik/ChatGPT/Courant')
CAD=ROOT/'hardware/panel/cad'
OUT=ROOT/'RADIAN_PCBs_and_case'
TMP=ROOT/'hardware/panel/previews/presentation_tmp'
TMP.mkdir(parents=True,exist_ok=True)

TOP=(203/255,203/255,228/255)
BOTTOM=(103/255,103/255,128/255)

def load_step(path):
    assy=cq.Assembly.importStep(str(path))
    out=[]
    for c in assy.children:
        out.append((c.name,c.obj.moved(c.loc),c.color.toTuple()[:3] if c.color else (.2,.2,.2)))
    return out

def render(children,path,camera,target,parallel_scale):
    rr=vtk.vtkRenderer()
    rr.GradientBackgroundOn()
    rr.SetBackground(*BOTTOM)
    rr.SetBackground2(*TOP)
    rr.SetUseFXAA(True)
    win=vtk.vtkRenderWindow()
    win.SetOffScreenRendering(1)
    win.SetSize(3536,2464)
    win.SetMultiSamples(0)
    win.AddRenderer(rr)
    for name,shape,rgb in children:
        mapper=vtk.vtkPolyDataMapper()
        mapper.SetInputData(shape.toVtkPolyData(.018,.08,True))
        mapper.ScalarVisibilityOff()
        actor=vtk.vtkActor()
        actor.SetMapper(mapper)
        prop=actor.GetProperty()
        prop.SetColor(*rgb)
        prop.SetAmbient(.18)
        prop.SetDiffuse(.72)
        if any(k in name for k in ('MOLEX','OSC','WURTH','STACK')):
            prop.SetSpecular(.42); prop.SetSpecularPower(52)
        elif 'BOARD' in name:
            prop.SetSpecular(.12); prop.SetSpecularPower(18)
        else:
            prop.SetSpecular(.25); prop.SetSpecularPower(34)
        rr.AddActor(actor)
    rr.AutomaticLightCreationOff()
    for xyz,power in [((-160,250,340),1.0),((320,-220,210),.75),((70,50,-180),.30)]:
        light=vtk.vtkLight()
        light.SetLightTypeToSceneLight()
        light.SetPosition(*xyz); light.SetFocalPoint(*target); light.SetIntensity(power)
        rr.AddLight(light)
    cam=rr.GetActiveCamera()
    cam.SetPosition(*camera); cam.SetFocalPoint(*target); cam.SetViewUp(0,0,1)
    cam.ParallelProjectionOn(); cam.SetParallelScale(parallel_scale)
    rr.ResetCameraClippingRange(); win.Render()
    cap=vtk.vtkWindowToImageFilter()
    cap.SetInput(win); cap.SetInputBufferTypeToRGB(); cap.ReadFrontBufferOff(); cap.Update()
    writer=vtk.vtkPNGWriter()
    writer.SetFileName(str(path)); writer.SetInputConnection(cap.GetOutputPort()); writer.Write()
    win.Finalize()

    im=Image.open(path).convert('RGB')
    im=im.resize((1768,1232),Image.Resampling.LANCZOS)
    im.save(path,optimize=True)

main=load_step(CAD/'RADIAN_actual_parts_main_board.step')
panel=load_step(CAD/'RADIAN_actual_parts_panel_board.step')
render(main,OUT/'01_mainboard_KiCad_actual_parts_U8_aligned.png',
       (250,-170,105),(88,64,-27),88)
render(panel,OUT/'02_panel_KiCad_actual_parts.png',
       (280,-185,150),(108,64,-1),92)
print('PRESENTATION_BOARD_RENDERS_PASS')
