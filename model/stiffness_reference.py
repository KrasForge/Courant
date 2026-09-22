#!/usr/bin/env python3
"""Bit-exact fixed-point reference for RADIAN bending stiffness (#86).

The production control is one unsigned byte:
    mu2 = STIFFNESS / 4096
and the wave CFL ceiling becomes:
    gamma2 <= min(gamma2_max, 0.5 - STIFFNESS/512)

This script regenerates src/tb/stiffness_trace.txt for a fixed-boundary 8x8
reference case. Integer arithmetic mirrors fdtd_pkg/physical_pkg exactly.
"""
from pathlib import Path
import math

FRAC = 23
QMAX = 2**23 - 1
QMIN = -(2**23)
NX = NY = 8
STEPS = 80

def sat(x):
    return min(max(int(x), QMIN), QMAX)

def toq(x):
    return sat(round(x * 2**FRAC))

def shr23(x):
    return (int(x) + 2**22) // 2**23

def qmul(a, b):
    return sat(shr23(a * b))

def mulc(c, a):
    return shr23(c * a)

def satadd(a, b):
    return sat(a + b)

def stiffness_mu2(ctrl):
    return int(ctrl) << 11

def stiff_gmax(base, ctrl):
    allowed = 2**22 - (int(ctrl) << 14)
    return max(0, min(int(base), allowed))

def biharm(U, i, j):
    def z(y, x):
        if y < 0 or y >= NY or x < 0 or x >= NX:
            return 0
        return U[y][x]
    c = z(i, j)
    first = z(i-1,j)+z(i+1,j)+z(i,j+1)+z(i,j-1)
    diag = z(i-1,j+1)+z(i-1,j-1)+z(i+1,j+1)+z(i+1,j-1)
    second = z(i-2,j)+z(i+2,j)+z(i,j+2)+z(i,j-2)
    return 20*c - 8*first + 2*diag + second

def render():
    g2 = toq(0.08)
    a0 = toq(0.9995)
    sk = toq(0.9995)

    alpha = toq(0.10)
    gmax = toq(0.451)
    ctrl = 0x60
    imp = toq(0.9)
    mu2 = stiffness_mu2(ctrl)
    gmax_eff = stiff_gmax(gmax, ctrl)

    U = [[0 for _ in range(NX)] for _ in range(NY)]
    U1 = [[0 for _ in range(NX)] for _ in range(NY)]
    trace = []
    for step in range(STEPS):
        Un = [[0 for _ in range(NX)] for _ in range(NY)]
        for i in range(NY):
            for j in range(NX):
                c = U[i][j]
                prev = U1[i][j]
                n = U[i-1][j] if i > 0 else 0
                s = U[i+1][j] if i < NY-1 else 0
                e = U[i][j+1] if j < NX-1 else 0
                w = U[i][j-1] if j > 0 else 0
                u2 = qmul(c, c)
                au2 = qmul(alpha, u2)
                g2l = min(max(satadd(g2, au2), 0), gmax_eff)
                lap = n + s + e + w - 4*c
                bend = mulc(mu2, biharm(U, i, j))

                acc = 2*c - mulc(sk, prev) + mulc(g2l, lap) - bend
                out = sat(mulc(a0, acc))
                if step == 0 and i == 4 and j == 4:
                    out = sat(out + imp)
                Un[i][j] = out
        U1, U = U, Un
        trace.append((U[4][2], U[4][6]))
    return trace

def modal_omega(g2, mu2, mx, my):
    # Fixed-boundary discrete eigenvalue of -Laplacian. The plate term is L^2,
    # so its contribution grows quadratically with spatial frequency.
    lam = 4.0 * (
        math.sin(mx * math.pi / (2.0 * (NX + 1))) ** 2
        + math.sin(my * math.pi / (2.0 * (NY + 1))) ** 2
    )
    q = g2 * lam + mu2 * lam * lam
    return math.acos(1.0 - q / 2.0)

def check_dispersion():
    g2 = 0.08
    mu2 = 0x60 / 4096.0
    low0 = modal_omega(g2, 0.0, 1, 1)
    high0 = modal_omega(g2, 0.0, 4, 4)
    low1 = modal_omega(g2, mu2, 1, 1)
    high1 = modal_omega(g2, mu2, 4, 4)
    low_gain = low1 / low0
    high_gain = high1 / high0
    assert high_gain > low_gain > 1.0
    return low_gain, high_gain

def main():
    trace = render()
    low_gain, high_gain = check_dispersion()
    out = Path(__file__).resolve().parent.parent / "src" / "tb" / "stiffness_trace.txt"
    with out.open("w", encoding="utf-8") as f:
        f.write("# L R -- fixed-boundary 8x8, STIFFNESS=0x60, issue #86\n")
        for l, r in trace:
            f.write(f"{l} {r}\n")
    print(f"wrote {len(trace)} stiffness reference steps to {out}")
    print(f"mu2(0x60)={0x60/4096:.8f}; effective gamma2_max={0.5-0x60/512:.8f}")
    print(f"dispersion check: mode(1,1) x{low_gain:.4f}, mode(4,4) x{high_gain:.4f}")

if __name__ == "__main__":
    main()
