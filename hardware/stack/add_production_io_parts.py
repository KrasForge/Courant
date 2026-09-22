#!/usr/bin/env python3
import pcbnew
from pathlib import Path
ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
P=str(ROOT/'panel/design/radian_panel.kicad_pcb')
LIB=str(ROOT/'panel/library/RadianPanel.pretty')
b=pcbnew.LoadBoard(P)
def net(name):
    n=b.FindNet(name)
    if n:return n
    b.Add(pcbnew.NETINFO_ITEM(b,name))
    return b.FindNet(name)
for n in ['unconnected-(J200-Pad1)','unconnected-(J200-Pad2)',
          'unconnected-(J201-Pad2)','unconnected-(J306-Pad1)',
          'unconnected-(J306-Pad2)','unconnected-(J306-Pad3)']:
    net(n)
def put(name,ref,value,x,y,nets):
    f=pcbnew.FootprintLoad(LIB,name)
    if f is None:raise RuntimeError(name)
    f.SetReference(ref);f.SetValue(value)
    f.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(x),pcbnew.FromMM(y)))
    f.SetFPIDAsString('RadianPanel:'+name)
    for pad in f.Pads():
        nn=nets.get(pad.GetNumber())
        if nn:pad.SetNet(net(nn))
        else:pad.SetNetCode(0)
    b.Add(f)
put('Wurth_61201021621_B','J200','61201021621',175.27,59.42,
    {**{'1':'unconnected-(J200-Pad1)','2':'unconnected-(J200-Pad2)'},
     **{str(i):'GND' for i in range(3,9)},'9':'RACK_12V','10':'RACK_12V'})
put('Wurth_450301014042_B','JP1','450301014042',165.5,40.5,
    {'1':'MOD_IN','2':'MOD_BIPOLAR','3':'MOD_RAW'})
put('Wurth_694106402002_B','J201','694106402002',100.0,95.0,
    {'1':'DESKTOP_12V','2':'unconnected-(J201-Pad2)','3':'GND'})
put('SameSky_SD-50BV','J306','SD-50BV',85.0,85.5,
    {'1':'unconnected-(J306-Pad1)','2':'unconnected-(J306-Pad2)',
     '3':'unconnected-(J306-Pad3)','4':'MIDI4','5':'MIDI5'})
put('TagConnect_TC2030_IDC_NL_B','J202','TC2030-IDC-NL',155.0,96.0,
    {'1':'V3V3','2':'JTAG_TMS','3':'JTAG_TDI',
     '4':'JTAG_TCK','5':'GND','6':'JTAG_TDO'})
pcbnew.SaveBoard(P,b,True)
print('added production footprints')
