#!/usr/bin/env python3
from pathlib import Path
import pcbnew,re

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
BOARD=ROOT/'courant/deliverables/courant.kicad_pcb'
LIB=ROOT/'courant/deliverables/RadianMain.pretty'
b=pcbnew.LoadBoard(str(BOARD))
K='$'+'{KIPRJMOD}'

def mm(x): return pcbnew.FromMM(x)
def set_ctyd(f,w,h):
    shapes=[g for g in f.GraphicalItems() if g.GetLayer()==pcbnew.F_CrtYd and hasattr(g,'SetStart')]
    if len(shapes)!=1: raise RuntimeError(f'{f.GetReference()} expected 1 courtyard, got {len(shapes)}')
    g=shapes[0]; p=f.GetPosition()
    g.SetStart(pcbnew.VECTOR2I(p.x-mm(w/2),p.y-mm(h/2)))
    g.SetEnd(pcbnew.VECTOR2I(p.x+mm(w/2),p.y+mm(h/2)))
    g.SetWidth(mm(.05))
def set_model(f,path,rotz=0):
    ms=f.Models(); ms.clear()
    m=pcbnew.FP_3DMODEL();m.m_Filename=path;m.m_Show=True;m.m_Opacity=1.0
    m.m_Scale.x=m.m_Scale.y=m.m_Scale.z=1.0
    m.m_Offset.x=m.m_Offset.y=m.m_Offset.z=0.0
    m.m_Rotation.x=m.m_Rotation.y=0.0;m.m_Rotation.z=rotz
    ms.append(m)

for ref in ['J1','J2','J3','J4']:
    f=next(x for x in b.GetFootprints() if x.GetReference()==ref)
    for pad in f.Pads():
        pad.SetDrillSize(pcbnew.VECTOR2I(mm(1.02),mm(1.02)))
    if ref=='J2':
        f.SetFPIDAsString('RadianMain:Molex_22_23_2061')
        set_ctyd(f,15.5876,6.85)
        set_model(f,K+'/cad/models/Molex_22-23-2061_drawing_reference.step')
    else:
        f.SetFPIDAsString('RadianMain:Molex_22_23_2021')
        if abs((f.GetOrientationDegrees()%180)-90)<1e-6:
            set_ctyd(f,6.85,5.58)
        else:
            set_ctyd(f,5.58,6.85)
        set_model(f,K+'/cad/models/Molex_22-23-2021_drawing_reference.step',180 if ref=='J1' else 0)

pcbnew.SaveBoard(str(BOARD),b,True)

def make_lib(src,new,value,model,body_w,body_h):
    s=(LIB/(src+'.kicad_mod')).read_text()
    while '(model ' in s:
        j=s.find('(model '); depth=0;k=j
        while k<len(s):
            if s[k]=='(':depth+=1
            elif s[k]==')':
                depth-=1
                if depth==0:k+=1;break
            k+=1
        s=s[:j]+s[k:]
    s=re.sub(r'^\(footprint "[^"]+"',f'(footprint "{new}"',s,count=1,flags=re.M)
    s=re.sub(r'\(property "Value" "[^"]*"',f'(property "Value" "{value}"',s,count=1)
    s=re.sub(r'\(drill 1\)', '(drill 1.02)', s)
    pat=r'\(fp_rect\s+\(start [^\)]*\)\s+\(end [^\)]*\)(.*?)\(layer "F\.CrtYd"\)(.*?)\)'
    repl=(f'(fp_rect\n\t\t(start {-body_w/2:.4f} {-body_h/2:.4f})\n'
          f'\t\t(end {body_w/2:.4f} {body_h/2:.4f})\\1(layer "F.CrtYd")\\2)')
    s,n=re.subn(pat,repl,s,count=1,flags=re.S)
    if n!=1: raise RuntimeError(f'{src}: courtyard replacement failed')
    block=(f'\n\t(model "{model}"\n\t\t(offset (xyz 0 0 0))\n'
           f'\t\t(scale (xyz 1 1 1))\n\t\t(rotate (xyz 0 0 0))\n\t)\n')
    idx=s.rfind('(embedded_fonts')
    if idx<0:idx=s.rfind(')')
    s=s[:idx]+block+s[idx:]
    (LIB/(new+'.kicad_mod')).write_text(s)

make_lib('RESET_GND__232228838d','Molex_22_23_2021','22-23-2021',
         K+'/cad/models/Molex_22-23-2021_drawing_reference.step',5.58,6.85)
make_lib('JTAG_VREF_GND_TCK_TDO_TDI_TMS__2864413b98','Molex_22_23_2061','22-23-2061',
         K+'/cad/models/Molex_22-23-2061_drawing_reference.step',15.5876,6.85)
print('MOLEX_PACKAGE_FIX_APPLIED')
