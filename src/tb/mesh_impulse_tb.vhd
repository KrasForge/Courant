-------------------------------------------------------------------------------
-- mesh_impulse_tb.vhd  -  mesh impulse-response and linear-physics validation
--
-- Strikes a symmetric 9x9 mesh at its centre and validates the impulse response
-- against the reference model (model/QMesh2D.m), the M2 "validate linear
-- physics" goal:
--
--   1. Bit-for-bit match of the stereo pickups vs the Q1.23 reference over 128
--      steps. The Q1.23 mesh matches the float reference to ~97 dB SNR at the
--      pickup (measured in model/, comfortably within the documented Q1.23
--      error budget; see docs/fixed_point_analysis.md / issue #4).
--   2. Symmetry: a centred strike on a left/right-symmetric mesh must give
--      identical left/right pickups. Integer Q1.23 arithmetic is exactly
--      symmetric, so pick_l = pick_r bit-for-bit every step. (The float
--      reference is only symmetric to rounding, because FP addition is
--      non-associative - the fixed-point mesh is actually more symmetric.)
--   3. Captures the impulse response to sim/mesh_impulse_response.txt.
--
-- A 9x9 mesh with default generics already places the excitation at the centre
-- (4,4) and the pickups at the mirror nodes (4,2) and (4,6).
--
-- Golden trace: src/tb/mesh_impulse_trace.txt ("pick_l pick_r" per step). The
-- centred single-node strike is reproduced by one `exc` injection from rest,
-- so mesh step k is compared against golden line k.
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

entity mesh_impulse_tb is
end entity mesh_impulse_tb;

architecture sim of mesh_impulse_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 9;
  constant NY         : positive := 9;
  constant STEPS      : positive := 128;

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
    assert done report "mesh_impulse_tb: timeout" severity failure;
    wait;
  end process;

  -- 9x9 mesh, all default generics: excitation at centre (4,4), pickups at the
  -- mirror nodes (NX/4, NY/2) = (4,2) and (3*NX/4, NY/2) = (4,6).
  dut : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => pick_l, pick_r => pick_r, valid => valid);

  stim : process
    constant IMP : q123_t := to_q123(0.5);
    file     fin  : text;
    file     fout : text;
    variable st   : file_open_status;
    variable l, o : line;
    variable good : boolean;
    variable gL, gR : integer;
  begin
    coeffs <= (gamma2 => to_q123(0.09),
               a0     => to_q123(0.99996875),
               sigk1  => to_q123(0.99996875));

    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(pick_l) = 0 and to_integer(pick_r) = 0
      report "after reset: pickups not at rest" severity failure;

    file_open(st, fin, "../src/tb/mesh_impulse_trace.txt", read_mode);
    assert st = open_ok report "cannot open mesh_impulse_trace.txt" severity failure;

    -- Capture the impulse response into sim/ (artefact for inspection).
    file_open(st, fout, "mesh_impulse_response.txt", write_mode);
    write(o, string'("# step pick_l pick_r  (9x9 centred impulse)"));
    writeline(fout, o);

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

      -- 1. Bit-for-bit vs the Q1.23 reference
      assert to_integer(pick_l) = gL and to_integer(pick_r) = gR
        report "step " & integer'image(k) & ": pickups (" &
               integer'image(to_integer(pick_l)) & "," & integer'image(to_integer(pick_r)) &
               ") expected (" & integer'image(gL) & "," & integer'image(gR) & ")"
        severity failure;

      -- 2. Symmetry: centred strike on a symmetric mesh -> identical L/R
      assert to_integer(pick_l) = to_integer(pick_r)
        report "asymmetry at step " & integer'image(k) & ": pick_l = " &
               integer'image(to_integer(pick_l)) & ", pick_r = " &
               integer'image(to_integer(pick_r))
        severity failure;

      -- 3. Capture
      write(o, k);          write(o, string'(" "));
      write(o, to_integer(pick_l)); write(o, string'(" "));
      write(o, to_integer(pick_r));
      writeline(fout, o);
    end loop;
    file_close(fin);
    file_close(fout);

    report "mesh_impulse_tb: all checks passed (" & integer'image(STEPS) &
           " steps, bit-exact vs reference, L/R symmetric)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
