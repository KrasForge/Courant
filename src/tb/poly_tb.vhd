-------------------------------------------------------------------------------
-- poly_tb.vhd  -  polyphony: independent voices, allocation, stealing, mix (#29)
--
-- Drives poly_voices with note_s-mapping events (the interface a MIDI/CV front-end
-- produces) and checks the polyphony behaviour:
--
--   * a note_s-on allocates a voice (active mask), and the mesh makes sound;
--   * several notes held at once allocate several voices and mix together
--     without divergence (output stays inside Q1.23 the whole run);
--   * with all voices busy, a further note_s-on steals a voice (bounded: the
--     active count never exceeds NVOICES) and still does not diverge;
--   * a note_s-off frees the voice playing that note_s (active bit clears).
--
-- NVOICES is a generic (here 3), demonstrating configurable polyphony.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity poly_tb is
end entity poly_tb;

architecture sim of poly_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NVOICES    : positive := 3;
  constant FRAME_CYC  : positive := 100;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal frame : std_logic := '0';

  signal note_on   : std_logic := '0';
  signal note_off  : std_logic := '0';
  signal note_s      : std_logic_vector(6 downto 0) := (others => '0');
  signal coeffs_in : coeffs_t;
  signal exc_in    : q123_t := (others => '0');

  signal out_l, out_r : q123_t;
  signal out_valid    : std_logic;
  signal active       : std_logic_vector(NVOICES-1 downto 0);

  signal done : boolean := false;

  -- monitors
  signal oor        : boolean := false;   -- any output left Q1.23 (divergence)
  signal measuring  : boolean := false;
  signal energy     : integer := 0;

  function popcount(v : std_logic_vector) return integer is
    variable c : integer := 0;
  begin
    for i in v'range loop if v(i) = '1' then c := c + 1; end if; end loop;
    return c;
  end function;

  function mk_coeffs(g2 : real) return coeffs_t is
  begin
    return (gamma2 => to_q123(g2), a0 => to_q123(0.99996875),
            sigk1 => to_q123(0.99996875), alpha => to_q123(0.05),
            gamma2_max => to_q123(0.451));
  end function;

begin

  clk_gen : process begin
    while not done loop clk <= '0'; wait for CLK_PERIOD/2; clk <= '1'; wait for CLK_PERIOD/2; end loop; wait;
  end process;

  frame_gen : process
    variable c : integer := 0;
  begin
    while not done loop
      wait until rising_edge(clk);
      c := c + 1;
      if c = FRAME_CYC then frame <= '1'; c := 0; else frame <= '0'; end if;
    end loop;
    wait;
  end process;

  watchdog : process begin
    wait for 5 ms;
    assert done report "poly_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.poly_voices
    generic map (NVOICES => NVOICES, NX => 8, NY => 8, OS => 4)
    port map (clk => clk, rst => rst, frame => frame,
              note_on => note_on, note_off => note_off, note => note_s,
              coeffs_in => coeffs_in, exc_in => exc_in,
              out_l => out_l, out_r => out_r, out_valid => out_valid,
              active => active);

  -- divergence + energy monitor (single driver of `energy`; cleared on the
  -- rising edge of `measuring` so the stimulus never drives it)
  mon : process (clk)
    variable prev_meas : boolean := false;
  begin
    if rising_edge(clk) then
      -- always watch for divergence
      if rst = '0' and out_valid = '1' then
        if to_integer(out_l) > 2**23-1 or to_integer(out_l) < -(2**23)
        or to_integer(out_r) > 2**23-1 or to_integer(out_r) < -(2**23) then
          oor <= true;
        end if;
      end if;
      -- energy accumulation window (single driver of `energy`)
      if measuring and not prev_meas then
        energy <= 0;
      elsif measuring and rst = '0' and out_valid = '1' then
        energy <= energy + abs(to_integer(out_l)) + abs(to_integer(out_r));
      end if;
      prev_meas := measuring;
    end if;
  end process;

  stim : process
    procedure do_note_on(n : integer; g2 : real; amp : real) is
    begin
      wait until rising_edge(clk);
      note_s      <= std_logic_vector(to_unsigned(n, 7));
      coeffs_in <= mk_coeffs(g2);
      exc_in    <= to_q123(amp);
      note_on   <= '1';
      wait until rising_edge(clk);
      note_on   <= '0';
    end procedure;
    procedure do_note_off(n : integer) is
    begin
      wait until rising_edge(clk);
      note_s     <= std_logic_vector(to_unsigned(n, 7));
      note_off <= '1';
      wait until rising_edge(clk);
      note_off <= '0';
    end procedure;
    procedure run_frames(k : integer) is
    begin
      for f in 0 to k-1 loop wait until rising_edge(clk) and out_valid = '1'; end loop;
    end procedure;
  begin
    coeffs_in <= mk_coeffs(0.09);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    --------------------------------------------------------------------------
    -- 1. one voice: allocate + sound
    --------------------------------------------------------------------------
    do_note_on(60, 0.09, 0.6);
    run_frames(3);
    assert popcount(active) = 1
      report "poly_tb: first note_s did not allocate exactly one voice" severity failure;
    measuring <= true; run_frames(20); measuring <= false;
    wait until rising_edge(clk);
    assert energy > 0 report "poly_tb: single voice silent" severity failure;

    --------------------------------------------------------------------------
    -- 2. polyphony: three notes held -> three voices, mixed, bounded
    --------------------------------------------------------------------------
    do_note_on(64, 0.16, 0.6);
    run_frames(2);
    do_note_on(67, 0.25, 0.6);
    run_frames(3);
    assert popcount(active) = NVOICES
      report "poly_tb: three notes did not fill all voices (active=" &
             integer'image(popcount(active)) & ")" severity failure;
    measuring <= true; run_frames(20); measuring <= false;
    wait until rising_edge(clk);
    assert energy > 0 report "poly_tb: polyphonic mix silent" severity failure;

    --------------------------------------------------------------------------
    -- 3. voice stealing: a 4th note_s with all voices busy -> still <= NVOICES
    --------------------------------------------------------------------------
    do_note_on(72, 0.30, 0.9);          -- hard strike, must steal
    run_frames(3);
    assert (popcount(active) <= NVOICES)
      report "poly_tb: active voices exceeded NVOICES (no stealing)" severity failure;
    assert popcount(active) = NVOICES
      report "poly_tb: stealing left a voice unallocated" severity failure;
    run_frames(20);

    --------------------------------------------------------------------------
    -- 4. note_s-off frees the voice playing that note_s
    --------------------------------------------------------------------------
    do_note_off(64);
    run_frames(2);
    assert popcount(active) = NVOICES-1
      report "poly_tb: note_s-off did not free a voice (active=" &
             integer'image(popcount(active)) & ")" severity failure;

    -- and no divergence anywhere in the run
    assert not oor
      report "poly_tb: output left the Q1.23 range (divergence)" severity failure;

    report "poly_tb: all checks passed (" & integer'image(NVOICES) &
           " voices: allocate, mix, steal (bounded), free; no divergence)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
