#!/usr/bin/env python3
"""
Power budget for the 5 V input, computed from the board's own rail loading.

This is a budget, not a measurement. Every line is a datasheet or engineering
figure with its basis stated, given as a low/high pair rather than a single
number, because the only honest answer before a board exists is a range. The
question it settles is whether a Eurorack case's +5 V rail can run this: the
source specifies "5 V / 3 A", which is headroom rather than draw, and 3 A would
exclude most cases.

FPGA dynamic power is the term nobody can pin down without a synthesis run and
a switching activity file; the range below is deliberately wide at that line.

    python3 scripts/power.py
"""
from __future__ import annotations

if __name__ == "__main__":
 from pathlib import Path as _NativePath
 if (_NativePath(__file__).resolve().parents[1]/"NATIVE_BASELINE.json").exists():
  raise SystemExit('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')


# rail, part, low mA, high mA, basis
LOADS = [
    ("V1 (1.0 V)", "U1 VCCINT, 9 pins", 150, 600,
     "A50T static ~40 mA; the rest is the FDTD mesh and voices at 100 MHz. "
     "Widest term in the budget -- needs synthesis + activity to narrow"),
    ("V1V8 (1.8 V)", "U1 VCCAUX/VCCBRAM, 5 pins", 30, 80,
     "VCCAUX ~25 mA static; BRAM adds with mesh size"),
    ("V3V3 (3.3 V)", "U1 VCCO, 24 pins / 36 I/O", 20, 50,
     "LVCMOS33 into short traces, I2S and SPI at a few MHz"),
    ("V3V3 (3.3 V)", "Y1 100 MHz oscillator", 25, 40, "ASE series at 3.3 V"),
    ("V3V3 (3.3 V)", "Y2 12.288 MHz oscillator", 5, 15, "ASE series, stock data 5-10 mA"),
    ("V3V3 (3.3 V)", "U3 PCM5102A DAC", 18, 25, "datasheet typical, playing"),
    ("V3V3 (3.3 V)", "U8 H11L1M optocoupler", 0, 10,
     "LED current only while MIDI is arriving; 0 when idle"),
    ("V3V3 (3.3 V)", "J11 status LEDs x4", 0, 6,
     "1 kOhm series, ~1.3 mA each, all four lit"),
    ("V3V3 (3.3 V)", "U2 W25Q64 flash", 1, 5,
     "idle after configuration; 4 mA while reading"),
    ("V3V3 (3.3 V)", "U4 MCP3208 ADC", 1, 1, "500 uA typical active"),
    ("V3V3 (3.3 V)", "U5 REF3125 + divider load", 1, 2,
     "300 uA quiescent plus pot and CV divider current"),
    ("V3V3 (3.3 V)", "U6 MCP6002, U7 MCP6561", 1, 1, "~100 uA each"),
]
RAIL_V = {"V1 (1.0 V)": 1.0, "V1V8 (1.8 V)": 1.8, "V3V3 (3.3 V)": 3.3}
EFF = (0.90, 0.85)          # TPS62130 efficiency, best and worst case here
VIN = 5.0


def main():
    per_rail: dict = {}
    print("  load                                        mA low   mA high")
    for rail, part, lo, hi, _ in LOADS:
        a, b = per_rail.get(rail, (0, 0))
        per_rail[rail] = (a + lo, b + hi)
        print(f"  {rail:14} {part:28} {lo:6}   {hi:7}")

    print("\n  rail totals")
    out_lo = out_hi = 0.0
    for rail, (lo, hi) in per_rail.items():
        v = RAIL_V[rail]
        out_lo += v * lo / 1000
        out_hi += v * hi / 1000
        print(f"  {rail:14} {lo:4}-{hi:4} mA   {v * lo / 1000:.3f}-{v * hi / 1000:.3f} W")

    print(f"\n  output power            {out_lo:.2f} - {out_hi:.2f} W")
    in_lo = out_lo / EFF[0]
    in_hi = out_hi / EFF[1]
    print(f"  input power at {EFF[1]:.0%}-{EFF[0]:.0%}  {in_lo:.2f} - {in_hi:.2f} W")
    print(f"  input current at {VIN:.0f} V   {in_lo / VIN * 1000:.0f} - "
          f"{in_hi / VIN * 1000:.0f} mA")
    print(f"\n  source specifies 3000 mA -- that is "
          f"{3000 / (in_hi / VIN * 1000):.0f}x the worst case here, i.e. headroom")
    print("  Eurorack +5 V rails commonly supply 500-1500 mA: comfortable either way.")
    print("\n  NOT INCLUDED: inrush. The bulk capacitance is a few hundred uF and the")
    print("  TPS62130 soft-start capacitors (3.3 nF) set the ramp; a case's current")
    print("  limit sees that, not the steady state.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
