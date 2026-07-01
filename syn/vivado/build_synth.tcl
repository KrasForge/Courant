# build_synth.tcl - Vivado synth + implementation for the playable synth_top.
#
# Builds the board wrapper arty_synth (MMCM clocking + synth_top) for a Digilent
# Arty A7, runs opt/place/route, writes utilisation + post-route timing, and
# exits non-zero on negative slack (a pass/fail timing gate). This is the build
# path for the flagship playable design (issue #76); the older resonator-only
# flow is build_arty.tcl.
#
# Usage:
#   vivado -mode batch -source build_synth.tcl -tclargs <part> <NVOICES> <NX> <NY> <OS> <TIME_MUX>
# e.g.
#   vivado -mode batch -source build_synth.tcl -tclargs xc7a35ticsg324-1L 4 8 8 4 true
#   vivado -mode batch -source build_synth.tcl -tclargs xc7a100tcsg324-1  8 8 8 4 true

set part     [lindex $argv 0]; if {$part     eq ""} { set part xc7a35ticsg324-1L }
set NVOICES  [lindex $argv 1]; if {$NVOICES  eq ""} { set NVOICES 4 }
set NX       [lindex $argv 2]; if {$NX       eq ""} { set NX 8 }
set NY       [lindex $argv 3]; if {$NY       eq ""} { set NY 8 }
set OS       [lindex $argv 4]; if {$OS       eq ""} { set OS 4 }
set TIME_MUX [lindex $argv 5]; if {$TIME_MUX eq ""} { set TIME_MUX true }

set here [file dirname [info script]]
set rtl  [file normalize $here/../../src/rtl]

# RTL in dependency-friendly order (Vivado resolves regardless; listed for clarity)
read_vhdl -vhdl2008 [list \
  $rtl/fdtd_pkg.vhd \
  $rtl/node_element.vhd \
  $rtl/grid_mesh.vhd \
  $rtl/grid_mesh_tdm.vhd \
  $rtl/mesh.vhd \
  $rtl/cdc_word.vhd \
  $rtl/i2s_transceiver.vhd \
  $rtl/i2s_clkgen.vhd \
  $rtl/sample_strobe.vhd \
  $rtl/mesh_resonator.vhd \
  $rtl/voice_allocator.vhd \
  $rtl/poly_voices.vhd \
  $rtl/midi_uart_rx.vhd \
  $rtl/midi_frontend.vhd \
  $rtl/preset_bank.vhd \
  $rtl/synth_top.vhd \
  $here/arty_synth.vhd ]

read_xdc $here/arty_synth.xdc

synth_design -top arty_synth -part $part \
  -generic NVOICES=$NVOICES -generic NX=$NX -generic NY=$NY -generic OS=$OS \
  -generic TIME_MUX=$TIME_MUX

set tag "synth_${NVOICES}v_${NX}x${NY}_OS${OS}_[expr {$TIME_MUX eq "true" ? "tdm" : "spatial"}]_[string range $part 0 6]"

opt_design
place_design
route_design

report_utilization    -file util_${tag}.rpt
report_timing_summary -file timing_${tag}.rpt -delay_type min_max -report_unconstrained

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
