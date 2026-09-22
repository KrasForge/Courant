#!/usr/bin/env python3
"""Reconcile RADIAN generated schematics without changing their electrical graph.
Run only against a backed-up project; native netlist/ERC/DRC are still required.
"""
from pathlib import Path
import json, re, uuid, copy, argparse

def parse(text):
    stack=[]; root=None
    for tok in re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+',text):
        if tok=='(':
            node=[]
            if stack: stack[-1].append(node)
            elif root is not None: raise ValueError('Multiple roots')
            else: root=node
            stack.append(node)
        elif tok==')':
            if not stack: raise ValueError('Unbalanced close')
            stack.pop()
        else: stack[-1].append(tok)
    if stack: raise ValueError('Unclosed expression')
    return root

def children(node,key): return [x for x in node if isinstance(x,list) and x and x[0]==key]
def child(node,key): return next(iter(children(node,key)),None)
def val(tok): return json.loads(tok) if tok.startswith('"') else tok
def q(v): return json.dumps(str(v),ensure_ascii=False)
def number(v): return f'{float(v):.6f}'.rstrip('0').rstrip('.') or '0'
def ident(text): return str(uuid.uuid5(uuid.UUID('7cfa5422-3a38-4c31-a2d2-e3ea799ebfff'),text))

def render(node,level=0):
    if not isinstance(node,list): return node
    if not any(isinstance(x,list) for x in node): return '('+' '.join(node)+')'
    head=[]; tail=[]; seen=False
    for x in node:
        if isinstance(x,list): seen=True
        (tail if seen else head).append(x)
    return '('+' '.join(head)+''.join('\n'+'  '*(level+1)+render(x,level+1) for x in tail)+')'

def properties(node): return {val(x[1]):val(x[2]) for x in children(node,'property')}
def set_property(node,name,value,x=0,y=0):
    p=next((p for p in children(node,'property') if val(p[1])==name),None)
    if p is not None: p[2]=q(value)
    else: node.append(parse(f'(property {q(name)} {q(value)} (at {number(x)} {number(y)} 0) (effects (font (size 1.27 1.27)) hide))'))
def snap(v): return number(round(float(v)/1.27)*1.27)
def snap_at(n):
    a=child(n,'at')
    if a: a[1:3]=[snap(a[1]),snap(a[2])]

FLAG='''(symbol "PWR_FLAG" (power) (pin_names (offset 0) hide) (in_bom yes) (on_board yes)
(property "Reference" "#FLG" (at 0 1.905 0) (effects (font (size 1.27 1.27)) hide))
(property "Value" "PWR_FLAG" (at 0 3.81 0) (effects (font (size 1.27 1.27))))
(property "Footprint" "" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))
(property "Datasheet" "" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))
(property "Description" "ERC power-source declaration; not a physical regulator" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))
(symbol "PWR_FLAG_0_0" (pin power_out line (at 0 0 90) (length 0) (name "~" (effects (font (size 1.27 1.27)))) (number "1" (effects (font (size 1.27 1.27))))))
(symbol "PWR_FLAG_0_1" (polyline (pts (xy 0 0) (xy 0 1.27) (xy -1.016 1.905) (xy 0 2.54) (xy 1.016 1.905) (xy 0 1.27)) (stroke (width 0) (type default)) (fill (type none)))))'''

def add_flags(doc,path):
    libs=child(doc,'lib_symbols'); definition=parse(FLAG); definition[1]=q('RadianPanel:PWR_FLAG')
    if not any(val(x[1])=='RadianPanel:PWR_FLAG' for x in children(libs,'symbol')): libs.append(definition)
    existing={properties(s).get('Reference') for s in children(doc,'symbol')}
    for i,net in enumerate(['GND','VRAW','VIN5'],1):
        ref=f'#FLG0{i}'; x=40.64+(i-1)*129.54; y=347.98
        if ref in existing: continue
        tag=ident('erc-flag:'+net)
        doc.append(parse(f'''(symbol (lib_id "RadianPanel:PWR_FLAG") (at {x} {y} 0) (unit 1) (in_bom yes) (on_board yes) (dnp no) (uuid "{tag}")
(property "Reference" "{ref}" (at {x} {y-1.905} 0) (effects (font (size 1.27 1.27)) hide))
(property "Value" "PWR_FLAG" (at {x} {y-3.81} 0) (effects (font (size 1.27 1.27))))
(pin "1" (uuid "{ident('erc-flag-pin:'+net)}"))
(instances (project "radian_panel" (path "{path}" (reference "{ref}") (unit 1)))))'''))
        doc.append(parse(f'(wire (pts (xy {x} {y}) (xy {x+5.08} {y})) (stroke (width 0) (type default)) (uuid "{ident("erc-wire:"+net)}"))'))
        doc.append(parse(f'(global_label "{net}" (shape bidirectional) (at {x+5.08} {y} 180) (effects (font (size 1.27 1.27)) (justify right)) (uuid "{ident("erc-label:"+net)}"))'))

def fix_schematics(root, metadata=None):
    root=Path(root); design=root/'design'
    if metadata is None:
        pcb=parse((design/'radian_panel.kicad_pcb').read_text())
        meta={properties(f).get('Reference'):properties(f) for f in children(pcb,'footprint')}
    else: meta=metadata
    master=parse((design/'radian_panel.kicad_sch').read_text()); rootid=val(child(master,'uuid')[1])
    power_sheet=next(s for s in children(master,'sheet') if properties(s).get('Sheetfile')=='power.kicad_sch')
    flagpath='/'+rootid+'/'+val(child(power_sheet,'uuid')[1])
    count=0
    for file in sorted(design.glob('*.kicad_sch')):
        doc=parse(file.read_text())
        for inst in children(doc,'symbol'):
            at=child(inst,'at'); x,y=map(float,at[1:3]); snap_at(inst)
            dx,dy=float(at[1])-x,float(at[2])-y
            for prop in children(inst,'property'):
                a=child(prop,'at')
                if a: a[1:3]=[number(float(a[1])+dx),number(float(a[2])+dy)]
            m=meta.get(properties(inst).get('Reference'),{})
            for key in ['Description','Manufacturer']:
                if key in m: set_property(inst,key,m[key],float(at[1]),float(at[2]))
            count+=int(dx!=0 or dy!=0)
        for kind in ['wire','bus']:
            for wire in children(doc,kind):
                for pt in children(child(wire,'pts'),'xy'): pt[1:3]=[snap(pt[1]),snap(pt[2])]
        for kind in ['global_label','label','hierarchical_label','no_connect','junction']:
            for item in children(doc,kind): snap_at(item)
        for definition in children(child(doc,'lib_symbols'),'symbol'):
            m=meta.get(val(definition[1]).split(':')[-1],{})
            for key in ['Description','Manufacturer']:
                if key in m: set_property(definition,key,m[key])
        if file.name=='power.kicad_sch': add_flags(doc,flagpath)
        file.write_text(render(doc)+'\n')
    libfile=root/'library/RadianPanel.kicad_sym'; library=parse(libfile.read_text())
    for definition in children(library,'symbol'):
        m=meta.get(val(definition[1]).split(':')[-1],{})
        for key in ['Description','Manufacturer']:
            if key in m: set_property(definition,key,m[key])
    if not any(val(s[1])=='PWR_FLAG' for s in children(library,'symbol')): library.append(parse(FLAG))
    libfile.write_text(render(library)+'\n')
    return {'moved_symbols':count,'power_source_declarations':['GND','VRAW','VIN5']}

if __name__=='__main__':
    import sys
    print(json.dumps(fix_schematics(sys.argv[1]),indent=2))
