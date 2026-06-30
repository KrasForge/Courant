-------------------------------------------------------------------------------
-- i2s_transceiver_tb.vhd  -  bit-accurate I2S loopback
--
-- Generates BCLK / LRCLK (32-bit slots), loops the transmitter's serial output
-- straight back into the receiver (sd_tx -> sd_rx), drives a set of Q1.23 test
-- words on tx_l / tx_r, and checks the receiver recovers them exactly. This
-- proves the RX and TX framing are consistent and that 24-bit I2S words map
-- cleanly to/from Q1.23 (including the sign bit, all-ones, and the rails).
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity i2s_transceiver_tb is
end entity i2s_transceiver_tb;

architecture sim of i2s_transceiver_tb is

  constant BCLK_HALF : time     := 10 ns;
  constant SLOT      : positive := 32;     -- BCLK per channel (24-bit MSB-justified)

  signal bclk   : std_logic := '0';
  signal lrclk  : std_logic := '0';
  signal rst    : std_logic := '1';
  signal sd     : std_logic;               -- loopback wire (tx -> rx)
  signal rx_l   : q123_t;
  signal rx_r   : q123_t;
  signal rxv    : std_logic;
  signal tx_l   : q123_t := (others => '0');
  signal tx_r   : q123_t := (others => '0');

  signal done : boolean := false;

  type vec_t is array (natural range <>) of integer;
  -- left/right test words (Q1.23 integer values)
  constant VL : vec_t := (0,  8388607, -8388608,        1,  2796202, -2796203, 1193046);
  constant VR : vec_t := (0, -8388608,  8388607, -1,       -1,  5592405, -1193046);

begin

  -- BCLK
  bclk_gen : process
  begin
    while not done loop
      bclk <= '0'; wait for BCLK_HALF;
      bclk <= '1'; wait for BCLK_HALF;
    end loop;
    wait;
  end process;

  -- LRCLK toggles every SLOT BCLK. Driven on the rising edge so it is settled
  -- before the transceiver's falling-edge TX logic samples it (a real codec
  -- presents LRCLK settled at the FPGA's sampling edge; here we just avoid a
  -- simulation delta-race with the falling-edge TX process).
  lr_gen : process (bclk)
    variable c : integer := 0;
  begin
    if rising_edge(bclk) then
      c := c + 1;
      if c = SLOT then
        lrclk <= not lrclk;
        c := 0;
      end if;
    end if;
  end process;

  watchdog : process
  begin
    wait for 50 ms;
    assert done report "i2s_transceiver_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (
      rst => rst, bclk => bclk, lrclk => lrclk,
      sd_rx => sd, sd_tx => sd,            -- loopback: TX drives sd, RX reads sd
      rx_l => rx_l, rx_r => rx_r, rx_valid => rxv,
      tx_l => tx_l, tx_r => tx_r
    );

  stim : process
  begin
    rst <= '1';
    wait until rising_edge(bclk);
    wait until rising_edge(bclk);
    rst <= '0';

    for k in VL'range loop
      tx_l <= to_signed(VL(k), 24);
      tx_r <= to_signed(VR(k), 24);
      -- hold the words constant and flush the frame latency
      for f in 1 to 3 loop
        wait until rising_edge(bclk) and rxv = '1';
      end loop;
      assert to_integer(rx_l) = VL(k) and to_integer(rx_r) = VR(k)
        report "vector " & integer'image(k) & ": got (" &
               integer'image(to_integer(rx_l)) & "," & integer'image(to_integer(rx_r)) &
               ") expected (" & integer'image(VL(k)) & "," & integer'image(VR(k)) & ")"
        severity failure;
    end loop;

    report "i2s_transceiver_tb: all checks passed (" &
           integer'image(VL'length) & " stereo words, bit-accurate loopback)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
