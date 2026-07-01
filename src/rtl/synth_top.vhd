-------------------------------------------------------------------------------
-- synth_top.vhd  -  end-to-end playable synth (MIDI -> polyphony -> codec) (#68)
--
-- Ties the M8 building blocks into one top-level instrument:
--
--   MIDI in --> [sync] --> midi_frontend --> note events + per-note coeffs/exc
--                                    \                 |
--            preset_bank --> base coeffs (a0/sigk1/gamma2_max, decay/CFL)
--                                          |
--                          merge (note pitch/timbre + preset body) --> coeffs
--                                          v
--                    poly_voices (NVOICES independent meshes + mix) --> L/R
--                                          v
--                    pickup CDC (system -> audio clock) --> i2s_transceiver TX
--                                          v
--                                       sd_tx --> codec DAC
--
--   i2s_clkgen (I2S MASTER): from the audio master clock `mclk` it generates
--   MCLK/BCLK/LRCLK for the codec; sample_strobe crosses LRCLK back into the
--   system clock as the per-audio-frame `frame` that advances the mesh.
--
-- Two clock domains: the system clock (mesh, MIDI, presets) and the audio I2S
-- clock (transceiver). The only crossings are the pickup word (cdc_word) and the
-- LRCLK->frame strobe (sample_strobe); a single global reset is used for both
-- (sufficient for simulation, synchronise per-domain for a real build).
--
-- Coefficient split: the note sets pitch (gamma2) and, via velocity, timbre
-- (alpha); the recalled preset sets the "body" (a0/sigk1 decay + gamma2_max
-- CFL clamp). So a preset picks the instrument and notes play it.
--
-- Output-only (a synth voice): the codec ADC input is unused (sd_rx tied off).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity synth_top is
  generic (
    -- voices / mesh
    NVOICES       : positive := 4;
    NX            : positive := 8;
    NY            : positive := 8;
    OS            : positive := 4;
    FREE_BOUNDARY : boolean  := false;
    TIME_MUX      : boolean  := false;
    -- MIDI UART (system-clock rate / MIDI baud)
    CLK_HZ        : positive := 100_000_000;
    BAUD          : positive := 31_250;
    -- I2S clock division from the audio master clock
    MCLK_TO_BCLK  : positive := 4;
    BCLK_TO_LRCK  : positive := 64
  );
  port (
    -- system (mesh / control) domain
    sys_clk      : in  std_logic;
    sys_rst      : in  std_logic;
    -- audio master clock (e.g. 12.288 MHz from an MMCM)
    mclk         : in  std_logic;
    -- serial MIDI in
    midi_rx      : in  std_logic;
    -- preset control (system domain)
    preset_index : in  unsigned(3 downto 0) := (others => '0');
    preset_recall: in  std_logic := '0';
    preset_save  : in  std_logic := '0';
    -- register edit / read-back (system domain)
    cfg_wr_en    : in  std_logic := '0';
    cfg_wr_addr  : in  unsigned(3 downto 0) := (others => '0');
    cfg_wr_data  : in  std_logic_vector(23 downto 0) := (others => '0');
    cfg_rd_addr  : in  unsigned(3 downto 0) := (others => '0');
    cfg_rd_data  : out std_logic_vector(23 downto 0);
    -- codec pins (audio domain)
    codec_mclk   : out std_logic;
    codec_bclk   : out std_logic;
    codec_lrclk  : out std_logic;
    sd_tx        : out std_logic;         -- audio to the DAC
    -- observability
    active       : out std_logic_vector(NVOICES-1 downto 0)
  );
end entity synth_top;

architecture rtl of synth_top is

  -- generated I2S clocks (audio domain)
  signal bclk_i, lrclk_i : std_logic;

  -- per-audio-frame strobe (system domain)
  signal frame : std_logic;

  -- MIDI input synchroniser (into system clock)
  signal rx_meta, rx_sync : std_logic := '1';

  -- midi_frontend outputs (note mapping)
  signal m_coeffs   : coeffs_t;
  signal m_exc_in   : q123_t;
  signal m_exc_en   : std_logic;
  signal m_note_on  : std_logic;
  signal m_note_off : std_logic;
  signal m_note     : std_logic_vector(6 downto 0);
  signal m_vel      : std_logic_vector(6 downto 0);

  -- preset_bank base coefficients
  signal p_coeffs : coeffs_t;

  -- merged voice coefficients (note pitch/timbre + preset body)
  signal v_coeffs : coeffs_t;

  -- polyphonic mix (system domain)
  signal mix_l, mix_r : q123_t;
  signal mix_valid    : std_logic;

  -- pickup CDC (system -> audio)
  signal pick_src : std_logic_vector(47 downto 0);
  signal pick_dst : std_logic_vector(47 downto 0);
  signal tx_l, tx_r : q123_t;

begin

  ----------------------------------------------------------------------------
  -- I2S master clock generation + codec clock pins
  ----------------------------------------------------------------------------
  clkgen : entity work.i2s_clkgen
    generic map (MCLK_TO_BCLK => MCLK_TO_BCLK, BCLK_TO_LRCK => BCLK_TO_LRCK)
    port map (mclk => mclk, rst => sys_rst,
              mclk_o => codec_mclk, bclk => bclk_i, lrclk => lrclk_i);
  codec_bclk  <= bclk_i;
  codec_lrclk <= lrclk_i;

  ----------------------------------------------------------------------------
  -- per-audio-frame strobe: LRCLK -> system-clock `frame`
  ----------------------------------------------------------------------------
  strobe : entity work.sample_strobe
    port map (sys_clk => sys_clk, rst => sys_rst, lrclk => lrclk_i, frame => frame);

  ----------------------------------------------------------------------------
  -- MIDI input two-flop synchroniser (async serial -> system clock)
  ----------------------------------------------------------------------------
  sync_proc : process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      if sys_rst = '1' then
        rx_meta <= '1'; rx_sync <= '1';
      else
        rx_meta <= midi_rx;
        rx_sync <= rx_meta;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- MIDI front-end: note -> pitch / strike / timbre
  ----------------------------------------------------------------------------
  midi : entity work.midi_frontend
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (clk => sys_clk, rst => sys_rst, rx => rx_sync, frame => frame,
              coeffs => m_coeffs, exc_in => m_exc_in, exc_en => m_exc_en,
              note_on => m_note_on, note_off => m_note_off,
              note => m_note, velocity => m_vel);

  ----------------------------------------------------------------------------
  -- Preset bank: base "body" coefficients + register edit/read-back
  ----------------------------------------------------------------------------
  presets : entity work.preset_bank
    port map (clk => sys_clk, rst => sys_rst,
              wr_en => cfg_wr_en, wr_addr => cfg_wr_addr, wr_data => cfg_wr_data,
              rd_addr => cfg_rd_addr, rd_data => cfg_rd_data,
              preset_index => preset_index, recall => preset_recall, save => preset_save,
              coeffs => p_coeffs,
              pick_lx => open, pick_ly => open, pick_rx => open, pick_ry => open,
              free_boundary => open);

  -- merge: note sets pitch (gamma2) + velocity timbre (alpha); preset sets the
  -- body (decay a0/sigk1, CFL clamp gamma2_max)
  v_coeffs.gamma2     <= m_coeffs.gamma2;
  v_coeffs.alpha      <= m_coeffs.alpha;
  v_coeffs.a0         <= p_coeffs.a0;
  v_coeffs.sigk1      <= p_coeffs.sigk1;
  v_coeffs.gamma2_max <= p_coeffs.gamma2_max;

  ----------------------------------------------------------------------------
  -- Polyphonic voice pool (system domain)
  ----------------------------------------------------------------------------
  voices : entity work.poly_voices
    generic map (NVOICES => NVOICES, NX => NX, NY => NY, OS => OS,
                 FREE_BOUNDARY => FREE_BOUNDARY, TIME_MUX => TIME_MUX)
    port map (clk => sys_clk, rst => sys_rst, frame => frame,
              note_on => m_note_on, note_off => m_note_off, note => m_note,
              coeffs_in => v_coeffs, exc_in => m_exc_in,
              out_l => mix_l, out_r => mix_r, out_valid => mix_valid,
              active => active);

  ----------------------------------------------------------------------------
  -- Pickup CDC: stereo mix crosses into the I2S (audio) domain
  ----------------------------------------------------------------------------
  pick_src <= std_logic_vector(mix_l) & std_logic_vector(mix_r);

  cdc_pick : entity work.cdc_word
    generic map (WIDTH => 48)
    port map (src_clk => sys_clk, src_rst => sys_rst,
              src_data => pick_src, src_valid => mix_valid,
              dst_clk => bclk_i,   dst_rst => sys_rst,
              dst_data => pick_dst, dst_valid => open);

  tx_l <= signed(pick_dst(47 downto 24));
  tx_r <= signed(pick_dst(23 downto 0));

  ----------------------------------------------------------------------------
  -- I2S transceiver (audio domain): stream the stereo pickups to the DAC
  ----------------------------------------------------------------------------
  i2s : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (rst => sys_rst, bclk => bclk_i, lrclk => lrclk_i,
              sd_rx => '0', sd_tx => sd_tx,
              rx_l => open, rx_r => open, rx_valid => open,
              tx_l => tx_l, tx_r => tx_r);

end architecture rtl;
