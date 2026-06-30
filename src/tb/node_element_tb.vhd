-------------------------------------------------------------------------------
-- node_element_tb.vhd  -  unit test for the single-node PE
--
-- Drives node_element from rest with neighbour inputs held constant and checks
-- the committed displacement after each strobe against a golden sequence
-- produced by iterating node_update / the Q1.23 reference model
-- (model/QMesh2D.m). Also checks synchronous reset to rest.
--
-- A watchdog aborts (failure) if a `valid` pulse never arrives, so a pipeline
-- bug fails the build instead of hanging CI.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity node_element_tb is
end entity node_element_tb;

architecture sim of node_element_tb is

  constant CLK_PERIOD : time := 10 ns;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal strobe : std_logic := '0';
  signal coeffs : coeffs_t;
  signal nb     : neighbours_t;
  signal u_out  : q123_t;
  signal valid  : std_logic;

  signal done : boolean := false;

  -- Golden u_out sequence: rest start, neighbours held at
  -- [0.30, -0.10, 0.20, 0.00], default coeffs (gamma^2=0.09, a0=sigk1 @ sigma=1.5).
  type int_array is array (natural range <>) of integer;
  constant EXP : int_array(1 to 8) :=
    (301981, 797214, 1307408, 1648898, 1698762, 1439067, 963321, 442800);

begin

  -- Clock
  clk_gen : process
  begin
    while not done loop
      clk <= '0'; wait for CLK_PERIOD/2;
      clk <= '1'; wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  -- Watchdog
  watchdog : process
  begin
    wait for 1 ms;
    assert done report "node_element_tb: timeout waiting for valid" severity failure;
    wait;
  end process;

  dut : entity work.node_element
    port map (
      clk => clk, rst => rst, strobe => strobe,
      coeffs => coeffs, nb => nb, u_out => u_out, valid => valid
    );

  stim : process
  begin
    -- Constant stimulus for the whole run
    coeffs <= (gamma2 => to_q123(0.09),
               a0     => to_q123(0.99996875),
               sigk1  => to_q123(0.99996875));
    nb     <= (n => to_q123(0.30), s => to_q123(-0.10),
               e => to_q123(0.20), w => to_q123(0.00));

    -- Synchronous reset to rest
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(u_out) = 0
      report "after reset: u_out /= 0" severity failure;

    -- Eight one-step updates, checking the committed result each time
    for k in EXP'range loop
      wait until rising_edge(clk);
      strobe <= '1';
      wait until rising_edge(clk);
      strobe <= '0';
      wait until rising_edge(clk) and valid = '1';
      assert to_integer(u_out) = EXP(k)
        report "step " & integer'image(k) & ": u_out = "
             & integer'image(to_integer(u_out)) & ", expected "
             & integer'image(EXP(k))
        severity failure;
    end loop;

    -- Synchronous reset returns to rest
    rst <= '1';
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(u_out) = 0
      report "after second reset: u_out /= 0" severity failure;

    report "node_element_tb: all checks passed" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
