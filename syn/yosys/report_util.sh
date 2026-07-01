#!/usr/bin/env bash
# report_util.sh - Artix-7 resource report via the open-source yosys flow.
#
# Maps the RTL onto Xilinx 7-series primitives (DSP48E1 / LUT / FF) and prints a
# utilisation summary per design unit. This is the flow used to produce the
# numbers in docs/resource_budget.md; it runs anywhere (no Vivado licence). For
# sign-off numbers on real silicon use the Vivado flow in ../vivado/.
#
# Requires: yosys + yosys-plugin-ghdl + ghdl.
#   sudo apt-get install yosys yosys-plugin-ghdl ghdl
#
# Usage:  ./report_util.sh            # node_element, grid_mesh, top_resonator
set -euo pipefail

# Point the ghdl yosys plugin at the installed ghdl library prefix.
export GHDL_PREFIX="${GHDL_PREFIX:-/usr/lib/ghdl/mcode/vhdl}"

RTL=../../src/rtl
STD=--std=08

report() {            # $1 = top entity, $2... = source files
  local top="$1"; shift
  local tmp; tmp="$(mktemp)"
  echo "=================================================================="
  echo " $top"
  echo "=================================================================="
  yosys -m ghdl -p \
    "ghdl $STD $* -e $top; synth_xilinx -family xc7 -noiopad; tee -o $tmp stat -top $top" \
    >/dev/null 2>&1
  sed -n '/Number of cells/,/Estimated number of LCs/p' "$tmp"
  rm -f "$tmp"
}

report node_element  $RTL/fdtd_pkg.vhd $RTL/node_element.vhd
report grid_mesh     $RTL/fdtd_pkg.vhd $RTL/node_element.vhd $RTL/grid_mesh.vhd
report top_resonator $RTL/fdtd_pkg.vhd $RTL/node_element.vhd $RTL/grid_mesh.vhd \
                     $RTL/grid_mesh_tdm.vhd $RTL/mesh.vhd \
                     $RTL/cdc_word.vhd $RTL/i2s_transceiver.vhd \
                     $RTL/mesh_resonator.vhd $RTL/preset_bank.vhd \
                     $RTL/top_resonator.vhd

echo
echo "Note: grid_mesh / top_resonator default to NX=NY=8. DSP/LUT/FF scale"
echo "linearly with NX*NY (one node_element per node)."
