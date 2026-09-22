#!/usr/bin/env python3
"""Bit-exact normalized reference for the #87 physical mallet.

This mirrors physical_pkg + physical_mallet and documents the production
HARDNESS law independently of the RTL. The original floating-point Exciter.m
study remains the SI-scale feasibility/character reference.
"""
from pathlib import Path

FRAC=23
QMAX=2**23-1
QMIN=-(2**23)

def sat(x):
    return max(QMIN,min(QMAX,int(x)))

def toq(x):
    return sat(round(x*(2**FRAC)))

def contact_raw(compression, hardness):
    if compression<=0 or hardness<=0:
        return 0
    sq=0
    for p in range(22,-1,-1):
        if compression & (1<<p):
            sq=compression>>(FRAC-p)
            break
    base=sq
    # Exact RTL: base/2 + (base*hardness + 32)/64.
    return sat((base>>1)+((base*hardness+32)>>6))

def surface_force(compression, hardness):
    return sat(contact_raw(compression,hardness)<<4)

def launch_velocity(strike):
    mag=abs(int(strike))
    if mag>QMAX:
        mag=QMAX
    return mag>>9

def run(hardness, amplitude=0.5, steps=2048, surface=0):
    gap=toq(0.008)
    hx=surface-gap
    hv=launch_velocity(toq(amplitude))
    touched=False
    active=hv!=0 and hardness!=0
    trace=[]
    contacts=0
    for _ in range(steps):
        compression=sat(hx-surface) if active else 0
        raw=contact_raw(compression,hardness) if active else 0
        fout=surface_force(compression,hardness) if active else 0
        stop_after_step = False
        if raw>0:
            touched=True
        elif touched:
            stop_after_step=True
        # RTL performs the semi-implicit update on the separation edge, then
        # clears running via a signal assignment for the following cycle.
        if active:
            vnext=sat(hv-(raw>>7))
            hv=vnext
            hx=sat(hx+vnext)
        if stop_after_step:
            active=False
        compression2=sat(hx-surface) if active else 0
        fout2=surface_force(compression2,hardness) if active else 0
        contact2=active and contact_raw(compression2,hardness)>0
        if contact2:
            contacts+=1
        trace.append((fout2,int(contact2),int(active),hx,hv))
        if not active and touched:
            break
    return contacts,trace

def main():
    fs_mesh=48_000*4
    labels=[("soft",0x20),("medium",0x80),("hard",0xFF)]
    results=[]
    for name,h in labels:
        c,tr=run(h)
        ms=1000*c/fs_mesh
        peak=max(abs(x[0]) for x in tr)
        results.append((name,h,c,ms,peak))
    assert results[0][2]>results[1][2]>results[2][2]
    slow,_=run(0x80,0.20)
    fast,_=run(0x80,0.85)
    assert slow>fast

    out=Path(__file__).resolve().parent.parent/"src"/"tb"/"mallet_trace.txt"
    _,trace=run(0x80,0.50)
    with out.open("w",encoding="utf-8") as f:
        f.write("# force contact active hammer_x hammer_v; HARDNESS=0x80 velocity=0.5\n")
        for row in trace:
            f.write(" ".join(str(x) for x in row)+"\n")

    for name,h,c,ms,peak in results:
        print(f"{name:6s} HARDNESS=0x{h:02X}: contact={c} steps = {ms:.3f} ms, peak force={peak}")
    print(f"velocity check @0x80: 0.20 -> {slow} steps, 0.85 -> {fast} steps")
    print(f"wrote {len(trace)} medium-hardness samples to {out}")

if __name__=="__main__":
    main()
