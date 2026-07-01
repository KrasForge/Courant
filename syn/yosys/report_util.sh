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

SYNTH_SRCS="$RTL/fdtd_pkg.vhd $RTL/node_element.vhd $RTL/grid_mesh.vhd \
  $RTL/grid_mesh_tdm.vhd $RTL/mesh.vhd $RTL/cdc_word.vhd $RTL/i2s_transceiver.vhd \
  $RTL/i2s_clkgen.vhd $RTL/sample_strobe.vhd $RTL/mesh_resonator.vhd \
  $RTL/voice_allocator.vhd $RTL/poly_voices.vhd $RTL/midi_uart_rx.vhd \
  $RTL/midi_frontend.vhd $RTL/preset_bank.vhd $RTL/synth_top.vhd"

report node_element  $RTL/fdtd_pkg.vhd $RTL/node_element.vhd
report grid_mesh     $RTL/fdtd_pkg.vhd $RTL/node_element.vhd $RTL/grid_mesh.vhd
report top_resonator $RTL/fdtd_pkg.vhd $RTL/node_element.vhd $RTL/grid_mesh.vhd \
                     $RTL/grid_mesh_tdm.vhd $RTL/mesh.vhd \
                     $RTL/cdc_word.vhd $RTL/i2s_transceiver.vhd \
                     $RTL/mesh_resonator.vhd $RTL/preset_bank.vhd \
                     $RTL/top_resonator.vhd

# The playable synth (issue #77): flatten so the aggregate DSP/LUT/FF are summed
# (a hierarchical top otherwise reports only the wrapper's cells). Sweep configs
# via TM / NV below; the full voices-vs-part table is in docs/resource_budget.md.
synth_report() {          # $1 = TIME_MUX, $2 = NVOICES
  local tm=$1 nv=$2 tmp; tmp="$(mktemp)"
  yosys -m ghdl -p \
    "ghdl $STD -gTIME_MUX=$tm -gNVOICES=$nv $SYNTH_SRCS -e synth_top; \
     synth_xilinx -family xc7 -noiopad -flatten; tee -o $tmp stat" >/dev/null 2>&1
  local dsp lut ff
  dsp=$(grep -oP 'DSP48E1\s+\K[0-9]+' "$tmp" | tail -1)
  lut=$(grep -oP 'LUT[1-6]\s+\K[0-9]+' "$tmp" | awk '{s+=$1} END{print s}')
  ff=$(grep -oP 'FDRE\s+\K[0-9]+|FDSE\s+\K[0-9]+|FDRE_1\s+\K[0-9]+' "$tmp" | awk '{s+=$1} END{print s}')
  printf "  TIME_MUX=%-5s NVOICES=%s :  DSP=%-5s LUT=%-6s FF=%s\n" "$tm" "$nv" "${dsp:-0}" "${lut:-0}" "${ff:-0}"
  rm -f "$tmp"
}
echo "=================================================================="
echo " synth_top (playable design; ~18 DSP / time-mux voice)"
echo "=================================================================="
synth_report true 2
synth_report true 4

echo
echo "Note: grid_mesh / top_resonator default to NX=NY=8. DSP/LUT/FF scale"
echo "linearly with NX*NY (one node_element per node). synth_top: ~18 DSP per"
echo "time-multiplexed voice; see docs/resource_budget.md for the voices-vs-part"
echo "table and the LUT-mapping caveat."
