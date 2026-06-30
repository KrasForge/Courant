-------------------------------------------------------------------------------
-- tdm_tb.vhd  -  time-multiplexed mesh is bit-exact with the spatial mesh
--
-- Drives a spatial grid_mesh and a grid_mesh_tdm with identical coefficients
-- and excitation, and checks their stereo pickups match bit-for-bit every step.
-- Uses the non-linearity on (alpha) and a hard strike so the full datapath
-- (squaring, clamp, saturation) and the ping-pong double buffering are
-- exercised. The two have different latencies (spatial: 4 clocks; TDM: NX*NY+2
-- clocks per step); the TDM is the slower one, so its `valid` gates each
-- comparison.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity tdm_tb is
end entity tdm_tb;

architecture sim of tdm_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 8;
  constant NY         : positive := 8;
  constant STEPS      : positive := 30;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal strobe : std_logic := '0';
  signal coeffs : coeffs_t;
  signal exc_in : q123_t := (others => '0');
  signal exc_en : std_logic := '0';

  signal sp_l, sp_r : q123_t;  signal sp_v : std_logic;   -- spatial
  signal tm_l, tm_r : q123_t;  signal tm_v : std_logic;   -- time-multiplexed

  signal done : boolean := false;

begin

  clk_gen : process
  begin
    while not done loop
      clk <= '0'; wait for CLK_PERIOD/2;
      clk <= '1'; wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  watchdog : process
  begin
    wait for 10 ms;
    assert done report "tdm_tb: timeout" severity failure;
    wait;
  end process;

  spatial : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => sp_l, pick_r => sp_r, valid => sp_v);

  tdm : entity work.grid_mesh_tdm
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => tm_l, pick_r => tm_r, valid => tm_v);

  stim : process
  begin
    -- non-linearity on, so the squaring / clamp / saturation paths are tested
    coeffs <= (gamma2     => to_q123(0.09),
               a0         => to_q123(0.99996875),
               sigk1      => to_q123(0.99996875),
               alpha      => to_q123(0.6),
               gamma2_max => to_q123(0.451));

    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for k in 0 to STEPS-1 loop
      wait until rising_edge(clk);
      strobe <= '1';
      if k = 0 then exc_in <= to_q123(0.9); exc_en <= '1'; end if;  -- hard strike
      wait until rising_edge(clk);
      strobe <= '0';
      exc_en <= '0';
      wait until rising_edge(clk) and tm_v = '1';    -- TDM is the slower one
      assert to_integer(sp_l) = to_integer(tm_l) and to_integer(sp_r) = to_integer(tm_r)
        report "step " & integer'image(k) & ": spatial (" &
               integer'image(to_integer(sp_l)) & "," & integer'image(to_integer(sp_r)) &
               ") /= tdm (" &
               integer'image(to_integer(tm_l)) & "," & integer'image(to_integer(tm_r)) & ")"
        severity failure;
    end loop;

    report "tdm_tb: all checks passed (time-mux bit-exact with spatial, " &
           integer'image(STEPS) & " steps, non-linear)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
