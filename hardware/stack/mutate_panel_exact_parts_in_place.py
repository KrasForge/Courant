#!/usr/bin/env python3
from pathlib import Path
import pcbnew
ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
BOARD=str(ROOT/'panel/design/radian_panel.kicad_pcb')
b=pcbnew.LoadBoard(BOARD)

spec={
 'J200':dict(value='61201021621',fpid='RadianPanel:Wurth_61201021621_Exact_B',
             mpn='61201021621',model='${KIPRJMOD}/../cad/models/Wurth_61201021621_native.step',drill=1.10,size=(1.65,1.65)),
 'J201':dict(value='22-27-2021',fpid='RadianPanel:Molex_22-27-2021_J201_B',
             mpn='22-27-2021',model='${KIPRJMOD}/../cad/models/Molex_22-27-2021_centered.step',drill=1.19,size=(1.74,2.19)),
 'J306':dict(value='22-27-2021',fpid='RadianPanel:Molex_22-27-2021_J306_B',
             mpn='22-27-2021',model='${KIPRJMOD}/../cad/models/Molex_22-27-2021_centered.step',drill=1.19,size=(1.74,2.19)),
 'J202':dict(value='22-27-2061',fpid='RadianPanel:Molex_22-27-2061_J202_B',
             mpn='22-27-2061',model='${KIPRJMOD}/../cad/models/Molex_22-27-2061_centered.step',drill=1.19,size=(1.74,2.19)),
 'JP1':dict(value='450301014042',fpid='RadianPanel:Wurth_450301014042_Exact_B',
            mpn='450301014042',model='${KIPRJMOD}/../cad/models/Wurth_450301014042_native.step',drill=.80,size=(1.30,1.30)),
}
for ref,cfg in spec.items():
    f=next(x for x in b.GetFootprints() if x.GetReference()==ref)
    f.SetValue(cfg['value']); f.SetFPIDAsString(cfg['fpid'])
    f.SetField('MPN',cfg['mpn'])
    # Schematic source currently has blank Manufacturer fields; keep parity exact.
    f.SetField('Manufacturer','')
    for p in f.Pads():
        p.SetDrillSize(pcbnew.VECTOR2I(pcbnew.FromMM(cfg['drill']),pcbnew.FromMM(cfg['drill'])))
        p.SetSize(pcbnew.VECTOR2I(pcbnew.FromMM(cfg['size'][0]),pcbnew.FromMM(cfg['size'][1])))
    models=f.Models(); models.clear()
    m=pcbnew.FP_3DMODEL();m.m_Filename=cfg['model'];m.m_Show=True;m.m_Opacity=1.0
    m.m_Scale.x=m.m_Scale.y=m.m_Scale.z=1.0
    m.m_Offset.x=m.m_Offset.y=m.m_Offset.z=0.0
    m.m_Rotation.x=m.m_Rotation.y=m.m_Rotation.z=0.0
    models.append(m)

# Actual Wurth 450301014042 pin numbering while keeping the native copper
# endpoints exactly where they are:
# right = physical 3 / MOD_RAW, centre = physical 1 / MOD_IN,
# left = physical 2 / MOD_BIPOLAR.
f=next(x for x in b.GetFootprints() if x.GetReference()=='JP1')
pads=sorted(list(f.Pads()),key=lambda p:pcbnew.ToMM(p.GetPosition().x),reverse=True)
# absolute X descending: right, centre, left
for p,num,net in zip(pads,['3','1','2'],['MOD_RAW','MOD_IN','MOD_BIPOLAR']):
    p.SetNumber(num); p.SetNet(b.FindNet(net))

pcbnew.SaveBoard(BOARD,b,True)
for ref in spec:
    f=next(x for x in b.GetFootprints() if x.GetReference()==ref)
    print(ref,f.GetValue(),f.GetFPIDAsString(),
          [(p.GetNumber(),p.GetNetname(),round(pcbnew.ToMM(p.GetPosition().x),2),round(pcbnew.ToMM(p.GetPosition().y),2)) for p in f.Pads()],
          [m.m_Filename for m in f.Models()])
