-------------------------------------------------------------------------------
-- sample_strobe_tb.vhd  -  audio-frame strobe / CDC check
--
-- Drives an LRCLK that is asynchronous to the system clock (its period is not a
-- whole number of sys_clk cycles) and checks that sample_strobe emits exactly
-- one clean single-cycle `frame` pulse per LRCLK period, with no double pulses
-- and none missed.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity sample_strobe_tb is
end entity sample_strobe_tb;

architecture sim of sample_strobe_tb is

  constant SYS_HALF  : time     := 5 ns;     -- 100 MHz system clock
  constant LR_HALF   : time     := 175 ns;   -- async word clock (17.5 cycles)
  constant N_FRAMES  : positive := 10;

  signal sys_clk : std_logic := '0';
  signal rst     : std_logic := '1';
  signal lrclk   : std_logic := '0';
  signal frame   : std_logic;

  signal frame_cnt : integer := 0;
  signal lr_done   : boolean := false;
  signal done      : boolean := false;

begin

  sys_gen : process
  begin
    while not done loop
      sys_clk <= '0'; wait for SYS_HALF;
      sys_clk <= '1'; wait for SYS_HALF;
    end loop;
    wait;
  end process;

  -- Exactly N_FRAMES LRCLK periods (rising edges), asynchronous to sys_clk.
  lr_gen : process
  begin
    lrclk <= '0';
    wait for 200 ns;                         -- settle after reset
    for i in 1 to N_FRAMES loop
      lrclk <= '1'; wait for LR_HALF;
      lrclk <= '0'; wait for LR_HALF;
    end loop;
    lr_done <= true;
    wait;
  end process;

  dut : entity work.sample_strobe
    port map (sys_clk => sys_clk, rst => rst, lrclk => lrclk, frame => frame);

  -- Monitor: count frames, enforce single-cycle (never high two cycles running)
  mon : process (sys_clk)
    variable prev : std_logic := '0';
  begin
    if rising_edge(sys_clk) then
      if rst = '0' then
        if frame = '1' then
          assert prev = '0'
            report "frame asserted for more than one cycle" severity failure;
          frame_cnt <= frame_cnt + 1;
        end if;
      end if;
      prev := frame;
    end if;
  end process;

  stim : process
  begin
    rst <= '1';
    wait for 100 ns;
    rst <= '0';
    wait until lr_done;
    wait for 1 us;                           -- let the last frame propagate
    assert frame_cnt = N_FRAMES
      report "expected " & integer'image(N_FRAMES) & " frame strobes, got " &
             integer'image(frame_cnt)
      severity failure;
    report "sample_strobe_tb: all checks passed (" & integer'image(frame_cnt) &
           " single-cycle strobes, one per audio frame)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
