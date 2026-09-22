#!/usr/bin/env python3
import pcbnew
P='/home/ik/ChatGPT/Courant/hardware/panel/design/radian_panel.kicad_pcb'
b=pcbnew.LoadBoard(P)
def mm(x): return pcbnew.FromMM(x)
def pt(x,y): return pcbnew.VECTOR2I(mm(x),mm(y))
def tr(net,layer,pts,w=.25):
    n=b.FindNet(net)
    for a,c in zip(pts,pts[1:]):
        t=pcbnew.PCB_TRACK(b);t.SetNet(n);t.SetLayer(layer);t.SetWidth(mm(w))
        t.SetStart(pt(*a));t.SetEnd(pt(*c));b.Add(t)
def via(net,x,y,w=.65,d=.30):
    v=pcbnew.PCB_VIA(b);v.SetNet(b.FindNet(net));v.SetPosition(pt(x,y))
    v.SetWidth(mm(w));v.SetDrill(mm(d));v.SetLayerPair(pcbnew.F_Cu,pcbnew.B_Cu);b.Add(v)

tr('JTAG_TMS',pcbnew.B_Cu,[(106.27,97.365),(108.0,96.0),(111.0,94.0),(115.5,93.0)])
tr('JTAG_TDI',pcbnew.B_Cu,[(105.0,98.635),(105.0,100.5),(108.0,102.0),(111.0,102.5)])

tr('GND',pcbnew.B_Cu,[(103.73,98.635),(103.5,100.0),(100.0,101.5),(96.0,101.5)])
via('GND',96.0,101.5,.70,.30)

# V3V3 goes around the left end of the parallel PROGRAM_B/JTAG lanes:
# rise to F.Cu on the right, cross below those lanes at y=106, then
# return to the existing B.Cu V3V3 trunk at x=59.5,y=105.
tr('V3V3',pcbnew.B_Cu,[(106.27,98.635),(110.0,99.0),(113.5,99.0)])
via('V3V3',113.5,99.0)
tr('V3V3',pcbnew.F_Cu,[(113.5,99.0),(113.5,106.0),(58.5,106.0)])
via('V3V3',58.5,106.0)
tr('V3V3',pcbnew.B_Cu,[(58.5,106.0),(59.5,105.0)])

tr('JTAG_TCK',pcbnew.B_Cu,[(105.0,97.365),(105.0,94.0)])
via('JTAG_TCK',105.0,94.0)
tr('JTAG_TCK',pcbnew.F_Cu,[(105.0,94.0),(109.0,94.0),(113.0,98.0),(113.0,101.0),(111.5,103.0)])

tr('JTAG_TDO',pcbnew.B_Cu,[(103.73,97.365),(103.73,94.5),(100.0,94.5)])
via('JTAG_TDO',100.0,94.5)
tr('JTAG_TDO',pcbnew.F_Cu,[(100.0,94.5),(92.0,94.5),(92.0,102.5),(111.0,102.5)])

pcbnew.SaveBoard(P,b,True)
print('J202 local routes added v4')
