#!/usr/bin/env python3
from pathlib import Path
import sys, re
import cadquery as cq

ROOT=Path('/home/ik/ChatGPT/Courant/hardware')
sys.path.insert(0,str(ROOT/'panel/source'))
import build_cad as model

src=ROOT/'panel/cad/RADIAN_P1_desktop_fit_study.step'
a=cq.Assembly.importStep(str(src))

def color_hex(c, default='#30362F'):
    if c is None:return default
    rgb=c.toTuple()[:3]
    return '#'+''.join(f'{max(0,min(255,round(v*255))):02x}' for v in rgb)

# Keep the two real board assemblies, the exact Samtec mating pair, and all
# current panel electrical/mechanical parts including their generic lead/pin
# envelopes. Strip the faceplate/case so the inter-board gap is visible.
items={}
for c in a.children:
    n=c.name
    keep = (
        n in {'P1_BOARD','MAINBOARD_REPAIRED','J17_IPT1_REFERENCE','J18_IPT1_REFERENCE'}
        or re.match(r'^(?:J100|J101|RV[1-6]|ENC1|SW1|D1[0-3]|J30[1-6]|J20[0-2]|F[12]|D[1-4]|U[12]|L1|C(?:[1-7]|20|21)|R(?:[1-5]|20|21|22|23|24)|JP1|SW[34])_(?:body|pins|shaft|bushing)$',n)
    )
    if keep:
        shape=c.obj.moved(c.loc)
        col=color_hex(c.color)
        # Make the mating connectors easier to distinguish in the proof views.
        if n in {'J100_body','J101_body'}: col='#356fa8'
        elif n in {'J17_IPT1_REFERENCE','J18_IPT1_REFERENCE'}: col='#b08a32'
        items[n]=(shape,col)

outdir=ROOT/'panel/previews'
outdir.mkdir(exist_ok=True)
model.export_assy(items,ROOT/'panel/cad/RADIAN_direct_stack_mated.step','RADIAN_DIRECT_STACK_MATED')
model.render(items,outdir/'direct_stack_mated_iso.png',target=(101,64,-20),camera=(300,-210,120),scale=135)
model.render(items,outdir/'direct_stack_mated_side.png',target=(101,64,-20),camera=(101,-260,-20),scale=120,up=(0,0,1))

# Connector-only close-up so all four mating connector bodies are unobscured.
close={}
for n in ['P1_BOARD','MAINBOARD_REPAIRED','J100_body','J101_body','J100_pins','J101_pins','J17_IPT1_REFERENCE','J18_IPT1_REFERENCE']:
    if n in items: close[n]=items[n]
model.render(close,outdir/'direct_stack_connectors_closeup.png',target=(84,67,-20),camera=(250,-180,35),scale=95)
print('STACK_RENDER_PASS',len(items),'items')
print(outdir/'direct_stack_mated_iso.png')
print(outdir/'direct_stack_mated_side.png')
print(outdir/'direct_stack_connectors_closeup.png')
