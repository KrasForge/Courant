#!/usr/bin/env python3
from pathlib import Path
import shutil, datetime, pcbnew

ROOT=Path('/home/ik/ChatGPT/Courant')
MAIN=ROOT/'hardware/courant/deliverables/courant.kicad_pcb'
PANEL=ROOT/'hardware/panel/design/radian_panel.kicad_pcb'
stamp=datetime.datetime.now().strftime('%Y%m%dT%H%M%S')

for p in (MAIN,PANEL):
    backup=p.with_name(p.stem+f'.before_colored_actual_models_{stamp}'+p.suffix)
    shutil.copy2(p,backup)
    print('BACKUP',backup)

def set_model(f,path,off=(0,0,0),rot=(0,0,0)):
    ms=f.Models(); ms.clear()
    m=pcbnew.FP_3DMODEL()
    m.m_Filename=path; m.m_Show=True; m.m_Opacity=1.0
    m.m_Scale.x=m.m_Scale.y=m.m_Scale.z=1.0
    m.m_Offset.x,m.m_Offset.y,m.m_Offset.z=off
    m.m_Rotation.x,m.m_Rotation.y,m.m_Rotation.z=rot
    ms.append(m)

b=pcbnew.LoadBoard(str(MAIN))
fps={f.GetReference():f for f in b.GetFootprints() if f.GetReference()}
set_model(fps['U8'],
 '${KICAD10_3DMODEL_DIR}/Package_DIP.3dshapes/DIP-6_W7.62mm.step',
 (-3.81,2.54,0))
pcbnew.SaveBoard(str(MAIN),b,True)
print('MAIN_UPDATED',MAIN)
b=pcbnew.LoadBoard(str(PANEL))
fps={f.GetReference():f for f in b.GetFootprints() if f.GetReference()}

M='${KIPRJMOD}/../cad/models/'
for ref in ['RV1','RV2','RV3','RV4','RV5','RV6']:
    set_model(fps[ref],M+'Bourns_PTV09A_4020F_family_actual_colored.step')
set_model(fps['ENC1'],M+'Bourns_PEC11R_4220F_S0024_drawing_reference_colored.step')
set_model(fps['SW1'],M+'E_Switch_100SP1T1B1M2REH_drawing_reference_colored.step')
set_model(fps['L1'],M+'Bourns_SRP7050TA_100M_drawing_reference_colored.step')
for ref in ['TP1','TP2','TP3','TP4','TP5']:
    set_model(fps[ref],M+'TestPoint_D2_colored.step')

for ref in ['D10','D11','D12','D13']:
    set_model(fps[ref],
      '${KICAD10_3DMODEL_DIR}/LED_THT.3dshapes/LED_D3.0mm_Green.step',
      (-1.27,0,0))
for ref in ['SW3','SW4']:
    set_model(fps[ref],
      '${KICAD10_3DMODEL_DIR}/Button_Switch_THT.3dshapes/SW_TH_Tactile_Omron_B3F-100x.step',
      (-3.25,2.25,0))
for ref in ['J201','J306']:
    set_model(fps[ref],
      '${KICAD10_3DMODEL_DIR}/Connector_Molex.3dshapes/Molex_KK-254_AE-6410-02A_1x02_P2.54mm_Vertical.step',
      (-1.27,0,0))
set_model(fps['J202'],
  '${KICAD10_3DMODEL_DIR}/Connector_Molex.3dshapes/Molex_KK-254_AE-6410-06A_1x06_P2.54mm_Vertical.step',
  (-6.35,0,0))

set_model(fps['JP1'],M+'production/Wurth_450301014042.stp')
set_model(fps['J200'],M+'production/Wurth_61201021621.stp',
          (0.325,0,4.675),(0,0,-90))

pcbnew.SaveBoard(str(PANEL),b,True)
print('PANEL_UPDATED',PANEL)
