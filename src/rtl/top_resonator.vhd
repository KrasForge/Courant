-------------------------------------------------------------------------------
-- top_resonator.vhd  -  end-to-end FPGA resonator (README §3, §5)
--
-- One entity tying the whole engine together:
--   I2S RX  ->  CDC  ->  oversampled non-linear mesh  ->  CDC  ->  I2S TX
-- with a control/register bus supplying the precomputed coefficients.
--
--   * i2s_transceiver (audio / BCLK domain): RX captures the incoming sample
--     (the mallet), TX streams the two pickups as L/R.
--   * cdc_word (excitation): brings the mallet sample from the I2S domain into
--     the mesh (system-clock) domain. Its dst_valid is the per-frame strobe
--     that advances the mesh, so the excitation is always fresh when the mesh
--     steps.
--   * mesh_resonator (system-clock domain): runs the NX*NY grid OS time-steps
--     per audio frame, injecting the excitation, and decimates the stereo
--     pickups to one audio sample per frame.
--   * cdc_word (pickups): brings the stereo output back into the I2S domain.
--   * preset_bank (system-clock domain): runtime coefficients to the mesh,
--     plus factory/user presets recalled via preset_index/recall/save.
--
-- Generics expose mesh size, oversampling factor, and boundary mode. A single
-- global reset is used for both domains (sufficient for simulation; a real
-- build would synchronise reset into each clock domain).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity top_resonator is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    OS            : positive := 4;
    FREE_BOUNDARY : boolean  := false;
    TIME_MUX      : boolean  := false  -- false: spatial mesh; true: time-multiplexed
  );
  port (
    -- system (mesh) domain
    sys_clk     : in  std_logic;
    sys_rst     : in  std_logic;
    -- I2S (audio) domain
    bclk        : in  std_logic;
    lrclk       : in  std_logic;
    sd_rx       : in  std_logic;          -- audio in  (from ADC)
    sd_tx       : out std_logic;          -- audio out (to DAC)
    -- control/register bus (system domain)
    cfg_wr_en     : in  std_logic;
    cfg_wr_addr   : in  unsigned(3 downto 0);
    cfg_wr_data   : in  std_logic_vector(23 downto 0);
    cfg_rd_addr   : in  unsigned(3 downto 0);
    cfg_rd_data   : out std_logic_vector(23 downto 0);
    -- preset control (system domain); default to a no-op so existing
    -- instantiations that only use the register port are unaffected
    preset_index  : in  unsigned(3 downto 0) := (others => '0');
    preset_recall : in  std_logic := '0';    -- pulse: load preset_index
    preset_save   : in  std_logic := '0'      -- pulse: save into a user slot
  );
end entity top_resonator;

architecture rtl of top_resonator is

  -- I2S domain
  signal rx_l, rx_r : q123_t;
  signal rx_valid   : std_logic;
  signal tx_l, tx_r : q123_t;

  -- coefficients (system domain)
  signal coeffs : coeffs_t;

  -- excitation CDC (I2S -> system)
  signal exc_slv   : std_logic_vector(23 downto 0);
  signal exc_valid : std_logic;          -- also the mesh frame strobe

  -- mesh outputs (system domain)
  signal out_l, out_r : q123_t;
  signal out_valid    : std_logic;

  -- pickup CDC (system -> I2S), L and R carried together (48 bits)
  signal pick_src : std_logic_vector(47 downto 0);
  signal pick_dst : std_logic_vector(47 downto 0);

begin

  ----------------------------------------------------------------------------
  -- I2S transceiver (audio domain)
  ----------------------------------------------------------------------------
  i2s : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (rst => sys_rst, bclk => bclk, lrclk => lrclk,
              sd_rx => sd_rx, sd_tx => sd_tx,
              rx_l => rx_l, rx_r => rx_r, rx_valid => rx_valid,
              tx_l => tx_l, tx_r => tx_r);

  ----------------------------------------------------------------------------
  -- Control / register bus (system domain)
  ----------------------------------------------------------------------------
  ctrl : entity work.preset_bank
    port map (clk => sys_clk, rst => sys_rst,
              wr_en => cfg_wr_en, wr_addr => cfg_wr_addr, wr_data => cfg_wr_data,
              rd_addr => cfg_rd_addr, rd_data => cfg_rd_data,
              preset_index => preset_index, recall => preset_recall, save => preset_save,
              coeffs => coeffs,
              pick_lx => open, pick_ly => open, pick_rx => open, pick_ry => open,
              free_boundary => open);

  ----------------------------------------------------------------------------
  -- Excitation CDC: the mallet (rx_l) crosses into the mesh domain. Its
  -- dst_valid is the per-frame strobe that advances the mesh.
  ----------------------------------------------------------------------------
  cdc_exc : entity work.cdc_word
    generic map (WIDTH => 24)
    port map (src_clk => bclk,     src_rst => sys_rst,
              src_data => std_logic_vector(rx_l), src_valid => rx_valid,
              dst_clk => sys_clk,  dst_rst => sys_rst,
              dst_data => exc_slv, dst_valid => exc_valid);

  ----------------------------------------------------------------------------
  -- Oversampled non-linear mesh (system domain)
  ----------------------------------------------------------------------------
  core : entity work.mesh_resonator
    generic map (NX => NX, NY => NY, OS => OS, FREE_BOUNDARY => FREE_BOUNDARY,
                 TIME_MUX => TIME_MUX)
    port map (clk => sys_clk, rst => sys_rst,
              frame => exc_valid, coeffs => coeffs,
              exc_in => signed(exc_slv), exc_en => '1',
              out_l => out_l, out_r => out_r, out_valid => out_valid);

  ----------------------------------------------------------------------------
  -- Pickup CDC: stereo output crosses back into the I2S domain.
  ----------------------------------------------------------------------------
  pick_src <= std_logic_vector(out_l) & std_logic_vector(out_r);

  cdc_pick : entity work.cdc_word
    generic map (WIDTH => 48)
    port map (src_clk => sys_clk, src_rst => sys_rst,
              src_data => pick_src, src_valid => out_valid,
              dst_clk => bclk,     dst_rst => sys_rst,
              dst_data => pick_dst, dst_valid => open);

  tx_l <= signed(pick_dst(47 downto 24));
  tx_r <= signed(pick_dst(23 downto 0));

end architecture rtl;
