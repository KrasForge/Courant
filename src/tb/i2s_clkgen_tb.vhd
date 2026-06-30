-------------------------------------------------------------------------------
-- i2s_clkgen_tb.vhd  -  the I2S master clocks have the right ratios and are stable
--
-- Drives i2s_clkgen from a 12.288 MHz master clock and measures, on hardware-
-- equivalent terms, what a scope/analyzer would check at bring-up (issue #26):
--   * MCLK : BCLK  = 4   (BCLK = 3.072 MHz)
--   * BCLK : LRCLK = 64  (LRCLK = 48 kHz, 32 BCLK per channel)
--   * MCLK : LRCLK = 256 (single-speed-mode ratio for CS5343 / CS4344)
--   * the ratios never deviate (clocks are stable, not just momentarily right)
--   * LRCLK is 50%-duty (equal left/right slot widths)
--   * MCLK is forwarded to the codec unchanged.
-- Measured with free-running tick counters and edge differences (no off-by-one),
-- over several LRCLK frames.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity i2s_clkgen_tb is
end entity i2s_clkgen_tb;

architecture sim of i2s_clkgen_tb is

  constant MCLK_PERIOD : time     := 81.380 ns;   -- 12.288 MHz
  constant M2B         : positive := 4;
  constant B2L         : positive := 64;
  constant FRAMES      : positive := 4;            -- LRCLK periods to observe

  signal mclk   : std_logic := '0';
  signal rst    : std_logic := '1';
  signal mclk_o : std_logic;
  signal bclk   : std_logic;
  signal lrclk  : std_logic;

  signal done : boolean := false;

  -- measurement state (mclk domain)
  signal mtick    : integer := 0;     -- free-running mclk tick counter
  signal btick    : integer := 0;     -- free-running bclk-rising tick counter
  signal last_bt  : integer := 0;
  signal last_lt  : integer := 0;
  signal meas_mpb : integer := 0;     -- last measured mclk-per-bclk
  signal meas_bpl : integer := 0;     -- last measured bclk-per-lrclk
  signal mpb_min  : integer := integer'high;
  signal mpb_max  : integer := 0;
  signal bpl_min  : integer := integer'high;
  signal bpl_max  : integer := 0;
  signal frame_cnt   : integer := 0;     -- completed LRCLK periods
  signal lhi, llo : integer := 0;     -- LRCLK high / low mclk-tick accumulators
  signal lhi_cap  : integer := 0;     -- high / low widths of the last full period
  signal llo_cap  : integer := 1;
  signal warm     : boolean := false; -- ignore the first (partial) intervals

begin

  clk_gen : process
  begin
    while not done loop
      mclk <= '0'; wait for MCLK_PERIOD/2;
      mclk <= '1'; wait for MCLK_PERIOD/2;
    end loop;
    wait;
  end process;

  watchdog : process
  begin
    wait for 10 ms;
    assert done report "i2s_clkgen_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.i2s_clkgen
    generic map (MCLK_TO_BCLK => M2B, BCLK_TO_LRCK => B2L)
    port map (mclk => mclk, rst => rst, mclk_o => mclk_o,
              bclk => bclk, lrclk => lrclk);

  -- mclk-domain monitor: tick counters + edge differences
  monitor : process (mclk)
    variable prev_b, prev_l : std_logic := '0';
  begin
    if rising_edge(mclk) then
      if rst = '1' then
        mtick <= 0; btick <= 0; last_bt <= 0; last_lt <= 0;
        prev_b := '0'; prev_l := '0';
      else
        mtick <= mtick + 1;

        if bclk = '1' and prev_b = '0' then           -- BCLK rising edge
          meas_mpb <= mtick - last_bt;
          last_bt  <= mtick;
          btick    <= btick + 1;
          if warm then
            if (mtick - last_bt) < mpb_min then mpb_min <= mtick - last_bt; end if;
            if (mtick - last_bt) > mpb_max then mpb_max <= mtick - last_bt; end if;
          end if;
        end if;

        if lrclk = '1' and prev_l = '0' then           -- LRCLK rising edge
          meas_bpl <= btick - last_lt;
          last_lt  <= btick;
          if warm then
            if (btick - last_lt) < bpl_min then bpl_min <= btick - last_lt; end if;
            if (btick - last_lt) > bpl_max then bpl_max <= btick - last_lt; end if;
            lhi_cap <= lhi;     -- high mclk-ticks of the just-completed period
            llo_cap <= llo;     -- low  mclk-ticks of the just-completed period
            frame_cnt  <= frame_cnt + 1;
          end if;
          warm <= true;                                 -- first full frame seen
          lhi  <= 1;                                     -- this tick (lrclk='1')
          llo  <= 0;                                     --   starts the new high slot
        else
          if lrclk = '1' then lhi <= lhi + 1; else llo <= llo + 1; end if;
        end if;

        prev_b := bclk;
        prev_l := lrclk;
      end if;
    end if;
  end process;

  stim : process
  begin
    rst <= '1';
    wait for 20 * MCLK_PERIOD;
    wait until rising_edge(mclk);
    rst <= '0';

    -- let several full LRCLK frames elapse
    wait until frame_cnt >= FRAMES;

    -- sample mclk forwarding away from any edge (avoid delta-delay races on the
    -- combinational pass-through): check the high half then the low half
    wait until rising_edge(mclk);
    wait for MCLK_PERIOD/4;
    assert mclk_o = '1'
      report "i2s_clkgen_tb: mclk not forwarded to the codec (high)" severity failure;
    wait for MCLK_PERIOD/2;
    assert mclk_o = '0'
      report "i2s_clkgen_tb: mclk not forwarded to the codec (low)" severity failure;

    assert meas_mpb = M2B
      report "i2s_clkgen_tb: MCLK/BCLK = " & integer'image(meas_mpb) &
             " (expected " & integer'image(M2B) & ")" severity failure;
    assert meas_bpl = B2L
      report "i2s_clkgen_tb: BCLK/LRCLK = " & integer'image(meas_bpl) &
             " (expected " & integer'image(B2L) & ")" severity failure;

    assert mpb_min = M2B and mpb_max = M2B
      report "i2s_clkgen_tb: BCLK ratio unstable (min " &
             integer'image(mpb_min) & ", max " & integer'image(mpb_max) & ")"
      severity failure;
    assert bpl_min = B2L and bpl_max = B2L
      report "i2s_clkgen_tb: LRCLK ratio unstable (min " &
             integer'image(bpl_min) & ", max " & integer'image(bpl_max) & ")"
      severity failure;

    -- LRCLK 50% duty: high and low slots equal (= M2B*B2L/2 mclk ticks each)
    assert lhi_cap = llo_cap and lhi_cap = (M2B * B2L) / 2
      report "i2s_clkgen_tb: LRCLK not 50% duty (high " & integer'image(lhi_cap) &
             " /= low " & integer'image(llo_cap) & " mclk ticks)" severity failure;

    report "i2s_clkgen_tb: all checks passed (MCLK:BCLK:LRCLK = " &
           integer'image(M2B * B2L) & ":" & integer'image(B2L) & ":1, " &
           "stable over " & integer'image(FRAMES) & " frames, 50% LRCLK duty)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
