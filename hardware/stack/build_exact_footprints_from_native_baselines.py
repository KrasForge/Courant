#!/usr/bin/env python3
from pathlib import Path
import re
L=Path('/home/ik/ChatGPT/Courant/hardware/panel/library/RadianPanel.pretty')

def make(src,dst,newname,value,mpn,model,pad_size,drill,renum=None):
    s=(L/(src+'.kicad_mod')).read_text()
    s=s.replace(f'(footprint "{src}"',f'(footprint "{newname}"',1)
    # First Value property only.
    s=re.sub(r'\(property "Value" "[^"]*"',f'(property "Value" "{value}"',s,count=1)
    s=re.sub(r'\(property "MPN" "[^"]*"',f'(property "MPN" "{mpn}"',s,count=1)
    # Native generator footprints use circular/rect pads. Keep the proven pad
    # centers and graphics; only use the selected component's hole/land sizes.
    s=re.sub(r'\(size 1\.8 1\.8\) \(drill 1\)',f'(size {pad_size} {pad_size}) (drill {drill})',s)
    if renum:
        # Replace pad numbers by their relative X coordinate, avoiding swap collisions.
        for old,new in renum.items():
            pat=rf'\(pad "{old}" ([^\n]*?)\(at ([^\n]*?)\)'
        lines=[]
        for line in s.splitlines():
            if line.lstrip().startswith('(pad "') or '(pad "' in line:
                for old,new in renum.items():
                    if f'(pad "{old}"' in line:
                        line=line.replace(f'(pad "{old}"',f'(pad "X{new}"',1);break
            lines.append(line)
        s='\n'.join(lines)+'\n'
        for new in set(renum.values()): s=s.replace(f'(pad "X{new}"',f'(pad "{new}"')
    model_block=f'\n(model "{model}" (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0)))\n'
    i=s.rfind(')')
    s=s[:i]+model_block+s[i:]
    (L/(dst+'.kicad_mod')).write_text(s)

make('IDC_2x05_P2.54_Shrouded','Wurth_61201021621_Exact_B','Wurth_61201021621_Exact_B',
     '61201021621','61201021621','${KIPRJMOD}/../cad/models/Wurth_61201021621_native.step','1.65','1.1')
make('Header_1x02_P2.54','Molex_22-27-2021_J201_B','Molex_22-27-2021_J201_B',
     '22-27-2021','22-27-2021','${KIPRJMOD}/../cad/models/Molex_22-27-2021_centered.step','1.6','1.1')
make('Header_1x02_P2.54','Molex_22-27-2021_J306_B','Molex_22-27-2021_J306_B',
     '22-27-2021','22-27-2021','${KIPRJMOD}/../cad/models/Molex_22-27-2021_centered.step','1.6','1.1')
make('Header_1x06_P2.54','Molex_22-27-2061_J202_B','Molex_22-27-2061_J202_B',
     '22-27-2061','22-27-2061','${KIPRJMOD}/../cad/models/Molex_22-27-2061_centered.step','1.6','1.1')
make('Header_1x03_P2.54','Wurth_450301014042_Exact_B','Wurth_450301014042_Exact_B',
     '450301014042','450301014042','${KIPRJMOD}/../cad/models/Wurth_450301014042_native.step','1.3','.8',
     {'1':'3','2':'1','3':'2'})
print('exact library footprints rebuilt from native baseline families')
