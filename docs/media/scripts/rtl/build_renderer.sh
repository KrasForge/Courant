#!/usr/bin/env sh
# Build the cycle-accurate RTL audio renderer used for the README sound demos:
# GHDL synthesises synth_top (4 voices, 8x8, OS=4, time-multiplexed) to
# Verilog, Verilator compiles it with render_rtl.cpp.
#
#   docs/media/scripts/rtl/build_renderer.sh BUILD_DIR
#   BUILD_DIR/verilated/Vsynth_top docs/media/scores/01_berlin_voltage.txt \
#       480000 out.s24le out.txt          # 10 s at 48 kHz
#   python3 docs/media/scripts/rtl_media.py CAPTURE_DIR
#
# Needs docker and an image with ghdl (with synth) and verilator 5.
# Rendering is slow: the full 100 MHz system clock is simulated.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
build=$(mkdir -p "$1" && cd "$1" && pwd)
image=${RTL_SIM_IMAGE:-radian-rtl-sim:20260916}
run() { docker run --rm --network none -u "$(id -u):$(id -g)" \
  -v "$root:/repo:ro" -v "$here:/tools:ro" -v "$build:/build" -w /build \
  --entrypoint /bin/sh "$image" -c "$1"; }

run 'mkdir -p ghdl && ghdl -i --std=08 --workdir=ghdl /repo/src/rtl/*.vhd &&
     ghdl -m --std=08 --workdir=ghdl synth_top >/dev/null 2>&1 || true
     ghdl synth --std=08 --workdir=ghdl --out=verilog \
       -gNVOICES=4 -gNX=8 -gNY=8 -gOS=4 -gTIME_MUX=true synth_top > synth_top.v'
python3 "$here/normalize_verilog_literals.py" "$build/synth_top.v"
run 'verilator --cc --exe --build -j 8 -O3 -Wno-fatal --top-module synth_top \
       --Mdir verilated synth_top.v /tools/render_rtl.cpp -CFLAGS -O3'
echo "renderer: $build/verilated/Vsynth_top"
