#!/usr/bin/env python3
from pathlib import Path
import re
ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
LIB=ROOT/'courant/deliverables/RadianMain.pretty'

def strip_models(s):
    out=[];i=0
    while i<len(s):
        j=s.find('(model ',i)
        if j<0:
            out.append(s[i:]);break
        out.append(s[i:j]);depth=0;k=j
        while k<len(s):
            if s[k]=='(': depth+=1
            elif s[k]==')':
                depth-=1
                if depth==0:
                    k+=1;break
            k+=1
        i=k
    return ''.join(out)

def clone(src,new,value=None,model=None,rotz=0):
    s=(LIB/(src+'.kicad_mod')).read_text()
    s=strip_models(s)
    s=re.sub(r'^\(footprint "[^"]+"',f'(footprint "{new}"',s,count=1,flags=re.M)
    if value is not None:
        s=re.sub(r'\(property "Value" "[^"]*"',f'(property "Value" "{value}"',s,count=1)
    if model:
        block=(f'\n\t(model "{model}"\n'
               f'\t\t(offset (xyz 0 0 0))\n'
               f'\t\t(scale (xyz 1 1 1))\n'
               f'\t\t(rotate (xyz 0 0 {rotz}))\n\t)\n')
        idx=s.rfind('(embedded_fonts')
        if idx<0: idx=s.rfind(')')
        s=s[:idx]+block+s[idx:]
    (LIB/(new+'.kicad_mod')).write_text(s)
    print(new)

M='${KIPRJMOD}/cad/models/'
clone('resistor_res0603__39c83d2b18','R_0603_1608Metric_Radian','R_0603',M+'R_0603_1608Metric.step')
clone('capacitor_cap0201__dadfb7a195','C_0201_0603Metric_Radian','C_0201',M+'C_0201_0603Metric.step')
clone('capacitor_cap0603__d5291f488c','C_0603_1608Metric_Radian','C_0603',M+'C_0603_1608Metric.step')
clone('capacitor_cap0805__10beff2a36','C_0805_2012Metric_Radian','C_0805',M+'C_0805_2012Metric.step')
clone('capacitor_cap1210__180759c794','C_1210_3225Metric_Radian','C_1210',M+'C_1210_3225Metric.step')
clone('inductor__e5f50d491f','Changjiang_FNR4030S1R0MT','FNR4030S1R0MT',M+'FNR4030S.step')
clone('BAT54S__32fc1a4b3f','Nexperia_BAT54S_215_SOT23','BAT54S,215',M+'SOT-23.step')
clone('BAT54S__32fc1a4b3f','REF3125AIDBZR_SOT23','REF3125AIDBZR',M+'SOT-23.step')
clone('1N4148W__9d65e6bad1','Diodes_1N4148W_7_F_SOD123','1N4148W-7-F',M+'SOD-123.step')
clone('5V_INPUT__f4047b8a89','Molex_22_23_2021_RowY','22-23-2021',M+'Molex_22-23-2021_drawing_reference.step',180)
clone('RESET_GND__232228838d','Molex_22_23_2021_RowX','22-23-2021',M+'Molex_22-23-2021_drawing_reference.step',0)
clone('JTAG_VREF_GND_TCK_TDO_TDI_TMS__2864413b98','Molex_22_23_2061','22-23-2061',M+'Molex_22-23-2061_drawing_reference.step',0)
clone('TPS62130ARGTR__6ea9868580','TPS62130ARGTR_WQFN16','TPS62130ARGTR',M+'WQFN16_3x3_EP1.68.step')
clone('W25Q64JVSSIQ__3f416348df','W25Q64JVSSIQ_SOIC8_208mil','W25Q64JVSSIQ',M+'SOIC8_5.3x5.3_P1.27.step')
clone('MCP3208-CI_SL__76680cdae2','MCP3208_CI_SL_SOIC16','MCP3208-CI/SL',M+'SOIC16_3.9x9.9_P1.27.step')
clone('MCP6002-I_SN__77edb9acaf','MCP6002_I_SN_SOIC8','MCP6002-I/SN',M+'SOIC8_3.9x4.9_P1.27.step')
clone('MCP6561T-E_OT__273f09eb8c','MCP6561T_E_OT_SOT23_5','MCP6561T-E/OT',M+'SOT-23-5.step')
clone('PCM5102APWR__31e6901811','PCM5102APWR_TSSOP20','PCM5102APWR',M+'TSSOP20_4.4x6.5_P0.65.step')
clone('H11L1M__c5e750f5d3','H11L1M_DIP6','H11L1M',M+'DIP6_W7.62_U8_centered.step')
clone('XC7A35T-1FTG256C__c6a6b2a4af','XC7A50T_1FTG256I_FTG256','XC7A50T-1FTG256I',M+'BGA256_17x17_P1.0.step')
clone('ASE-100_000MHZ-LC-T__ae75d0e002','Abracon_ASE_3225_4Pin','Abracon ASE 3225',M+'Oscillator_3225_4Pin.step')
clone('Stack_2x10_P2.54','Samtec_IPT1_110_06_L_D','IPT1-110-06-L-D',
      '${KIPRJMOD}/../../stack/models/Samtec_IPT1-110-06-L-D_drawing_reference.step')
