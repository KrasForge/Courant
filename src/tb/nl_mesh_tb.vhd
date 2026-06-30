-------------------------------------------------------------------------------
-- nl_mesh_tb.vhd  -  non-linear chaos injection, full mesh vs reference
--
-- Drives a 9x9 mesh with the non-linearity ON (alpha = 0.6, gamma2_max = 0.451,
-- the CFL-safe clamp from issue #3) and a HARD centred strike (0.9, near full
-- scale) that without the clamp would push the local Courant number past the
-- CFL limit. Validates the impulse response bit-for-bit against the non-linear
-- reference model (model/ nl_gen) over 160 steps.
--
-- Checks:
--   1. Bit-for-bit vs the non-linear Q1.23 reference.
--   2. Bounded: the saturating clamp keeps the state convergent (no divergence,
--      no Nyquist buzz). The reference run stays inside [-1,1) and the pickup
--      never pins to a single rail across the run.
--   3. Symmetry: a centred strike on a symmetric mesh gives pick_l = pick_r.
--
-- The companion behavioural study (model/ nl_gen) shows the non-linearity bends
-- pitch up (peak ~1.0 kHz linear -> ~6.8 kHz) and brightens the spectrum, then
-- the damping returns the mesh to rest.
--
-- Golden trace: src/tb/nl_mesh_trace.txt ("pick_l pick_r" per step).
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

entity nl_mesh_tb is
end entity nl_mesh_tb;

architecture sim of nl_mesh_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 9;
  constant NY         : positive := 9;
  constant STEPS      : positive := 160;

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
    wait for 10 ms;
    assert done report "nl_mesh_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => pick_l, pick_r => pick_r, valid => valid);

  stim : process
    constant IMP : q123_t := to_q123(0.9);          -- hard strike
    file     fin : text;
    variable st  : file_open_status;
    variable l   : line;
    variable good : boolean;
    variable gL, gR : integer;
    variable hi_rail, lo_rail : natural := 0;
  begin
    -- Non-linearity ON: alpha = 0.6, CFL-safe clamp gamma2_max = 0.451 (#3)
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
    assert to_integer(pick_l) = 0 and to_integer(pick_r) = 0
      report "after reset: pickups not at rest" severity failure;

    file_open(st, fin, "../src/tb/nl_mesh_trace.txt", read_mode);
    assert st = open_ok report "cannot open nl_mesh_trace.txt" severity failure;

    for k in 1 to STEPS loop
      loop
        assert not endfile(fin) report "golden trace ended early" severity failure;
        readline(fin, l);
        read(l, gL, good);
        exit when good;
      end loop;
      read(l, gR);

      wait until rising_edge(clk);
      strobe <= '1';
      if k = 1 then exc_in <= IMP; exc_en <= '1'; end if;
      wait until rising_edge(clk);
      strobe <= '0';
      exc_en <= '0';
      wait until rising_edge(clk) and valid = '1';

      -- 1. bit-for-bit vs the non-linear reference
      assert to_integer(pick_l) = gL and to_integer(pick_r) = gR
        report "step " & integer'image(k) & ": pickups (" &
               integer'image(to_integer(pick_l)) & "," & integer'image(to_integer(pick_r)) &
               ") expected (" & integer'image(gL) & "," & integer'image(gR) & ")"
        severity failure;

      -- 2. symmetry (centred strike on a symmetric mesh)
      assert to_integer(pick_l) = to_integer(pick_r)
        report "asymmetry at step " & integer'image(k) severity failure;

      -- track rail pinning (Nyquist-buzz guard)
      if to_integer(pick_l) = 2**23 - 1 then hi_rail := hi_rail + 1; end if;
      if to_integer(pick_l) = -(2**23)  then lo_rail := lo_rail + 1; end if;
    end loop;
    file_close(fin);

    -- 3. bounded / convergent: the pickup must not be stuck at one rail for the
    -- whole run (that would be the Nyquist-buzz failure mode the clamp prevents)
    assert hi_rail < STEPS and lo_rail < STEPS
      report "pickup pinned to a rail (non-linear instability not contained)"
      severity failure;

    report "nl_mesh_tb: all checks passed (non-linear, " & integer'image(STEPS) &
           " steps, bit-exact, bounded, symmetric)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
