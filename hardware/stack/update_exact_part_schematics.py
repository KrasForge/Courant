#!/usr/bin/env python3
from pathlib import Path
import re
D=Path('/home/ik/ChatGPT/Courant/hardware/panel/design')

def replace_count(path,old,new,count):
    p=D/path;s=p.read_text();n=s.count(old)
    if n!=count: raise RuntimeError(f'{path}: {old!r} count {n}, expected {count}')
    p.write_text(s.replace(old,new))
    return n

# Exact drop-in production connectors.
replace_count('power.kicad_sch','"EURORACK 10 PIN"','"61201021621"',2)
replace_count('power.kicad_sch','"RadianPanel:IDC_2x05_P2.54_Shrouded"','"RadianPanel:Wurth_61201021621_Exact_B"',2)
replace_count('power.kicad_sch','"SELECT keyed 2x05 IDC 2.54 mm header"','"61201021621"',1)

replace_count('power.kicad_sch','"DESKTOP 12 V INPUT"','"22-27-2021"',2)
replace_count('power.kicad_sch','"RadianPanel:Header_1x02_P2.54"','"RadianPanel:Molex_22-27-2021_J201_B"',2)
replace_count('power.kicad_sch','"SELECT locking 2-pin >=2A connector; P2.54 footprint"','"22-27-2021"',1)

replace_count('io.kicad_sch','"TO OFF-BOARD MIDI DIN"','"22-27-2021"',2)
replace_count('io.kicad_sch','"RadianPanel:Header_1x02_P2.54"','"RadianPanel:Molex_22-27-2021_J306_B"',2)
replace_count('io.kicad_sch','"SELECT 2.54 mm 1x02 header"','"22-27-2021"',1)

replace_count('service.kicad_sch','"JTAG SERVICE"','"22-27-2061"',2)
replace_count('service.kicad_sch','"RadianPanel:Header_1x06_P2.54"','"RadianPanel:Molex_22-27-2061_J202_B"',2)
replace_count('service.kicad_sch','"SELECT 2.54 mm 1x06 header"','"22-27-2061"',1)

# JP1: actual Wurth SPDT pinout. Old schematic positions top/middle/bottom were
# pins 1/2/3 = MOD_RAW/MOD_IN/MOD_BIPOLAR. Actual switch is:
# pin 3 = top MOD_RAW, pin 1 = middle common MOD_IN, pin 2 = bottom MOD_BIPOLAR.
p=D/'mod.kicad_sch';s=p.read_text()
s=s.replace('"MOD RANGE: 1-2 UNI / 2-3 BI"','"450301014042"')
s=s.replace('"RadianPanel:Header_1x03_P2.54"','"RadianPanel:Wurth_450301014042_Exact_B"')
s=s.replace('"2.54 mm 1x03 header + removable shunt"','"450301014042"')
# Symbol definition: edit the three pins by their fixed locations.
start=s.index('(symbol "JP1_1_1"'); end=s.index('(property "Description"',start)
block=s[start:end]
for at,num in [('(at -12.7 2.54 0)','3'),('(at -12.7 0.0 0)','1'),('(at -12.7 -2.54 0)','2')]:
    i=block.index(at); j=block.find('(pin passive line',i+1); j=len(block) if j<0 else j
    seg=block[i:j]
    seg=re.sub(r'\(name "[123]"',f'(name "{num}"',seg)
    seg=re.sub(r'\(number "[123]"',f'(number "{num}"',seg)
    block=block[:i]+seg+block[j:]
s=s[:start]+block+s[end:]
# Instance pin UUIDs follow the same fixed graphical positions.
mapping={
 '031fc1de-f652-56e7-993b-2ddd33f1cf5b':'3',
 'a988563f-0536-5d32-9cf9-0b06dc0ab031':'1',
 '4b7ea1de-3e57-5a72-ba4b-1ca26cb4b4f4':'2'}
for uid,num in mapping.items():
    s=re.sub(r'\(pin "[123]"\s*\(uuid "'+re.escape(uid)+r'"\)\)',f'(pin "{num}"\n      (uuid "{uid}"))',s,count=1)
s=s.replace('DEFAULT: shunt JP1 pins 1-2 = direct unipolar MOD; preserve existing firmware interpretation.',
            'JP1 is an SPDT configuration switch: one throw selects direct unipolar MOD_RAW; the other selects MOD_BIPOLAR.')
p.write_text(s)
print('schematics updated for exact service parts')
