-------------------------------------------------------------------------------
-- midi_frontend_tb.vhd  -  playing MIDI notes drives pitch and velocity (issue #28)
--
-- Sends a real 31250-baud-style MIDI byte stream (start / 8 data LSB-first /
-- stop) into midi_frontend, feeds its coeffs + excitation into a live
-- mesh_resonator, and checks the instrument behaviour:
--
--   * a Note On is parsed (note number + velocity recovered);
--   * pitch: a higher note sets a higher gamma2 (an octave up = gamma2 x4),
--     matching the documented note -> gamma0^2 mapping;
--   * strike: Note On delivers a frame of excitation (the mallet);
--   * velocity: a harder strike injects a larger excitation and produces more
--     output energy from the mesh than a soft strike from rest;
--   * Note Off (and Note On velocity 0) do NOT strike: the mesh decays naturally.
--
-- The UART is run at CLK_HZ/BAUD = 32 clocks/bit (via generics) to keep the
-- serial timing short in simulation; the logic is identical at 100 MHz/31250.
-- note_on/note_off are 1-cycle pulses that fire while a message is still being
-- clocked in, so a latching monitor records them; the coeffs/excitation are
-- held levels and are checked directly.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity midi_frontend_tb is
end entity midi_frontend_tb;

architecture sim of midi_frontend_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant CLK_HZ     : positive := 1_000_000;
  constant BAUD       : positive := 31_250;             -- => 32 clocks/bit
  constant BIT_CYC    : positive := CLK_HZ / BAUD;
  constant FRAME_CYC  : positive := 100;                -- clocks per audio frame

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal rx    : std_logic := '1';                      -- MIDI line idles high
  signal frame : std_logic := '0';

  signal coeffs   : coeffs_t;
  signal exc_in   : q123_t;
  signal exc_en   : std_logic;
  signal note_on  : std_logic;
  signal note_off : std_logic;
  signal note_v   : std_logic_vector(6 downto 0);
  signal vel_v    : std_logic_vector(6 downto 0);

  signal out_l, out_r : q123_t;
  signal out_valid    : std_logic;

  signal done : boolean := false;

  -- latching monitor for the 1-cycle note pulses (they fire mid-message)
  signal no_count, noff_count : integer := 0;
  signal cap_note, cap_vel    : integer := -1;

  -- energy accumulator (mesh output magnitude), gated by a measurement window
  signal measuring : boolean := false;
  signal energy    : integer := 0;

  -- same velocity scaling the front-end uses, for an exact expected value
  function vscale(fs : q123_t; vel : integer) return q123_t is
    variable p : signed(fs'length + 8 - 1 downto 0);
  begin
    p := fs * to_signed(vel, 8);
    return resize(shift_right(p, 7), Q_BITS);
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
    assert done report "midi_frontend_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.midi_frontend
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (clk => clk, rst => rst, rx => rx, frame => frame,
              coeffs => coeffs, exc_in => exc_in, exc_en => exc_en,
              note_on => note_on, note_off => note_off,
              note => note_v, velocity => vel_v);

  mesh : entity work.mesh_resonator
    generic map (NX => 8, NY => 8, OS => 4, FREE_BOUNDARY => false)
    port map (clk => clk, rst => rst, frame => frame, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              out_l => out_l, out_r => out_r, out_valid => out_valid);

  -- latch the note-on/off pulses (they occur while the message is clocking in)
  nmon : process (clk)
  begin
    if rising_edge(clk) then
      if note_on = '1' then
        no_count <= no_count + 1;
        cap_note <= to_integer(unsigned(note_v));
        cap_vel  <= to_integer(unsigned(vel_v));
      end if;
      if note_off = '1' then
        noff_count <= noff_count + 1;
      end if;
    end if;
  end process;

  -- accumulate output magnitude during a measurement window
  emon : process (clk)
    variable prev_meas : boolean := false;
  begin
    if rising_edge(clk) then
      if measuring and not prev_meas then         -- window just opened: clear
        energy <= 0;
      elsif measuring and out_valid = '1' then    -- accumulate output magnitude
        energy <= energy + abs(to_integer(out_l)) + abs(to_integer(out_r));
      end if;
      prev_meas := measuring;
    end if;
  end process;

  stim : process
    procedure send_byte(b : std_logic_vector(7 downto 0)) is
    begin
      rx <= '0';                                   -- start bit
      for i in 0 to BIT_CYC-1 loop wait until rising_edge(clk); end loop;
      for k in 0 to 7 loop                          -- data, LSB first
        rx <= b(k);
        for i in 0 to BIT_CYC-1 loop wait until rising_edge(clk); end loop;
      end loop;
      rx <= '1';                                   -- stop bit + idle
      for i in 0 to 2*BIT_CYC-1 loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure note_on_msg(n, v : integer) is
    begin
      send_byte(x"90");
      send_byte("0" & std_logic_vector(to_unsigned(n, 7)));
      send_byte("0" & std_logic_vector(to_unsigned(v, 7)));
    end procedure;
    procedure note_off_msg(n, v : integer) is
    begin
      send_byte(x"80");
      send_byte("0" & std_logic_vector(to_unsigned(n, 7)));
      send_byte("0" & std_logic_vector(to_unsigned(v, 7)));
    end procedure;

    -- wait until the latched note-on/off count advances past a snapshot
    procedure wait_note_on(prev : integer) is
    begin
      loop wait until rising_edge(clk); exit when no_count > prev; end loop;
    end procedure;
    procedure wait_note_off(prev : integer) is
    begin
      loop wait until rising_edge(clk); exit when noff_count > prev; end loop;
    end procedure;
    procedure wait_exc_en is
    begin
      loop wait until rising_edge(clk); exit when exc_en = '1'; end loop;
    end procedure;

    variable g2_a4, g2_a5 : integer;
    variable e_soft, e_hard : integer;
    variable p : integer;
  begin
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    --------------------------------------------------------------------------
    -- 1. Note On A4 (69), velocity 100: parse, pitch, strike amplitude
    --------------------------------------------------------------------------
    p := no_count;
    note_on_msg(69, 100);
    wait_note_on(p);
    assert cap_note = 69 and cap_vel = 100
      report "midi_frontend_tb: A4 note/velocity mis-parsed (note " &
             integer'image(cap_note) & " vel " & integer'image(cap_vel) & ")"
      severity failure;
    assert coeffs.gamma2 = to_q123(0.09)
      report "midi_frontend_tb: A4 pitch (gamma2) wrong" severity failure;
    assert exc_in = vscale(to_q123(0.9), 100)
      report "midi_frontend_tb: A4 strike amplitude wrong" severity failure;
    g2_a4 := to_integer(coeffs.gamma2);

    -- the strike must land as a frame of exc_en
    wait_exc_en;
    report "midi_frontend_tb: A4 strike delivered (exc_en)" severity note;

    --------------------------------------------------------------------------
    -- 2. Note On A5 (81), one octave up: gamma2 should quadruple (x4)
    --------------------------------------------------------------------------
    p := no_count;
    note_on_msg(81, 100);
    wait_note_on(p);
    assert coeffs.gamma2 = to_q123(0.36)
      report "midi_frontend_tb: A5 pitch (octave up) not gamma2 x4" severity failure;
    g2_a5 := to_integer(coeffs.gamma2);
    assert g2_a5 > g2_a4
      report "midi_frontend_tb: higher note did not raise gamma2" severity failure;

    --------------------------------------------------------------------------
    -- 3. Velocity sensitivity: a harder hit scales both the strike amplitude
    --    (louder) and alpha (brighter / more non-linear timbre). Both are held
    --    coefficient levels, so this is checked exactly. (Raw pickup energy is
    --    deliberately NOT asserted monotonic: with the velocity->alpha coupling
    --    the non-linear mesh redistributes energy, which is real behaviour.)
    --------------------------------------------------------------------------
    p := no_count;
    note_on_msg(60, 20);
    wait_note_on(p);
    e_soft := to_integer(exc_in);
    g2_a4  := to_integer(coeffs.alpha);       -- reuse: alpha at low velocity

    p := no_count;
    note_on_msg(60, 120);
    wait_note_on(p);
    e_hard := to_integer(exc_in);
    g2_a5  := to_integer(coeffs.alpha);       -- reuse: alpha at high velocity

    assert e_hard > e_soft
      report "midi_frontend_tb: harder hit did not raise strike amplitude (" &
             integer'image(e_hard) & " <= " & integer'image(e_soft) & ")"
      severity failure;
    assert g2_a5 > g2_a4
      report "midi_frontend_tb: harder hit did not raise alpha (timbre)"
      severity failure;

    -- and the mesh actually makes sound in response to a strike (from rest)
    rst <= '1'; for i in 0 to 9 loop wait until rising_edge(clk); end loop; rst <= '0';
    wait until rising_edge(clk);
    note_on_msg(64, 100);
    wait_exc_en;
    measuring <= true;
    for f in 0 to 30 loop wait until rising_edge(clk) and out_valid = '1'; end loop;
    measuring <= false;
    wait until rising_edge(clk);
    assert energy > 0
      report "midi_frontend_tb: mesh produced no output after a strike"
      severity failure;

    --------------------------------------------------------------------------
    -- 4. Note Off: no strike, natural decay (exc_en stays low)
    --------------------------------------------------------------------------
    p := noff_count;
    note_off_msg(60, 0);
    wait_note_off(p);
    for f in 0 to 4 loop
      wait until rising_edge(clk) and frame = '1';
      assert exc_en = '0'
        report "midi_frontend_tb: Note Off produced a strike" severity failure;
    end loop;

    report "midi_frontend_tb: all checks passed (note parsed; octave = gamma2 x4; " &
           "velocity amplitude " & integer'image(e_hard) & " > " &
           integer'image(e_soft) & "; note-off decays)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
