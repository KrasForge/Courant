# arty_a7.xdc - constraints stub for the Digilent Arty A7
#
# Minimal clock + I/O constraints for top_resonator on an Arty A7. The system
# clock is the on-board 100 MHz oscillator (pin E3). The I2S signals are routed
# to a Pmod header (example: Pmod JA); adjust the pin LOCs to your wiring and to
# whether the FPGA is I2S master or slave.

## System clock - 100 MHz oscillator
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports sys_clk]
create_clock -name sys_clk -period 10.000 [get_ports sys_clk]

## I2S bit clock (from the codec). Period shown for a 12.288 MHz BCLK
## (= 256 * 48 kHz); set to your codec's BCLK.
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports bclk]
create_clock -name bclk -period 81.380 [get_ports bclk]

## Asynchronous clock groups: the mesh (sys_clk) and audio (bclk) domains are
## independent; the cdc_word crossings are constrained as such.
set_clock_groups -asynchronous \
  -group [get_clocks sys_clk] -group [get_clocks bclk]

## I2S data / word select (example Pmod JA pins; edit to your board wiring)
set_property -dict { PACKAGE_PIN A11 IOSTANDARD LVCMOS33 } [get_ports lrclk]
set_property -dict { PACKAGE_PIN D12 IOSTANDARD LVCMOS33 } [get_ports sd_rx]
set_property -dict { PACKAGE_PIN D13 IOSTANDARD LVCMOS33 } [get_ports sd_tx]

## reset (button 0)
set_property -dict { PACKAGE_PIN D9 IOSTANDARD LVCMOS33 } [get_ports sys_rst]
