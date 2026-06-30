# build_arty.tcl - Vivado synthesis + utilisation report for the Arty A7.
#
# Reproducible non-project (out-of-context) flow targeting a Digilent Arty A7
# (Xilinx Artix-7). Synthesises top_resonator at a chosen mesh size and writes
# utilisation and timing reports. Use this for sign-off numbers; the quick
# open-source estimate lives in ../yosys/report_util.sh.
#
# Usage:
#   vivado -mode batch -source build_arty.tcl -tclargs <part> <NX> <NY> <OS>
# e.g.
#   vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 2 2 4
#   vivado -mode batch -source build_arty.tcl -tclargs xc7a100tcsg324-1  3 3 4

set part [lindex $argv 0]; if {$part eq ""} { set part xc7a35ticsg324-1L }
set NX   [lindex $argv 1]; if {$NX   eq ""} { set NX 2 }
set NY   [lindex $argv 2]; if {$NY   eq ""} { set NY 2 }
set OS   [lindex $argv 3]; if {$OS   eq ""} { set OS 4 }

set rtl [file normalize [file dirname [info script]]/../../src/rtl]

read_vhdl -vhdl2008 [list \
  $rtl/fdtd_pkg.vhd \
  $rtl/node_element.vhd \
  $rtl/grid_mesh.vhd \
  $rtl/cdc_word.vhd \
  $rtl/i2s_transceiver.vhd \
  $rtl/mesh_resonator.vhd \
  $rtl/control_bus.vhd \
  $rtl/top_resonator.vhd ]

read_xdc [file dirname [info script]]/arty_a7.xdc

synth_design -top top_resonator -part $part \
  -generic NX=$NX -generic NY=$NY -generic OS=$OS

set tag "${NX}x${NY}_OS${OS}_[string range $part 0 6]"
report_utilization      -file util_${tag}.rpt
report_timing_summary   -file timing_${tag}.rpt
puts "wrote util_${tag}.rpt and timing_${tag}.rpt"
