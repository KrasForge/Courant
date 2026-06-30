-------------------------------------------------------------------------------
-- sample_strobe.vhd  -  audio-frame strobe from the I2S word clock (CDC)
--
-- The mesh advances one time-step per audio sample, strobed from the I2S word
-- clock (README §3, "Clock-domain crossing"). This module crosses LRCLK from
-- the audio (BCLK) domain into the system-clock domain and emits a clean
-- one-cycle `frame` pulse once per audio sample (one LRCLK period, f_s).
--
-- Crossing: a two-flop synchroniser on LRCLK followed by rising-edge detection.
-- The rising edge of LRCLK marks the start of the left channel, i.e. the start
-- of each stereo audio frame, so `frame` pulses at f_s.
--
-- Oversampling (M3): `frame` is the audio-rate tick. The OS mesh time-steps per
-- frame are sequenced downstream by mesh_resonator (which handshakes each step
-- against the mesh's `valid`), so this module stays a single clean strobe. The
-- cycle budget is analysed in docs/timing_budget.md.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity sample_strobe is
  port (
    sys_clk : in  std_logic;          -- system clock (e.g. 100 MHz)
    rst     : in  std_logic;          -- synchronous reset
    lrclk   : in  std_logic;          -- I2S word select (audio domain, async)
    frame   : out std_logic           -- 1-cycle pulse per audio sample (f_s)
  );
end entity sample_strobe;

architecture rtl of sample_strobe is
  -- sync(0): metastability-capture flop; sync(1): synchronised LRCLK;
  -- sync(2): one-cycle-delayed copy for edge detection.
  signal sync : std_logic_vector(2 downto 0) := (others => '0');
begin

  process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      if rst = '1' then
        sync  <= (others => '0');
        frame <= '0';
      else
        sync  <= sync(1 downto 0) & lrclk;     -- shift LRCLK through the synchroniser
        frame <= sync(1) and not sync(2);      -- rising edge of synchronised LRCLK
      end if;
    end if;
  end process;

end architecture rtl;
