"""Generate a lossless ball map from AMD's checked-in package file."""
import json,re
from pathlib import Path
root=Path(__file__).resolve().parent.parent
pins=[]
for line in (root/'reference/xc7a35tftg256pkg.txt').read_text().splitlines():
    cols=line.split()
    if cols and re.fullmatch(r'[A-HJ-NPRT](?:[1-9]|1[0-6])',cols[0]):
        pins.append({'ball':cols[0],'function':cols[1],'bank':cols[3]})
assert len(pins)==256 and len({p['ball'] for p in pins})==256
(root/'fpga-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
