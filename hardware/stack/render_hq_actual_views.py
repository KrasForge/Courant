#!/usr/bin/env python3
from pathlib import Path
import cadquery as cq
import vtk

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
OUT=ROOT/'panel/previews/hq'
OUT.mkdir(parents=True,exist_ok=True)

def load_step(path):
    assy=cq.Assembly.importStep(str(path))
    out=[]
    for c in assy.children:
        shape=c.obj.moved(c.loc)
        rgb=c.color.toTuple()[:3] if c.color else (0.2,0.2,0.2)
        out.append((c.name,shape,rgb))
    return out

def render(children,path,camera,target,scale,case_opacity=1.0):
    rr=vtk.vtkRenderer()
    rr.SetBackground(.94,.94,.925)
    rr.SetUseFXAA(True)
    win=vtk.vtkRenderWindow()
    win.SetOffScreenRendering(1)
    win.SetSize(3840,2160)
    win.SetMultiSamples(0)
    win.AddRenderer(rr)
    for name,shape,rgb in children:
        mapper=vtk.vtkPolyDataMapper()
        mapper.SetInputData(shape.toVtkPolyData(.025,.10,True))
        mapper.ScalarVisibilityOff()
        actor=vtk.vtkActor()
        actor.SetMapper(mapper)
        prop=actor.GetProperty()
        prop.SetColor(*rgb)
        prop.SetOpacity(case_opacity if name.startswith('CASE_') else 1.0)
        prop.SetAmbient(.20)
        prop.SetDiffuse(.74)
        prop.SetSpecular(.28)
        prop.SetSpecularPower(42)
        rr.AddActor(actor)
    rr.AutomaticLightCreationOff()
    for xyz,power in [((-160,260,380),1.0),((390,-240,250),.72),((70,30,-260),.32)]:
        light=vtk.vtkLight()
        light.SetLightTypeToSceneLight()
        light.SetPosition(*xyz)
        light.SetFocalPoint(*target)
        light.SetIntensity(power)
        rr.AddLight(light)
    cam=rr.GetActiveCamera()
    cam.SetPosition(*camera)
    cam.SetFocalPoint(*target)
    cam.SetViewUp(0,0,1)
    cam.ParallelProjectionOn()
    cam.SetParallelScale(scale)
    rr.ResetCameraClippingRange()
    win.Render()
    im=vtk.vtkWindowToImageFilter()
    im.SetInput(win)
    im.SetInputBufferTypeToRGB()
    im.ReadFrontBufferOff()
    im.Update()
    writer=vtk.vtkPNGWriter()
    writer.SetFileName(str(path))
    writer.SetInputConnection(im.GetOutputPort())
    writer.Write()
    win.Finalize()
    print(path)

panel=load_step(ROOT/'panel/cad/RADIAN_actual_parts_panel_board.step')
main=load_step(ROOT/'panel/cad/RADIAN_actual_parts_main_board.step')
full=load_step(ROOT/'panel/cad/RADIAN_actual_parts_full_assembly.step')

render(main,OUT/'01_mainboard_top_4k.png',(250,-170,105),(88,64,-27),88)
render(main,OUT/'02_mainboard_bottom_4k.png',(245,-165,-130),(88,64,-31),88)
render(panel,OUT/'03_panel_top_4k.png',(280,-185,150),(108,64,-1),92)
render(panel,OUT/'04_panel_bottom_4k.png',(275,-175,-125),(108,64,-10),92)
render(full,OUT/'05_full_assembly_iso_4k.png',(305,-205,210),(104,64,-12),110,.18)
render(full,OUT/'06_full_assembly_front_4k.png',(104,-260,65),(104,64,-4),82,.22)
render(full,OUT/'07_full_assembly_side_4k.png',(315,64,-10),(104,64,-12),94,.15)
print('HQ_4K_RENDERS_PASS')
