-------------------------------------------------------------------------------
-- synth_top_tb.vhd  -  end-to-end: MIDI in -> polyphonic audio out (#68)
--
-- Drives synth_top from a real serial MIDI stream and decodes its I2S output
-- with a loopback codec (a second i2s_transceiver whose RX samples sd_tx off the
-- generated BCLK/LRCLK). Checks the whole chain:
--
--   * a recalled preset sets the body, then MIDI note-ons allocate voices
--     (the `active` mask fills as notes are held);
--   * the codec recovers non-zero stereo audio (the voices actually sound);
--   * a second note adds a second voice and they mix;
--   * the output never leaves Q1.23 over the run (no divergence).
--
-- Clocks are scaled for a fast simulation (MIDI at CLK_HZ/BAUD = 32 sys-clocks
-- per bit; audio master clock chosen so one audio frame ~ 300 system clocks);
-- the logic is identical at 100 MHz / 12.288 MHz / 31250 baud.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity synth_top_tb is
end entity synth_top_tb;

architecture sim of synth_top_tb is

  constant SYS_HALF  : time     := 5 ns;    -- 100 MHz system clock
  constant MCLK_HALF : time     := 6 ns;    -- audio master clock (~83 MHz sim)
  constant NVOICES   : positive := 3;
  constant BIT_CYC   : positive := 32;      -- CLK_HZ/BAUD system clocks per MIDI bit

  signal sys_clk : std_logic := '0';
  signal sys_rst : std_logic := '1';
  signal mclk    : std_logic := '0';
  signal midi_rx : std_logic := '1';        -- MIDI line idles high

  signal preset_index : unsigned(3 downto 0) := (others => '0');
  signal preset_recall: std_logic := '0';

  signal codec_mclk, codec_bclk, codec_lrclk : std_logic;
  signal sd_tx : std_logic;
  signal active : std_logic_vector(NVOICES-1 downto 0);

  -- loopback codec RX (decodes sd_tx)
  signal cod_l, cod_r : q123_t;
  signal cod_v        : std_logic;

  signal done : boolean := false;

  -- monitors
  signal oor     : boolean := false;   -- output left Q1.23 (divergence)
  signal peakabs : integer := 0;       -- max |output| seen while measuring
  signal measuring : boolean := false;

  function popcount(v : std_logic_vector) return integer is
    variable c : integer := 0;
  begin
    for i in v'range loop if v(i) = '1' then c := c + 1; end if; end loop;
    return c;
  end function;

begin

  sys_gen : process begin
    while not done loop sys_clk <= '0'; wait for SYS_HALF; sys_clk <= '1'; wait for SYS_HALF; end loop; wait;
  end process;
  mclk_gen : process begin
    while not done loop mclk <= '0'; wait for MCLK_HALF; mclk <= '1'; wait for MCLK_HALF; end loop; wait;
  end process;

  watchdog : process begin
    wait for 8 ms;
    assert done report "synth_top_tb: timeout" severity failure;
    wait;
  end process;

  ----------------------------------------------------------------------------
  dut : entity work.synth_top
    generic map (NVOICES => NVOICES, NX => 8, NY => 8, OS => 4,
                 CLK_HZ => 1_000_000, BAUD => 31_250,
                 MCLK_TO_BCLK => 4, BCLK_TO_LRCK => 64)
    port map (sys_clk => sys_clk, sys_rst => sys_rst, mclk => mclk,
              midi_rx => midi_rx,
              preset_index => preset_index, preset_recall => preset_recall,
              preset_save => '0',
              cfg_wr_en => '0', cfg_wr_addr => (others => '0'),
              cfg_wr_data => (others => '0'), cfg_rd_addr => (others => '0'),
              cfg_rd_data => open,
              codec_mclk => codec_mclk, codec_bclk => codec_bclk,
              codec_lrclk => codec_lrclk, sd_tx => sd_tx, active => active);

  -- loopback codec: RX decodes the DAC stream off the generated clocks
  codec : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (rst => sys_rst, bclk => codec_bclk, lrclk => codec_lrclk,
              sd_rx => sd_tx, sd_tx => open,
              rx_l => cod_l, rx_r => cod_r, rx_valid => cod_v,
              tx_l => (others => '0'), tx_r => (others => '0'));

  -- divergence + output-level monitor (audio domain)
  mon : process (codec_bclk)
  begin
    if rising_edge(codec_bclk) then
      if sys_rst = '0' and cod_v = '1' then
        if to_integer(cod_l) > 2**23-1 or to_integer(cod_l) < -(2**23)
        or to_integer(cod_r) > 2**23-1 or to_integer(cod_r) < -(2**23) then
          oor <= true;
        end if;
        if measuring then
          if abs(to_integer(cod_l)) > peakabs then peakabs <= abs(to_integer(cod_l)); end if;
          if abs(to_integer(cod_r)) > peakabs then peakabs <= abs(to_integer(cod_r)); end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  stim : process
    procedure sys_step is begin wait until rising_edge(sys_clk); end procedure;

    procedure send_byte(b : std_logic_vector(7 downto 0)) is
    begin
      midi_rx <= '0';                              -- start bit
      for i in 0 to BIT_CYC-1 loop sys_step; end loop;
      for k in 0 to 7 loop                          -- data, LSB first
        midi_rx <= b(k);
        for i in 0 to BIT_CYC-1 loop sys_step; end loop;
      end loop;
      midi_rx <= '1';                              -- stop + idle
      for i in 0 to 2*BIT_CYC-1 loop sys_step; end loop;
    end procedure;

    procedure note_on(n, v : integer) is
    begin
      send_byte(x"90");
      send_byte("0" & std_logic_vector(to_unsigned(n, 7)));
      send_byte("0" & std_logic_vector(to_unsigned(v, 7)));
    end procedure;

    procedure wait_active(cnt : integer) is
    begin
      loop wait until rising_edge(sys_clk); exit when popcount(active) >= cnt; end loop;
    end procedure;

    procedure run_frames(k : integer) is
    begin
      for f in 0 to k-1 loop wait until rising_edge(codec_bclk) and cod_v = '1'; end loop;
    end procedure;
  begin
    sys_rst <= '1';
    for i in 0 to 20 loop sys_step; end loop;
    sys_rst <= '0';
    for i in 0 to 4 loop sys_step; end loop;

    -- recall the gong preset (index 1): sets the body (long decay)
    preset_index <= to_unsigned(1, 4);
    sys_step; preset_recall <= '1'; sys_step; preset_recall <= '0';
    run_frames(2);

    --------------------------------------------------------------------------
    -- 1. one note -> one voice, and it sounds
    --------------------------------------------------------------------------
    note_on(60, 100);
    wait_active(1);
    assert popcount(active) >= 1
      report "synth_top_tb: first note did not allocate a voice" severity failure;

    measuring <= true;
    run_frames(60);                       -- let the voice ring and reach the codec
    measuring <= false;
    run_frames(1);
    assert peakabs > 0
      report "synth_top_tb: no audio out of the codec after a note" severity failure;
    report "synth_top_tb: voice sounded, peak |out| = " & integer'image(peakabs)
      severity note;

    --------------------------------------------------------------------------
    -- 2. a second held note -> a second voice
    --------------------------------------------------------------------------
    note_on(67, 90);
    wait_active(2);
    assert popcount(active) >= 2
      report "synth_top_tb: second note did not allocate a second voice" severity failure;
    run_frames(40);

    --------------------------------------------------------------------------
    -- 3. no divergence anywhere in the run
    --------------------------------------------------------------------------
    assert not oor
      report "synth_top_tb: output left the Q1.23 range (divergence)" severity failure;

    report "synth_top_tb: all checks passed (MIDI -> " & integer'image(NVOICES) &
           "-voice polyphony -> I2S audio; voices allocate, sound, bounded)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
