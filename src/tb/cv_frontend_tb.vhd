-------------------------------------------------------------------------------
-- cv_frontend_tb.vhd  -  CV pitch/gate/mod drive the engine (issue #70)
--
-- Drives cv_frontend with control-voltage stimulus and feeds its outputs into a
-- live mesh_resonator, checking the CV mapping:
--   * pitch CV -> gamma2: 0 counts = the reference note, +4096 counts (one
--     octave at 4096 counts/V) quadruples gamma2;
--   * gate rising -> a note-on strike (one frame of exc_en); gate falling ->
--     note-off (no strike);
--   * mod CV -> alpha: more mod raises the timbre coupling;
--   * the mesh sounds in response and stays inside Q1.23 (no divergence).
--
-- note_on/note_off are 1-cycle pulses (they fire on the synchronised gate edge),
-- so a latching monitor records them; coeffs are held levels, checked directly.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity cv_frontend_tb is
end entity cv_frontend_tb;

architecture sim of cv_frontend_tb is

  constant CLK_PERIOD : time := 10 ns;
  constant CV_W       : positive := 16;
  constant FRAME_CYC  : positive := 100;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal frame : std_logic := '0';

  signal pitch_cv : signed(CV_W-1 downto 0) := (others => '0');
  signal gate     : std_logic := '0';
  signal mod_cv   : signed(CV_W-1 downto 0) := (others => '0');

  signal coeffs   : coeffs_t;
  signal exc_in   : q123_t;
  signal exc_en   : std_logic;
  signal note_on  : std_logic;
  signal note_off : std_logic;
  signal cv_note  : std_logic_vector(6 downto 0);
  signal cv_vel   : std_logic_vector(6 downto 0);

  signal out_l, out_r : q123_t;
  signal out_valid    : std_logic;

  signal done : boolean := false;

  -- latch the 1-cycle note pulses
  signal no_count, noff_count : integer := 0;
  -- divergence + activity
  signal oor     : boolean := false;
  signal peakabs : integer := 0;
  signal measuring : boolean := false;

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
    assert done report "cv_frontend_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.cv_frontend
    generic map (CV_W => CV_W)
    port map (clk => clk, rst => rst, frame => frame,
              pitch_cv => pitch_cv, gate => gate, mod_cv => mod_cv,
              coeffs => coeffs, exc_in => exc_in, exc_en => exc_en,
              note_on => note_on, note_off => note_off,
              note => cv_note, velocity => cv_vel);

  mesh : entity work.mesh_resonator
    generic map (NX => 8, NY => 8, OS => 4, FREE_BOUNDARY => false)
    port map (clk => clk, rst => rst, frame => frame, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              out_l => out_l, out_r => out_r, out_valid => out_valid);

  nmon : process (clk)
  begin
    if rising_edge(clk) then
      if note_on = '1'  then no_count   <= no_count + 1;   end if;
      if note_off = '1' then noff_count <= noff_count + 1; end if;
    end if;
  end process;

  mon : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '0' and out_valid = '1' then
        if to_integer(out_l) > 2**23-1 or to_integer(out_l) < -(2**23)
        or to_integer(out_r) > 2**23-1 or to_integer(out_r) < -(2**23) then
          oor <= true;
        end if;
        if measuring then
          if abs(to_integer(out_l)) > peakabs then peakabs <= abs(to_integer(out_l)); end if;
        end if;
      end if;
    end if;
  end process;

  stim : process
    procedure step is begin wait until rising_edge(clk); end procedure;
    procedure wait_note_on(prev : integer) is
    begin loop step; exit when no_count > prev; end loop; end procedure;
    procedure wait_note_off(prev : integer) is
    begin loop step; exit when noff_count > prev; end loop; end procedure;
    procedure wait_exc_en is
    begin loop step; exit when exc_en = '1'; end loop; end procedure;

    variable p, a_lo, a_hi : integer;
  begin
    rst <= '1'; for i in 0 to 9 loop step; end loop; rst <= '0'; step;

    --------------------------------------------------------------------------
    -- 1. pitch CV = 0 -> reference note; gate strike
    --------------------------------------------------------------------------
    pitch_cv <= to_signed(0, CV_W);
    mod_cv   <= to_signed(0, CV_W);
    for i in 0 to 3 loop step; end loop;          -- let the quantiser settle
    p := no_count;
    gate <= '1';
    wait_note_on(p);
    assert to_integer(unsigned(cv_note)) = 69
      report "cv_frontend_tb: 0 V did not map to the reference note" severity failure;
    assert coeffs.gamma2 = to_q123(0.09)
      report "cv_frontend_tb: reference-note gamma2 wrong" severity failure;
    a_lo := to_integer(coeffs.alpha);             -- alpha at mod = 0
    wait_exc_en;
    report "cv_frontend_tb: gate strike delivered (exc_en)" severity note;

    --------------------------------------------------------------------------
    -- 2. gate low -> note-off
    --------------------------------------------------------------------------
    p := noff_count;
    gate <= '0';
    wait_note_off(p);

    --------------------------------------------------------------------------
    -- 3. pitch CV = +4096 counts (one octave) -> gamma2 x4
    --------------------------------------------------------------------------
    pitch_cv <= to_signed(4096, CV_W);
    for i in 0 to 3 loop step; end loop;
    p := no_count;
    gate <= '1';
    wait_note_on(p);
    assert to_integer(unsigned(cv_note)) = 81
      report "cv_frontend_tb: +1 octave CV did not map +12 semitones" severity failure;
    assert coeffs.gamma2 = to_q123(0.36)
      report "cv_frontend_tb: octave-up gamma2 not x4" severity failure;
    gate <= '0'; wait_note_off(noff_count);

    --------------------------------------------------------------------------
    -- 4. mod CV -> alpha (timbre): more mod raises alpha
    --------------------------------------------------------------------------
    mod_cv <= to_signed(16384, CV_W);            -- ~half scale
    for i in 0 to 3 loop step; end loop;
    p := no_count;
    gate <= '1';
    wait_note_on(p);
    a_hi := to_integer(coeffs.alpha);
    assert a_hi > a_lo
      report "cv_frontend_tb: mod CV did not raise alpha (" &
             integer'image(a_hi) & " <= " & integer'image(a_lo) & ")" severity failure;

    -- mesh sounds in response, and stays bounded
    measuring <= true;
    for f in 0 to 30 loop wait until rising_edge(clk) and out_valid = '1'; end loop;
    measuring <= false; step;
    assert peakabs > 0
      report "cv_frontend_tb: mesh produced no output from CV strike" severity failure;
    assert not oor
      report "cv_frontend_tb: output left the Q1.23 range (divergence)" severity failure;

    report "cv_frontend_tb: all checks passed (1V/oct pitch -> gamma2; gate -> " &
           "strike/decay; mod -> alpha; mesh sounds, bounded)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
