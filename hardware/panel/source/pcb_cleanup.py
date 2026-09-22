#!/usr/bin/env python3
"""Native KiCad metadata/artwork reconciliation. Never reroutes copper."""
from pathlib import Path
import json, copy, xml.etree.ElementTree as ET
import pcbnew
from native_cleanup import parse,render,children,child,val,q

def xy(v): return (v.x,v.y)
def copper_signature(board):
    tracks=[]
    for t in board.GetTracks():
        item=[t.GetClass(),t.GetNetname(),xy(t.GetStart()),xy(t.GetEnd()),(t.GetWidth(pcbnew.F_Cu) if isinstance(t,pcbnew.PCB_VIA) else t.GetWidth()),t.GetLayer()]
        if isinstance(t,pcbnew.PCB_VIA): item.append(t.GetDrillValue())
        tracks.append(item)
    pads=[]
    for f in board.GetFootprints():
        for p in f.Pads():
            net=p.GetNetname(); net='' if net.startswith('unconnected-') else net
            pads.append([f.GetReference(),p.GetNumber(),xy(p.GetPosition()),xy(p.GetSize()),xy(p.GetDrillSize()),p.GetShape(),round(p.GetOrientationDegrees()%180,5),net,p.GetLayerSet().FmtHex()])
    return {'tracks':sorted(tracks,key=str),'pads':sorted(pads,key=str)}

def missing_mount_library(root):
    board=parse((root/'design/radian_panel.kicad_pcb').read_text())
    mounts=[f for f in children(board,'footprint') if val(f[1])=='RadianPanel:Mount_NPTH']
    if not mounts: return
    signatures={render([p for p in children(f,'pad')][0]) for f in mounts}
    normalized=[]
    for f in mounts:
        pad=copy.deepcopy(children(f,'pad')[0]);pad[:]=[n for n in pad if not (isinstance(n,list) and n[0]=='uuid')]; normalized.append(render(pad))
    assert len(set(normalized))==1,'Mount diameters differ: separate library members required'
    f=copy.deepcopy(mounts[0]);f[1]=q('Mount_NPTH')
    f[:]=[n for n in f if not (isinstance(n,list) and n[0] in ['at','uuid'])]
    f.insert(2,['version','20260206']);f.insert(3,['generator',q('radian_native_cleanup')])
    for p in children(f,'pad'):p[:]=[n for n in p if not (isinstance(n,list) and n[0]=='uuid')]
    (root/'library/RadianPanel.pretty/Mount_NPTH.kicad_mod').write_text(render(f)+'\n')

def normalize_back_footprints(board,root):
    changes=[]; temp=pcbnew.BOARD()
    for f in board.GetFootprints():
        if f.GetLayer()!=pcbnew.B_Cu or abs(f.GetOrientationDegrees())>1e-6:continue
        lib=pcbnew.FootprintLoad(str(root/'library/RadianPanel.pretty'),f.GetFPID().GetLibItemName())
        if lib is None:raise ValueError('Missing library: '+f.GetReference())
        temp.Add(lib);lib.SetPosition(f.GetPosition());lib.Flip(lib.GetPosition(),pcbnew.FLIP_DIRECTION_LEFT_RIGHT)
        oldpad=sorted((p.GetNumber(),xy(p.GetPosition()),xy(p.GetSize()),xy(p.GetDrillSize())) for p in f.Pads())
        newpad=sorted((p.GetNumber(),xy(p.GetPosition()),xy(p.GetSize()),xy(p.GetDrillSize())) for p in lib.Pads())
        assert oldpad==newpad,'Cannot normalize without moving copper: '+f.GetReference()
        fields=[(a,xy(a.GetPosition()),a.GetTextAngleDegrees()) for a in f.GetFields()]
        pads=[(p,xy(p.GetPosition())) for p in f.Pads()]
        f.SetOrientationDegrees(180)
        for p,pos in pads:p.SetPosition(pcbnew.VECTOR2I(*pos))
        for field,pos,angle in fields:
            field.SetPosition(pcbnew.VECTOR2I(*pos));field.SetTextAngleDegrees(angle)
        oldgroups={};newgroups={}
        for g in f.GraphicalItems():oldgroups.setdefault((g.GetLayer(),g.GetShape()),[]).append(g)
        for g in lib.GraphicalItems():newgroups.setdefault((g.GetLayer(),g.GetShape()),[]).append((xy(g.GetStart()),xy(g.GetEnd())))
        assert set(oldgroups)==set(newgroups)
        for key,old in oldgroups.items():
            new=sorted(newgroups[key]);assert len(old)==len(new)
            for g,(start,end) in zip(old,new):
                g.SetStart(pcbnew.VECTOR2I(*start));g.SetEnd(pcbnew.VECTOR2I(*end))
        for model in f.Models():
            model.m_Rotation.z+=180
            model.m_Offset.x=-model.m_Offset.x;model.m_Offset.y=-model.m_Offset.y
        changes.append(f.GetReference())
    return changes

def fix_board(root,netlist):
    root=Path(root).resolve();missing_mount_library(root)
    target=root/'design/radian_panel.kicad_pcb';board=pcbnew.LoadBoard(str(target))
    before=copper_signature(board);normalized=normalize_back_footprints(board,root)
    refs={f.GetReference():f for f in board.GetFootprints() if f.GetReference()};assigned=[]
    for net in ET.parse(netlist).getroot().findall('nets/net'):
        name=net.get('name','')
        if not name.startswith('unconnected-'):continue
        nodes=net.findall('node');assert len(nodes)==1,'Expected a one-pin isolated net'
        ref,pin=nodes[0].get('ref'),nodes[0].get('pin')
        pad=[p for p in refs[ref].Pads() if p.GetNumber()==pin];assert len(pad)==1
        assert pad[0].GetNetname() in ['',name],'Refusing to replace an existing signal net'
        ni=board.FindNet(name)
        if ni is None:
            ni=pcbnew.NETINFO_ITEM(board,name);board.Add(ni)
        pad[0].SetNet(ni);assigned.append([ref,pin,name])
    after=copper_signature(board)
    assert before==after,'Copper geometry, functional pad nets or routing changed'
    pcbnew.SaveBoard(str(target),board,True)
    check=pcbnew.LoadBoard(str(target));assert copper_signature(check)==before
    result={'normalized_back_footprints':normalized,'isolated_pad_net_metadata':assigned,'copper_and_signal_nets_unchanged':True}
    (root/'reports/pcb_metadata_repair.json').write_text(json.dumps(result,indent=2))
    return result

if __name__=='__main__':
    import argparse
    ap=argparse.ArgumentParser();ap.add_argument('root');ap.add_argument('netlist');a=ap.parse_args()
    print(json.dumps(fix_board(a.root,a.netlist),indent=2))
