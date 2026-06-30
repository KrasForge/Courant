-------------------------------------------------------------------------------
-- pickup_tb.vhd  -  stereo pickup taps: distinct, routed, and configurable
--
-- Two 8x8 grid_mesh DUTs with identical dynamics (same excitation impulse) but
-- different pickup-tap generics:
--   dut_def : DEFAULT taps  -> (NX/4, NY/2) and (3*NX/4, NY/2)
--   dut_cfg : CUSTOM  taps  -> (1,1) and (7,3)
-- Each DUT's pick_l / pick_r are compared bit-for-bit against the reference
-- model (model/QMesh2D.m) sampled at the corresponding node coordinates. This
-- proves the taps are routed to the configured nodes and that the location is
-- controlled by the generics. It also checks the two channels are distinct.
--
-- Trace file: src/tb/pickup_trace.txt  ("dA_L dA_R dB_L dB_R" per step), where
-- dA_* are the default-tap nodes and dB_* the custom-tap nodes. As in the
-- boundary test, the single-node strike is reproduced by one `exc` injection
-- from rest, so mesh step k is compared against golden line k.
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

entity pickup_tb is
end entity pickup_tb;

architecture sim of pickup_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 8;
  constant NY         : positive := 8;
  constant STEPS      : positive := 40;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal strobe : std_logic := '0';
  signal coeffs : coeffs_t;
  signal exc_in : q123_t := (others => '0');
  signal exc_en : std_logic := '0';

  signal a_l, a_r : q123_t;   -- default-tap DUT
  signal a_v      : std_logic;
  signal b_l, b_r : q123_t;   -- custom-tap DUT
  signal b_v      : std_logic;

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
    assert done report "pickup_tb: timeout" severity failure;
    wait;
  end process;

  -- Default taps: PICK_* left at their defaults (NX/4, NY/2) and (3*NX/4, NY/2).
  -- EXC overridden to the struck node so dynamics match the reference run.
  dut_def : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false,
                 EXC_X => 2, EXC_Y => 2)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => a_l, pick_r => a_r, valid => a_v);

  -- Custom taps: relocate both pickups via generics.
  dut_cfg : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false,
                 EXC_X => 2, EXC_Y => 2,
                 PICK_LX => 1, PICK_LY => 1, PICK_RX => 7, PICK_RY => 3)
    port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => b_l, pick_r => b_r, valid => b_v);

  stim : process
    constant IMP : q123_t := to_q123(0.5);
    file     ft  : text;
    variable st  : file_open_status;
    variable l   : line;
    variable good : boolean;
    variable gAL, gAR, gBL, gBR : integer;
    variable saw_distinct : boolean := false;
  begin
    coeffs <= (gamma2 => to_q123(0.09),
               a0     => to_q123(0.99996875),
               sigk1  => to_q123(0.99996875));

    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(a_l) = 0 and to_integer(a_r) = 0
       and to_integer(b_l) = 0 and to_integer(b_r) = 0
      report "after reset: pickups not at rest" severity failure;

    file_open(st, ft, "../src/tb/pickup_trace.txt", read_mode);
    assert st = open_ok report "cannot open pickup_trace.txt" severity failure;

    for k in 1 to STEPS loop
      loop
        assert not endfile(ft) report "trace ended early" severity failure;
        readline(ft, l);
        read(l, gAL, good);
        exit when good;
      end loop;
      read(l, gAR); read(l, gBL); read(l, gBR);

      wait until rising_edge(clk);
      strobe <= '1';
      if k = 1 then exc_in <= IMP; exc_en <= '1'; end if;
      wait until rising_edge(clk);
      strobe <= '0';
      exc_en <= '0';
      wait until rising_edge(clk) and a_v = '1';

      -- default taps routed to (NX/4,NY/2) and (3*NX/4,NY/2)
      assert to_integer(a_l) = gAL and to_integer(a_r) = gAR
        report "default tap step " & integer'image(k) & ": got (" &
               integer'image(to_integer(a_l)) & "," & integer'image(to_integer(a_r)) &
               ") expected (" & integer'image(gAL) & "," & integer'image(gAR) & ")"
        severity failure;
      -- custom taps routed to (1,1) and (7,3)
      assert to_integer(b_l) = gBL and to_integer(b_r) = gBR
        report "custom tap step " & integer'image(k) & ": got (" &
               integer'image(to_integer(b_l)) & "," & integer'image(to_integer(b_r)) &
               ") expected (" & integer'image(gBL) & "," & integer'image(gBR) & ")"
        severity failure;

      if to_integer(a_l) /= to_integer(a_r) then
        saw_distinct := true;
      end if;
    end loop;
    file_close(ft);

    assert saw_distinct
      report "left and right pickups were never distinct" severity failure;

    report "pickup_tb: all checks passed (default + custom taps, " &
           integer'image(STEPS) & " steps, distinct L/R, 0 mismatches)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
