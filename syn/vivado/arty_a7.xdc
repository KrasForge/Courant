# arty_a7.xdc - timing & I/O constraints for top_resonator on a Digilent Arty A7
#
# Target: Arty A7 (Xilinx Artix-7) + Pmod I2S2 audio codec on Pmod header JA.
# Covers everything needed for a clean place & route at 100 MHz (issue #25):
#   * the two independent clocks (system 100 MHz, I2S bit clock) and their
#     I/O pin assignments,
#   * the asynchronous clock-domain crossing between them (the cdc_word
#     instances), constrained as a false path with a bounded bus skew so the
#     multi-bit word cannot tear,
#   * the asynchronous reset, treated as a false path into both domains.
#
# Pin LOCs are the Arty A7 board defaults (system clock E3, BTN0 D9) and the
# Pmod JA header (JA1=G13, JA2=B11, JA3=A11, JA4=D12, JA7=D13). Adjust the Pmod
# pins to your wiring; the timing constraints below are independent of the LOCs.

#==============================================================================
# Clocks
#==============================================================================

## System clock - on-board 100 MHz oscillator (pin E3)
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports sys_clk]
create_clock -name sys_clk -period 10.000 [get_ports sys_clk]

## I2S bit clock from the codec (top_resonator is the I2S slave). Period shown
## for a 12.288 MHz BCLK (= 256 * 48 kHz); set to your codec's actual BCLK.
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports bclk]
create_clock -name bclk -period 81.380 [get_ports bclk]

#==============================================================================
# I2S / Pmod I2S2 data pins (Pmod header JA)
#==============================================================================
## lrclk = word select (LRCK), sd_rx = data from the ADC (SDOUT),
## sd_tx  = data to the DAC (SDIN). The codec master clock (MCLK) is supplied
## externally / by a clocking wizard and is not a top_resonator port.
set_property -dict { PACKAGE_PIN A11 IOSTANDARD LVCMOS33 } [get_ports lrclk]
set_property -dict { PACKAGE_PIN D12 IOSTANDARD LVCMOS33 } [get_ports sd_rx]
set_property -dict { PACKAGE_PIN D13 IOSTANDARD LVCMOS33 } [get_ports sd_tx]

## I2S I/O timing relative to the bit clock (data is MSB-first, sampled on the
## BCLK edge per the I2S frame). Conservative half-period budgets; tighten to
## the codec datasheet numbers for sign-off.
set_input_delay  -clock bclk -max 20.000 [get_ports {lrclk sd_rx}]
set_input_delay  -clock bclk -min  5.000 [get_ports {lrclk sd_rx}]
set_output_delay -clock bclk -max 20.000 [get_ports sd_tx]
set_output_delay -clock bclk -min  5.000 [get_ports sd_tx]

#==============================================================================
# Reset (BTN0)
#==============================================================================
set_property -dict { PACKAGE_PIN D9  IOSTANDARD LVCMOS33 } [get_ports sys_rst]

#==============================================================================
# Clock-domain crossing (cdc_word: excitation in, pickups out)
#==============================================================================
# sys_clk (mesh) and bclk (audio) are independent oscillators. Declare them
# asynchronous: this cuts setup/hold (recovery/removal) analysis on every path
# between the two domains, which is exactly the false path the cdc_word MCP
# handshake relies on (only the 1-bit `req` toggle crosses, resolved by the
# two-flop synchroniser).
set_clock_groups -asynchronous \
  -group [get_clocks sys_clk] -group [get_clocks bclk]

# The blanket async group above is correct for the control/flag crossing, but
# it also stops analysis of the multi-bit holding-register -> destination data
# capture. That bus is read only when stable, yet its bits must still arrive
# within one destination clock period or the captured word could tear. A bus
# skew check survives the async clock group (it is a skew, not a setup, check)
# and bounds exactly that. One per direction; the destination period bounds it.
#   excitation : src=bclk    -> dst=sys_clk  (bound by sys_clk period 10 ns)
#   pickups    : src=sys_clk -> dst=bclk     (bound by bclk    period 81.38 ns)
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ *cdc_exc/hold_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ *cdc_exc/dst_data_reg*}] 10.000
set_bus_skew -from [get_cells -hierarchical -filter {NAME =~ *cdc_pick/hold_reg*}] \
             -to   [get_cells -hierarchical -filter {NAME =~ *cdc_pick/dst_data_reg*}] 81.380

# If you prefer not to use an async clock group (e.g. you keep some analysed
# paths between the domains), drop the set_clock_groups above and constrain the
# crossing explicitly instead:
#   set_false_path -to [get_cells -hier -filter {NAME =~ *cdc_*/sync_reg[0]*}]
#   set_max_delay -datapath_only \
#     -from [get_cells -hier -filter {NAME =~ *cdc_*/hold_reg*}] \
#     -to   [get_cells -hier -filter {NAME =~ *cdc_*/dst_data_reg*}] 10.000

# Asynchronous reset (a push-button) fans out into both domains; do not let its
# de-assertion edge create a cross-domain timing path.
set_false_path -from [get_ports sys_rst]
