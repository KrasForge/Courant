#!/usr/bin/env python3
from pathlib import Path
import re
p=Path('/home/ik/ChatGPT/Courant/hardware/panel/library/RadianPanel.kicad_sym')
s=p.read_text()
pairs=[
('"TO OFF-BOARD MIDI DIN"','"22-27-2021"'),
('"RadianPanel:Header_1x02_P2.54"','"RadianPanel:Molex_22-27-2021_J306_B"'),
('"EURORACK 10 PIN"','"61201021621"'),
('"RadianPanel:IDC_2x05_P2.54_Shrouded"','"RadianPanel:Wurth_61201021621_Exact_B"'),
('"DESKTOP 12 V INPUT"','"22-27-2021"'),
('"JTAG SERVICE"','"22-27-2061"'),
('"RadianPanel:Header_1x06_P2.54"','"RadianPanel:Molex_22-27-2061_J202_B"'),
('"MOD RANGE: 1-2 UNI / 2-3 BI"','"450301014042"'),
('"RadianPanel:Header_1x03_P2.54"','"RadianPanel:Wurth_450301014042_Exact_B"'),
]
# Header_1x02 occurs J201 too, so handle symbol blocks separately instead of global ambiguity.
def block_replace(text,sym,old,new):
    a=text.index(f'(symbol "{sym}"'); b=text.find('\n  (symbol "',a+10)
    if b<0:b=len(text)
    block=text[a:b]
    if old not in block:raise RuntimeError(f'{sym}: missing {old}')
    block=block.replace(old,new)
    return text[:a]+block+text[b:]
s=block_replace(s,'J306','"TO OFF-BOARD MIDI DIN"','"22-27-2021"')
s=block_replace(s,'J306','"RadianPanel:Header_1x02_P2.54"','"RadianPanel:Molex_22-27-2021_J306_B"')
s=block_replace(s,'J200','"EURORACK 10 PIN"','"61201021621"')
s=block_replace(s,'J200','"RadianPanel:IDC_2x05_P2.54_Shrouded"','"RadianPanel:Wurth_61201021621_Exact_B"')
s=block_replace(s,'J201','"DESKTOP 12 V INPUT"','"22-27-2021"')
s=block_replace(s,'J201','"RadianPanel:Header_1x02_P2.54"','"RadianPanel:Molex_22-27-2021_J201_B"')
s=block_replace(s,'J202','"JTAG SERVICE"','"22-27-2061"')
s=block_replace(s,'J202','"RadianPanel:Header_1x06_P2.54"','"RadianPanel:Molex_22-27-2061_J202_B"')
s=block_replace(s,'JP1','"MOD RANGE: 1-2 UNI / 2-3 BI"','"450301014042"')
s=block_replace(s,'JP1','"RadianPanel:Header_1x03_P2.54"','"RadianPanel:Wurth_450301014042_Exact_B"')
# JP1 actual Wurth physical pin numbering.
a=s.index('(symbol "JP1"'); b=s.find('\n  (symbol "',a+10); block=s[a:b]
suba=block.index('(symbol "JP1_1_1"'); subb=block.index('(property "Description"',suba)
pins=block[suba:subb]
for at,num in [('(at -12.7 2.54 0)','3'),('(at -12.7 0.0 0)','1'),('(at -12.7 -2.54 0)','2')]:
    i=pins.index(at); j=pins.find('(pin passive line',i+1); j=len(pins) if j<0 else j
    seg=pins[i:j]
    seg=re.sub(r'\(name "[123]"',f'(name "{num}"',seg)
    seg=re.sub(r'\(number "[123]"',f'(number "{num}"',seg)
    pins=pins[:i]+seg+pins[j:]
block=block[:suba]+pins+block[subb:]
s=s[:a]+block+s[b:]
p.write_text(s)
print('external symbol library synchronized')
