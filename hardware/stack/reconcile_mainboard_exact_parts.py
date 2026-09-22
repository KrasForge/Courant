#!/usr/bin/env python3
from pathlib import Path
import csv, pcbnew

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
DEL=ROOT/'courant/deliverables'
BOARD=DEL/'courant.kicad_pcb'
BOM=DEL/'courant-bom.csv'

rows=list(csv.DictReader(BOM.open()))
fields=list(rows[0])
for r in rows:
    refs=set(x.strip() for x in r['Reference(s)'].split(','))
    if refs=={'D10','D11','D12'}:
        r['Manufacturer']='Nexperia'
        r['MPN']='BAT54S,215'
        r['Notes']='Nexperia BAT54S,215; SOT-23 dual Schottky diode'
    if refs=={'D20'}:
        r['Manufacturer']='Diodes Incorporated'
        r['MPN']='1N4148W-7-F'
        r['Notes']='Diodes Incorporated 1N4148W-7-F; SOD-123 fast switching diode'
    if refs=={'L1','L2','L3'} and r['Manufacturer'].lower()=='cjiang':
        r['Manufacturer']='Changjiang Electronics'
with BOM.open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); w.writerows(rows)

meta={}
for r in rows:
    for ref in [x.strip() for x in r['Reference(s)'].split(',') if x.strip()]:
        if ref in meta: raise RuntimeError(f'duplicate BOM ref {ref}')
        meta[ref]=r

b=pcbnew.LoadBoard(str(BOARD))
fps={f.GetReference():f for f in b.GetFootprints() if f.GetReference()}
if set(fps)!=set(meta):
    raise RuntimeError(f'BOM/board mismatch board-only={sorted(set(fps)-set(meta))} bom-only={sorted(set(meta)-set(fps))}')

M='$'+'{KIPRJMOD}/cad/models/'
models={
 'R_0603_1608Metric_Radian':(M+'R_0603_1608Metric.step',0),
 'C_0201_0603Metric_Radian':(M+'C_0201_0603Metric.step',0),
 'C_0603_1608Metric_Radian':(M+'C_0603_1608Metric.step',0),
 'C_0805_2012Metric_Radian':(M+'C_0805_2012Metric.step',0),
 'C_1210_3225Metric_Radian':(M+'C_1210_3225Metric.step',0),
 'Changjiang_FNR4030S1R0MT':(M+'FNR4030S.step',0),
 'Nexperia_BAT54S_215_SOT23':(M+'SOT-23.step',0),
 'Diodes_1N4148W_7_F_SOD123':(M+'SOD-123.step',0),
 'REF3125AIDBZR_SOT23':(M+'SOT-23.step',0),
 'TPS62130ARGTR_WQFN16':(M+'WQFN16_3x3_EP1.68.step',0),
 'W25Q64JVSSIQ_SOIC8_208mil':(M+'SOIC8_5.3x5.3_P1.27.step',0),
 'MCP3208_CI_SL_SOIC16':(M+'SOIC16_3.9x9.9_P1.27.step',0),
 'MCP6002_I_SN_SOIC8':(M+'SOIC8_3.9x4.9_P1.27.step',0),
 'MCP6561T_E_OT_SOT23_5':(M+'SOT-23-5.step',0),
 'PCM5102APWR_TSSOP20':(M+'TSSOP20_4.4x6.5_P0.65.step',0),
 'H11L1M_DIP6':(M+'DIP6_W7.62_U8_centered.step',0),
 'XC7A50T_1FTG256I_FTG256':(M+'BGA256_17x17_P1.0.step',0),
 'Abracon_ASE_3225_4Pin':(M+'Oscillator_3225_4Pin.step',0),
 'Molex_22_23_2021_RowY':(M+'Molex_22-23-2021_drawing_reference.step',180),
 'Molex_22_23_2021_RowX':(M+'Molex_22-23-2021_drawing_reference.step',0),
 'Molex_22_23_2061':(M+'Molex_22-23-2061_drawing_reference.step',0),
 'Samtec_IPT1_110_06_L_D':('$'+'{KIPRJMOD}/../../stack/models/Samtec_IPT1-110-06-L-D_drawing_reference.step',0),
}

def semantic_id(f):
    ref=f.GetReference(); old=f.GetFPIDAsString()
    if ref.startswith('R'): return 'R_0603_1608Metric_Radian'
    if ref.startswith('C'):
        if 'cap0201' in old: return 'C_0201_0603Metric_Radian'
        if 'cap0603' in old: return 'C_0603_1608Metric_Radian'
        if 'cap0805' in old: return 'C_0805_2012Metric_Radian'
        if 'cap1210' in old: return 'C_1210_3225Metric_Radian'
    if ref in {'L1','L2','L3'}: return 'Changjiang_FNR4030S1R0MT'
    if ref in {'D10','D11','D12'}: return 'Nexperia_BAT54S_215_SOT23'
    if ref=='D20': return 'Diodes_1N4148W_7_F_SOD123'
    if ref=='J1': return 'Molex_22_23_2021_RowY'
    if ref in {'J3','J4'}: return 'Molex_22_23_2021_RowX'
    if ref=='J2': return 'Molex_22_23_2061'
    if ref in {'J17','J18'}: return 'Samtec_IPT1_110_06_L_D'
    if ref in {'U11','U12','U13'}: return 'TPS62130ARGTR_WQFN16'
    if ref=='U1': return 'XC7A50T_1FTG256I_FTG256'
    if ref=='U2': return 'W25Q64JVSSIQ_SOIC8_208mil'
    if ref=='U3': return 'PCM5102APWR_TSSOP20'
    if ref=='U4': return 'MCP3208_CI_SL_SOIC16'
    if ref=='U5': return 'REF3125AIDBZR_SOT23'
    if ref=='U6': return 'MCP6002_I_SN_SOIC8'
    if ref=='U7': return 'MCP6561T_E_OT_SOT23_5'
    if ref=='U8': return 'H11L1M_DIP6'
    if ref in {'Y1','Y2'}: return 'Abracon_ASE_3225_4Pin'
    raise RuntimeError(f'unclassified {ref} {old}')

def set_model(f,path,rotz):
    ms=f.Models(); ms.clear()
    m=pcbnew.FP_3DMODEL(); m.m_Filename=path; m.m_Show=True; m.m_Opacity=1.0
    m.m_Scale.x=m.m_Scale.y=m.m_Scale.z=1.0
    m.m_Offset.x=m.m_Offset.y=m.m_Offset.z=0.0
    m.m_Rotation.x=m.m_Rotation.y=0.0; m.m_Rotation.z=rotz
    ms.append(m)

for ref,f in fps.items():
    r=meta[ref]
    sid=semantic_id(f)
    f.SetFPIDAsString('RadianMain:'+sid)
    f.SetField('Manufacturer',r['Manufacturer'])
    f.SetField('MPN',r['MPN'])
    f.SetField('LCSC',r['LCSC'])
    f.SetField('Notes',r['Notes'])
    if ref in {'J1','J3','J4'}: f.SetValue('22-23-2021')
    elif ref=='J2': f.SetValue('22-23-2061')
    path,rotz=models[sid]
    set_model(f,path,rotz)

pcbnew.SaveBoard(str(BOARD),b,True)
print('RECONCILED',len(fps),'BOM placements')
for ref in ['J1','J2','J3','J4','J17','J18','U1','U5','Y1','Y2','L1','D10','D20']:
    f=fps[ref]
    print(ref,f.GetValue(),f.GetFPIDAsString(),
          f.GetField('Manufacturer'),f.GetField('MPN'),
          [m.m_Filename for m in f.Models()])
