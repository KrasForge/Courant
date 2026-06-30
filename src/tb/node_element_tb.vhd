-------------------------------------------------------------------------------
-- node_element_tb.vhd  -  unit test of the PE against the Q1.23 reference model
--
-- Drives node_element with a recorded neighbour trace exported from the
-- floating/Q1.23 reference model (model/QMesh2D.m) and compares the committed
-- displacement bit-for-bit against the golden trajectory, over many steps.
--
-- The observed node starts at REST in the reference run and is driven entirely
-- by its neighbours, so a fresh PE replaying the recorded neighbour values
-- reproduces the node's trajectory exactly (verified PE==reference during trace
-- generation). The trace deliberately includes saturation events and
-- full-scale (max-amplitude) neighbour inputs.
--
-- Trace file: src/tb/node_element_trace.txt
--   header line starting with '#', then "nN nS nE nW expected" per step.
--   Coefficients are gamma2=0.09, a0=sigk1 @ sigma=1.5 (matching the header).
--
-- A watchdog aborts (failure) if a `valid` pulse never arrives, so a pipeline
-- bug fails CI instead of hanging.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity node_element_tb is
end entity node_element_tb;

architecture sim of node_element_tb is

  constant CLK_PERIOD : time := 10 ns;
  constant TRACE_FILE : string := "../src/tb/node_element_trace.txt";

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal strobe : std_logic := '0';
  signal coeffs : coeffs_t;
  signal nb     : neighbours_t;
  signal u_out  : q123_t;
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
    assert done report "node_element_tb: timeout (valid never arrived?)" severity failure;
    wait;
  end process;

  dut : entity work.node_element
    port map (
      clk => clk, rst => rst, strobe => strobe,
      coeffs => coeffs, nb => nb, u_out => u_out, valid => valid
    );

  stim : process
    file     ftrace : text;
    variable l      : line;
    variable status : file_open_status;
    variable good   : boolean;
    variable vN, vS, vE, vW, vexp : integer;
    variable steps  : natural := 0;
  begin
    -- Coefficients matched to the trace header (gamma2=0.09, sigma=1.5).
    coeffs <= (gamma2     => to_q123(0.09),
               a0         => to_q123(0.99996875),
               sigk1      => to_q123(0.99996875),
               alpha      => Q123_ZERO,           -- linear (no chaos injection)
               gamma2_max => to_q123(0.5));
    nb <= (n => Q123_ZERO, s => Q123_ZERO, e => Q123_ZERO, w => Q123_ZERO);

    -- Synchronous reset to rest
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(u_out) = 0
      report "after reset: u_out /= 0" severity failure;

    -- Replay the recorded neighbour trace, bit-for-bit comparison each step
    file_open(status, ftrace, TRACE_FILE, read_mode);
    assert status = open_ok
      report "could not open trace file: " & TRACE_FILE severity failure;

    while not endfile(ftrace) loop
      readline(ftrace, l);
      read(l, vN, good);
      next when not good;          -- skip header / blank lines
      read(l, vS);
      read(l, vE);
      read(l, vW);
      read(l, vexp);

      wait until rising_edge(clk);
      nb <= (n => to_signed(vN, Q_BITS), s => to_signed(vS, Q_BITS),
             e => to_signed(vE, Q_BITS), w => to_signed(vW, Q_BITS));
      strobe <= '1';
      wait until rising_edge(clk);
      strobe <= '0';
      wait until rising_edge(clk) and valid = '1';

      assert to_integer(u_out) = vexp
        report "step " & integer'image(steps) & ": u_out = "
             & integer'image(to_integer(u_out)) & ", expected "
             & integer'image(vexp)
        severity failure;
      steps := steps + 1;
    end loop;
    file_close(ftrace);

    assert steps = 100
      report "expected 100 trace steps, ran " & integer'image(steps) severity failure;

    -- Reset edge case: return to rest, and confirm rest is a fixed point
    rst <= '1';
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(u_out) = 0
      report "after second reset: u_out /= 0" severity failure;

    nb <= (n => Q123_ZERO, s => Q123_ZERO, e => Q123_ZERO, w => Q123_ZERO);
    wait until rising_edge(clk); strobe <= '1';
    wait until rising_edge(clk); strobe <= '0';
    wait until rising_edge(clk) and valid = '1';
    assert to_integer(u_out) = 0
      report "rest is not a fixed point: u_out /= 0" severity failure;

    report "node_element_tb: all checks passed (" & integer'image(steps)
         & " trace steps, 0 mismatches)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
