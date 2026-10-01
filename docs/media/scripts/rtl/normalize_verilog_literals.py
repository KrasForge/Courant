"""Resolve GHDL-emitted constant bit-select syntax unsupported by Verilator 5.020.

    python3 normalize_verilog_literals.py BUILD/synth_top.v

Only expressions N'b0101[INDEX] are replaced with the corresponding one-bit
literal. The VHDL source and every nonconstant expression are left untouched.
"""
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
changes = 0


def replace(m):
    global changes
    width, bits, index = int(m[1]), m[2], int(m[3])
    assert len(bits) == width and 0 <= index < width
    changes += 1
    return "1'b" + bits[-index - 1]


p.write_text(re.sub(r"(\d+)'b([01]+)\[(\d+)\]", replace, s))
print('Constant bit-select syntax normalized:', changes)
