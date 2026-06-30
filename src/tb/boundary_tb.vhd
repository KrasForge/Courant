-------------------------------------------------------------------------------
-- boundary_tb.vhd  -  validate fixed (Dirichlet) and free (Neumann) edges
--
-- Instantiates two 6x6 grid_mesh DUTs - one with FREE_BOUNDARY=false (fixed),
-- one with FREE_BOUNDARY=true (free) - drives both with an identical single-
-- node excitation impulse, and compares the corner pickups bit-for-bit against
-- golden traces from the reference model (model/QMesh2D.m) for each boundary
-- mode. The two pickups sit at opposite corners (0,0) and (5,5), so all four
-- edges (N/W and S/E) are exercised.
--
-- The struck node starts at A in the reference (single-node strike); the mesh
-- reaches the same state by injecting `exc=A` for one sample from rest, so the
-- mesh's state after step k equals the reference state after (k-1) steps -
-- i.e. mesh step k is compared against golden line k (which holds golden[k-1]).
--
-- Trace file: src/tb/boundary_trace.txt  ("Lfix Rfix Lfree Rfree" per step).
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

entity boundary_tb is
end entity boundary_tb;

architecture sim of boundary_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 6;
  constant NY         : positive := 6;
  constant STEPS      : positive := 60;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal strobe : std_logic := '0';
  signal coeffs : coeffs_t;
  signal exc_in : q123_t := (others => '0');
  signal exc_en : std_logic := '0';

  -- fixed-boundary DUT pickups
  signal lf, rf : q123_t;
  signal vf     : std_logic;
  -- free-boundary DUT pickups
  signal lq, rq : q123_t;
  signal vq     : std_logic;

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
    assert done report "boundary_tb: timeout" severity failure;
    wait;
  end process;

  -- Two meshes, identical except the boundary mode. Excitation at (2,2),
  -- pickups at the two opposite corners.
  dut_fixed : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false,
                 EXC_X => 2, EXC_Y => 2,
                 PICK_LX => 0, PICK_LY => 0, PICK_RX => 5, PICK_RY => 5)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => lf, pick_r => rf, valid => vf);

  dut_free : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => true,
                 EXC_X => 2, EXC_Y => 2,
                 PICK_LX => 0, PICK_LY => 0, PICK_RX => 5, PICK_RY => 5)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => lq, pick_r => rq, valid => vq);

  stim : process
    constant IMP : q123_t := to_q123(0.5);
    file     ft  : text;
    variable st  : file_open_status;
    variable l   : line;
    variable good : boolean;
    variable gLf, gRf, gLq, gRq : integer;
  begin
    coeffs <= (gamma2     => to_q123(0.09),
               a0         => to_q123(0.99996875),
               sigk1      => to_q123(0.99996875),
               alpha      => Q123_ZERO,           -- linear (no chaos injection)
               gamma2_max => to_q123(0.5));

    -- Reset both meshes to rest
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(lf) = 0 and to_integer(rf) = 0
       and to_integer(lq) = 0 and to_integer(rq) = 0
      report "after reset: meshes not at rest" severity failure;

    file_open(st, ft, "../src/tb/boundary_trace.txt", read_mode);
    assert st = open_ok report "cannot open boundary_trace.txt" severity failure;

    for k in 1 to STEPS loop
      -- next golden data line (skip header/blank)
      loop
        assert not endfile(ft) report "trace ended early" severity failure;
        readline(ft, l);
        read(l, gLf, good);
        exit when good;
      end loop;
      read(l, gRf); read(l, gLq); read(l, gRq);

      -- one mesh step for both DUTs; inject the impulse on step 1
      wait until rising_edge(clk);
      strobe <= '1';
      if k = 1 then
        exc_in <= IMP;
        exc_en <= '1';
      end if;
      wait until rising_edge(clk);
      strobe <= '0';
      exc_en <= '0';
      wait until rising_edge(clk) and vf = '1';

      assert to_integer(lf) = gLf and to_integer(rf) = gRf
        report "fixed step " & integer'image(k) & ": (" &
               integer'image(to_integer(lf)) & "," & integer'image(to_integer(rf)) &
               ") expected (" & integer'image(gLf) & "," & integer'image(gRf) & ")"
        severity failure;
      assert to_integer(lq) = gLq and to_integer(rq) = gRq
        report "free step " & integer'image(k) & ": (" &
               integer'image(to_integer(lq)) & "," & integer'image(to_integer(rq)) &
               ") expected (" & integer'image(gLq) & "," & integer'image(gRq) & ")"
        severity failure;
    end loop;
    file_close(ft);

    report "boundary_tb: all checks passed (fixed + free, " &
           integer'image(STEPS) & " steps, 0 mismatches)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
