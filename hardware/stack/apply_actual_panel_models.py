#!/usr/bin/env python3
from pathlib import Path
import pcbnew, re, shutil

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
PANEL=ROOT/'panel'
BOARD=PANEL/'design/radian_panel.kicad_pcb'
LIB=PANEL/'library/RadianPanel.pretty'
MODELS=PANEL/'cad/models'
K='$'+'{KIPRJMOD}/../cad/models/'

# Store the open/actual component CAD in the project.
shutil.copy('/tmp/musicvis/Schematic_PCB/Music_Visualizer/Project_Library/PTV09A_Pot_Vertical/PTV09A-4225F-B104.step',
            MODELS/'SOURCE_Bourns_PTV09A_family.step')
shutil.copy('/tmp/audiojacks/AudioJacks.3dshapes/PJ398SM_Knurl_nut.step',
            MODELS/'QingPu_PJ398SM_Knurl_actual.step')
shutil.copy('/usr/share/kicad/3dmodels/Button_Switch_THT.3dshapes/SW_TH_Tactile_Omron_B3F-100x.step',
            MODELS/'SOURCE_Omron_B3F_100x.step')
shutil.copy('/usr/share/kicad/3dmodels/LED_THT.3dshapes/LED_D3.0mm_Green.step',
            MODELS/'SOURCE_LED_D3_Green.step')

paths={
 'PTV':K+'Bourns_PTV09A_4020F_family_actual.step',
 'PEC':K+'Bourns_PEC11R_4220F_S0024_drawing_reference.step',
 'SW1':K+'E_Switch_100SP1T1B1M2REH_drawing_reference.step',
 'JACK':K+'QingPu_PJ398SM_Knurl_actual.step',
 'B3F':K+'Omron_B3F_1000_centered.step',
 'LED':K+'Kingbright_L934GD_package_green_centered.step',
}

b=pcbnew.LoadBoard(str(BOARD))
groups={
 'PTV':[f'RV{i}' for i in range(1,7)],
 'PEC':['ENC1'],
 'SW1':['SW1'],
 'JACK':[f'J30{i}' for i in range(1,6)],
 'B3F':['SW3','SW4'],
 'LED':[f'D{i}' for i in range(10,14)],
}

def set_model(fp,path):
    ms=fp.Models(); ms.clear()
    m=pcbnew.FP_3DMODEL(); m.m_Filename=path; m.m_Show=True; m.m_Opacity=1.0
    m.m_Scale.x=m.m_Scale.y=m.m_Scale.z=1.0
    m.m_Offset.x=m.m_Offset.y=m.m_Offset.z=0.0
    m.m_Rotation.x=m.m_Rotation.y=m.m_Rotation.z=0.0
    ms.append(m)

fps={f.GetReference():f for f in b.GetFootprints()}
for key,refs in groups.items():
    for ref in refs:
        set_model(fps[ref],paths[key])
pcbnew.SaveBoard(str(BOARD),b,True)

# Keep the corresponding footprint library definitions synchronized.
fp_names={
 'PTV':'Bourns_PTV09A4_RearFacing.kicad_mod',
 'PEC':'Bourns_PEC11R4_RearFacing_Switch.kicad_mod',
 'SW1':'E_Switch_100SP_M2.kicad_mod',
 'JACK':'WQP518MA_PJ398SM_Vertical.kicad_mod',
 'B3F':'SW_PUSH_6x6_P6.5x4.5.kicad_mod',
 'LED':'LED_D3.0_P2.54.kicad_mod',
}
def replace_model(path,new_model):
    s=path.read_text()
    start=s.find('(model ')
    if start<0:
        idx=s.rfind(')')
        block=f'\n  (model "{new_model}"\n    (offset (xyz 0 0 0))\n    (scale (xyz 1 1 1))\n    (rotate (xyz 0 0 0))\n  )\n'
        s=s[:idx]+block+s[idx:]
    else:
        depth=0; end=None
        for i in range(start,len(s)):
            if s[i]=='(': depth+=1
            elif s[i]==')':
                depth-=1
                if depth==0:
                    end=i+1; break
        block=f'(model "{new_model}"\n    (offset (xyz 0 0 0))\n    (scale (xyz 1 1 1))\n    (rotate (xyz 0 0 0))\n  )'
        s=s[:start]+block+s[end:]
    path.write_text(s)

for key,name in fp_names.items():
    replace_model(LIB/name,paths[key])

for key,refs in groups.items():
    print(key,paths[key],refs)
print('ACTUAL_PANEL_MODELS_APPLIED')
