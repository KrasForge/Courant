#!/usr/bin/env python3
from pathlib import Path
import re,pcbnew

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
DEL=ROOT/'courant/deliverables'
LIB=DEL/'RadianMain.pretty'
BOARD=DEL/'courant.kicad_pcb'
BACK=ROOT/'_backups/mainboard_exact_parts_20260918T042958Z/courant.kicad_pcb'
K='$'+'{KIPRJMOD}'

def strip_models(s):
    out=[];i=0
    while i<len(s):
        j=s.find('(model ',i)
        if j<0:out.append(s[i:]);break
        out.append(s[i:j]);depth=0;k=j
        while k<len(s):
            if s[k]=='(':depth+=1
            elif s[k]==')':
                depth-=1
                if depth==0:k+=1;break
            k+=1
        i=k
    return ''.join(out)

def clone(src,new,value,model):
    s=(LIB/(src+'.kicad_mod')).read_text()
    s=strip_models(s)
    s=re.sub(r'^\(footprint "[^"]+"',f'(footprint "{new}"',s,count=1,flags=re.M)
    s=re.sub(r'\(property "Value" "[^"]*"',f'(property "Value" "{value}"',s,count=1)
    block=(f'\n\t(model "{model}"\n\t\t(offset (xyz 0 0 0))\n'
           f'\t\t(scale (xyz 1 1 1))\n\t\t(rotate (xyz 0 0 0))\n\t)\n')
    idx=s.rfind('(embedded_fonts')
    if idx<0:idx=s.rfind(')')
    s=s[:idx]+block+s[idx:]
    (LIB/(new+'.kicad_mod')).write_text(s)

# Preserve existing geometry variants but give them semantic package names.
cap0201={
 'capacitor_cap0201__093e0f1319':'C_0201_0603Metric_A',
 'capacitor_cap0201__63acabd7b4':'C_0201_0603Metric_B',
 'capacitor_cap0201__ba1a793164':'C_0201_0603Metric_C',
 'capacitor_cap0201__dadfb7a195':'C_0201_0603Metric_D',
 'capacitor_cap0201__f559b25a67':'C_0201_0603Metric_E',
}
for src,new in cap0201.items():
    clone(src,new,'C_0201',K+'/cad/models/C_0201_0603Metric.step')
cap0805={
 'capacitor_cap0805__06f2194478':'C_0805_2012Metric_A',
 'capacitor_cap0805__10beff2a36':'C_0805_2012Metric_B',
}
for src,new in cap0805.items():
    clone(src,new,'C_0805',K+'/cad/models/C_0805_2012Metric.step')
cap1210={
 'capacitor_cap1210__180759c794':'C_1210_3225Metric_A',
 'capacitor_cap1210__6451707d90':'C_1210_3225Metric_B',
}
for src,new in cap1210.items():
    clone(src,new,'C_1210',K+'/cad/models/C_1210_3225Metric.step')

# Connector variants: identical electrical part, different native footprint orientation/drawing.
def connector_clone(src,new,value,model,w,h,model_rotz=0):
    s=(LIB/(src+'.kicad_mod')).read_text()
    s=strip_models(s)
    s=re.sub(r'^\(footprint "[^"]+"',f'(footprint "{new}"',s,count=1,flags=re.M)
    s=re.sub(r'\(property "Value" "[^"]*"',f'(property "Value" "{value}"',s,count=1)
    s=re.sub(r'\(drill 1\)', '(drill 1.02)', s)
    pat=r'\(fp_rect\s+\(start [^\)]*\)\s+\(end [^\)]*\)(.*?)\(layer "F\.CrtYd"\)(.*?)\)'
    repl=(f'(fp_rect\n\t\t(start {-w/2:.4f} {-h/2:.4f})\n'
          f'\t\t(end {w/2:.4f} {h/2:.4f})\\1(layer "F.CrtYd")\\2)')
    s,n=re.subn(pat,repl,s,count=1,flags=re.S)
    if n!=1: raise RuntimeError((src,'courtyard'))
    block=(f'\n\t(model "{model}"\n\t\t(offset (xyz 0 0 0))\n'
           f'\t\t(scale (xyz 1 1 1))\n\t\t(rotate (xyz 0 0 {model_rotz}))\n\t)\n')
    idx=s.rfind('(embedded_fonts')
    if idx<0:idx=s.rfind(')')
    s=s[:idx]+block+s[idx:]
    (LIB/(new+'.kicad_mod')).write_text(s)

connector_clone('5V_INPUT__f4047b8a89','Molex_22_23_2021_RowY','22-23-2021',
                K+'/cad/models/Molex_22-23-2021_drawing_reference.step',5.58,6.85,180)
connector_clone('RESET_GND__232228838d','Molex_22_23_2021_RowX','22-23-2021',
                K+'/cad/models/Molex_22-23-2021_drawing_reference.step',5.58,6.85)

oldb=pcbnew.LoadBoard(str(BACK))
oldid={f.GetReference():f.GetFPIDAsString().split(':')[-1] for f in oldb.GetFootprints() if f.GetReference()}
b=pcbnew.LoadBoard(str(BOARD))
for f in b.GetFootprints():
    ref=f.GetReference()
    if not ref:continue
    oid=oldid[ref]
    if oid in cap0201:f.SetFPIDAsString('RadianMain:'+cap0201[oid])
    if oid in cap0805:f.SetFPIDAsString('RadianMain:'+cap0805[oid])
    if oid in cap1210:f.SetFPIDAsString('RadianMain:'+cap1210[oid])
    if ref=='J1':f.SetFPIDAsString('RadianMain:Molex_22_23_2021_RowY')
    if ref in {'J3','J4'}:f.SetFPIDAsString('RadianMain:Molex_22_23_2021_RowX')
    # Custom procurement fields are metadata, not silkscreen.
    fab=pcbnew.B_Fab if f.GetLayer()==pcbnew.B_Cu else pcbnew.F_Fab
    for name in ['Manufacturer','MPN','LCSC','Notes']:
        fld=f.GetField(name)
        fld.SetVisible(False);fld.SetLayer(fab)
        if hasattr(fld,'SetMirrored'):fld.SetMirrored(f.GetLayer()==pcbnew.B_Cu)
pcbnew.SaveBoard(str(BOARD),b,True)
print('FINAL_LIBRARY_VARIANTS_AND_HIDDEN_FIELDS_APPLIED')
