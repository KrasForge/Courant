# build_arty.tcl - Vivado synthesis + implementation + timing sign-off for Arty A7.
#
# Reproducible non-project flow targeting a Digilent Arty A7 (Xilinx Artix-7).
# Synthesises and implements (opt/place/route) top_resonator at a chosen mesh
# size, applies the board constraints, and writes utilisation and timing
# reports. Use this for sign-off numbers (issue #25, timing closure); the quick
# open-source resource estimate lives in ../yosys/report_util.sh.
#
# Usage:
#   vivado -mode batch -source build_arty.tcl -tclargs <part> <NX> <NY> <OS> [TIME_MUX]
# e.g.
#   vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 2 2 4
#   vivado -mode batch -source build_arty.tcl -tclargs xc7a100tcsg324-1  3 3 4
#   vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 8 8 4 true

set part     [lindex $argv 0]; if {$part     eq ""} { set part xc7a35ticsg324-1L }
set NX       [lindex $argv 1]; if {$NX       eq ""} { set NX 2 }
set NY       [lindex $argv 2]; if {$NY       eq ""} { set NY 2 }
set OS       [lindex $argv 3]; if {$OS       eq ""} { set OS 4 }
set TIME_MUX [lindex $argv 4]; if {$TIME_MUX eq ""} { set TIME_MUX false }

set rtl [file normalize [file dirname [info script]]/../../src/rtl]

read_vhdl -vhdl2008 [list \
  $rtl/fdtd_pkg.vhd \
  $rtl/node_element.vhd \
  $rtl/grid_mesh.vhd \
  $rtl/grid_mesh_tdm.vhd \
  $rtl/mesh.vhd \
  $rtl/cdc_word.vhd \
  $rtl/i2s_transceiver.vhd \
  $rtl/mesh_resonator.vhd \
  $rtl/preset_bank.vhd \
  $rtl/top_resonator.vhd ]

read_xdc [file dirname [info script]]/arty_a7.xdc

synth_design -top top_resonator -part $part \
  -generic NX=$NX -generic NY=$NY -generic OS=$OS -generic TIME_MUX=$TIME_MUX

set tag "${NX}x${NY}_OS${OS}_[expr {$TIME_MUX eq "true" ? "tdm" : "spatial"}]_[string range $part 0 6]"

# --- implementation: optimise, place, route -------------------------------
opt_design
place_design
route_design

# --- reports: utilisation + full post-route timing summary ----------------
report_utilization    -file util_${tag}.rpt
report_timing_summary -file timing_${tag}.rpt -delay_type min_max -report_unconstrained

# --- pass/fail gate on worst negative slack (setup + hold) ----------------
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
puts "wrote util_${tag}.rpt and timing_${tag}.rpt"
puts "WNS (setup) = $wns ns,  WHS (hold) = $whs ns"
if {$wns < 0 || $whs < 0} {
  puts "TIMING FAILED: negative slack"
  exit 1
} else {
  puts "TIMING MET: positive slack at the requested clocks"
}
