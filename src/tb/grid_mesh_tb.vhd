-------------------------------------------------------------------------------
-- grid_mesh_tb.vhd  -  elaboration + smoke test for the structural mesh
--
-- Builds an 8x8 fixed-boundary grid_mesh, injects a single-sample excitation
-- impulse at the centre, and checks that the disturbance propagates out to the
-- stereo pickup taps and that the mesh resets to rest. This is a smoke test of
-- the structure and wiring; rigorous physics validation against the reference
-- model is issue #13.
--
-- The mesh also elaborates at 16x16 and 32x32 (verified with
--   ghdl -e -gNX=16 -gNY=16 grid_mesh   /   -gNX=32 -gNY=32
-- which is fast; those sizes are not simulated here to keep CI quick).
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity grid_mesh_tb is
end entity grid_mesh_tb;

architecture sim of grid_mesh_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 8;
  constant NY         : positive := 8;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal strobe : std_logic := '0';
  signal coeffs : coeffs_t;
  signal exc_in : q123_t := (others => '0');
  signal exc_en : std_logic := '0';
  signal pick_l : q123_t;
  signal pick_r : q123_t;
  signal valid  : std_logic;

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
    wait for 5 ms;
    assert done report "grid_mesh_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false)
    port map (
      clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
      exc_in => exc_in, exc_en => exc_en,
      pick_l => pick_l, pick_r => pick_r, valid => valid
    );

  stim : process
    constant IMP   : q123_t := to_q123(0.5);
    variable moved : boolean := false;
  begin
    coeffs <= (gamma2     => to_q123(0.09),
               a0         => to_q123(0.99996875),
               sigk1      => to_q123(0.99996875),
               alpha      => Q123_ZERO,           -- linear (no chaos injection)
               gamma2_max => to_q123(0.5));

    -- Reset to rest
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(pick_l) = 0 and to_integer(pick_r) = 0
      report "after reset: pickups not at rest" severity failure;

    -- 24 mesh steps; inject a one-sample impulse at the centre on step 1
    for k in 1 to 24 loop
      wait until rising_edge(clk);
      strobe <= '1';
      if k = 1 then
        exc_in <= IMP;
        exc_en <= '1';
      end if;
      wait until rising_edge(clk);
      strobe <= '0';
      exc_en <= '0';
      wait until rising_edge(clk) and valid = '1';
      if to_integer(pick_l) /= 0 or to_integer(pick_r) /= 0 then
        moved := true;
      end if;
    end loop;

    assert moved
      report "excitation never propagated to the pickups" severity failure;

    -- Reset returns the whole mesh to rest
    rst <= '1';
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(pick_l) = 0 and to_integer(pick_r) = 0
      report "after second reset: pickups not at rest" severity failure;

    report "grid_mesh_tb: all checks passed (impulse propagated, reset clean)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
