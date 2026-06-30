-------------------------------------------------------------------------------
-- mesh_resonator_tb.vhd  -  oversampling + decimation path validation
--
-- Drives a 9x9 mesh_resonator at OS = 4 with a hard centred impulse and checks
-- the decimated audio-rate output bit-for-bit against the reference model
-- (model/ os_gen: oversampled non-linear mesh + boxcar decimation) over 256
-- audio frames. Coefficients are precomputed for the oversampled rate
-- (gamma2 = (c*(k/4)/h)^2, etc.).
--
-- The companion study (model/ os_gen) measures the aliasing reduction: spectral
-- SNR vs a 16x ground truth rises monotonically with the oversampling factor
-- (1x: -8.7 dB, 2x: -5.0, 4x: 0.3, 8x: 10.0), i.e. measurable aliasing
-- reduction vs 1x.
--
-- Golden trace: src/tb/os_trace.txt  ("out_l" per frame).
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

entity mesh_resonator_tb is
end entity mesh_resonator_tb;

architecture sim of mesh_resonator_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 9;
  constant NY         : positive := 9;
  constant OS         : positive := 4;
  constant FRAMES     : positive := 256;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal frame  : std_logic := '0';
  signal coeffs : coeffs_t;
  signal exc_in : q123_t := (others => '0');
  signal exc_en : std_logic := '0';
  signal out_l  : q123_t;
  signal out_r  : q123_t;
  signal ovalid : std_logic;

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
    wait for 20 ms;
    assert done report "mesh_resonator_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.mesh_resonator
    generic map (NX => NX, NY => NY, OS => OS, FREE_BOUNDARY => false)
    port map (clk => clk, rst => rst, frame => frame, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              out_l => out_l, out_r => out_r, out_valid => ovalid);

  stim : process
    constant IMP : q123_t := to_q123(0.5);
    file     fin : text;
    variable st  : file_open_status;
    variable l   : line;
    variable good : boolean;
    variable gExp : integer;
  begin
    -- Oversampled-rate coefficients for OS = 4 (from model/ os_gen), as exact
    -- Q1.23 integers: gamma2 = (c*(k/4)/h)^2 = 0.005625, alpha = gamma2*beta,
    -- a0 = sigk1 = 1 - sigma*(k/4), gamma2_max = 0.451.
    coeffs <= (gamma2     => to_signed(  47186, Q_BITS),
               a0         => to_signed(8388542, Q_BITS),
               sigk1      => to_signed(8388542, Q_BITS),
               alpha      => to_signed( 314589, Q_BITS),
               gamma2_max => to_signed(3783262, Q_BITS));

    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    assert to_integer(out_l) = 0 and to_integer(out_r) = 0
      report "after reset: output not at rest" severity failure;

    file_open(st, fin, "../src/tb/os_trace.txt", read_mode);
    assert st = open_ok report "cannot open os_trace.txt" severity failure;

    for f in 1 to FRAMES loop
      loop
        assert not endfile(fin) report "golden trace ended early" severity failure;
        readline(fin, l);
        read(l, gExp, good);
        exit when good;
      end loop;

      wait until rising_edge(clk);
      frame <= '1';
      if f = 1 then exc_in <= IMP; exc_en <= '1'; end if;
      wait until rising_edge(clk);
      frame <= '0';
      wait until rising_edge(clk) and ovalid = '1';
      if f = 1 then exc_en <= '0'; end if;

      assert to_integer(out_l) = gExp
        report "frame " & integer'image(f) & ": out_l = " &
               integer'image(to_integer(out_l)) & ", expected " &
               integer'image(gExp)
        severity failure;
    end loop;
    file_close(fin);

    report "mesh_resonator_tb: all checks passed (OS=4, " &
           integer'image(FRAMES) & " frames, decimated output bit-exact)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
