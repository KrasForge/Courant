-------------------------------------------------------------------------------
-- arty_synth.vhd  -  board wrapper for synth_top on the Arty A7 (issue #76)
--
-- Wraps the playable synth_top (#68) for a real Arty A7 build: an MMCM turns
-- the on-board 100 MHz oscillator into the system clock (100 MHz) and the audio
-- master clock (~12.288 MHz) for the Pmod I2S2 codec, and the front-panel
-- buttons/switches drive the reset and preset controls.
--
-- SYNTHESIS-ONLY: this file instantiates the Xilinx MMCME2_BASE primitive
-- (UNISIM), so it lives under syn/ and is NOT part of the GHDL simulation flow
-- (which globs src/rtl and stays vendor-neutral). synth_top itself is fully
-- simulated in src/tb/synth_top_tb.vhd; this wrapper only adds board clocking
-- and pin mapping.
--
-- MMCM: VCO = 100 MHz * 10 / 1 = 1000 MHz (in the Artix-7 -1 range).
--   CLKOUT1 = 1000 / 10      = 100 MHz     -> sys_clk
--   CLKOUT0 = 1000 / 81.375  = 12.2888 MHz -> mclk (~65 ppm high; audio-fine,
--            or drop in a Clocking Wizard / external 12.288 MHz osc for exact).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity arty_synth is
  generic (
    NVOICES  : positive := 4;
    NX       : positive := 8;
    NY       : positive := 8;
    OS       : positive := 4;
    TIME_MUX : boolean  := true          -- fold voices onto shared PEs (fits the part)
  );
  port (
    clk100     : in  std_logic;                       -- 100 MHz oscillator (E3)
    btn        : in  std_logic_vector(3 downto 0);    -- btn0 reset, btn1 recall, btn2 save
    sw         : in  std_logic_vector(3 downto 0);    -- preset index
    midi_rx    : in  std_logic;                       -- serial MIDI in
    -- Pmod I2S2 codec
    codec_mclk : out std_logic;
    codec_bclk : out std_logic;
    codec_lrclk: out std_logic;
    codec_sdin : out std_logic;                       -- audio to the DAC (sd_tx)
    -- status
    led        : out std_logic_vector(3 downto 0)     -- active voices
  );
end entity arty_synth;

architecture rtl of arty_synth is

  signal clkfb, clkfb_bufg          : std_logic;
  signal sys_clk_pre, mclk_pre      : std_logic;
  signal sys_clk, mclk              : std_logic;
  signal locked                     : std_logic;

  -- reset: held while the MMCM is unlocked or btn0 is pressed, synced to sys_clk
  signal rst_meta, rst_sync         : std_logic := '1';
  signal sys_rst                    : std_logic := '1';

  signal active : std_logic_vector(NVOICES-1 downto 0);

begin

  ----------------------------------------------------------------------------
  -- Clocking: 100 MHz -> sys_clk (100) + mclk (12.288)
  ----------------------------------------------------------------------------
  mmcm : MMCME2_BASE
    generic map (
      BANDWIDTH        => "OPTIMIZED",
      CLKIN1_PERIOD    => 10.000,        -- 100 MHz
      DIVCLK_DIVIDE    => 1,
      CLKFBOUT_MULT_F  => 10.000,        -- VCO = 1000 MHz
      CLKOUT0_DIVIDE_F => 81.375,        -- ~12.2888 MHz (mclk)
      CLKOUT1_DIVIDE   => 10,            -- 100 MHz (sys_clk)
      CLKOUT0_DUTY_CYCLE => 0.5, CLKOUT1_DUTY_CYCLE => 0.5,
      CLKOUT0_PHASE    => 0.0, CLKOUT1_PHASE => 0.0,
      CLKFBOUT_PHASE   => 0.0,
      REF_JITTER1      => 0.0,
      STARTUP_WAIT     => FALSE
    )
    port map (
      CLKIN1   => clk100,
      CLKFBIN  => clkfb_bufg,
      CLKFBOUT => clkfb,
      CLKOUT0  => mclk_pre,
      CLKOUT1  => sys_clk_pre,
      LOCKED   => locked,
      PWRDWN   => '0',
      RST      => '0'
    );

  fb_bufg  : BUFG port map (I => clkfb,       O => clkfb_bufg);
  sys_bufg : BUFG port map (I => sys_clk_pre, O => sys_clk);
  mck_bufg : BUFG port map (I => mclk_pre,    O => mclk);

  ----------------------------------------------------------------------------
  -- Reset synchroniser (release once locked, into the system clock)
  ----------------------------------------------------------------------------
  rst_proc : process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      rst_meta <= (not locked) or btn(0);
      rst_sync <= rst_meta;
      sys_rst  <= rst_sync;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- The playable synth
  ----------------------------------------------------------------------------
  core : entity work.synth_top
    generic map (NVOICES => NVOICES, NX => NX, NY => NY, OS => OS,
                 TIME_MUX => TIME_MUX,
                 CLK_HZ => 100_000_000, BAUD => 31_250,
                 MCLK_TO_BCLK => 4, BCLK_TO_LRCK => 64)
    port map (sys_clk => sys_clk, sys_rst => sys_rst, mclk => mclk,
              midi_rx => midi_rx,
              preset_index => unsigned(sw),
              preset_recall => btn(1), preset_save => btn(2),
              cfg_wr_en => '0', cfg_wr_addr => (others => '0'),
              cfg_wr_data => (others => '0'), cfg_rd_addr => (others => '0'),
              cfg_rd_data => open,
              codec_mclk => codec_mclk, codec_bclk => codec_bclk,
              codec_lrclk => codec_lrclk, sd_tx => codec_sdin,
              active => active);

  -- surface the active-voice mask on the LEDs (pad/truncate to 4)
  led_gen : for i in 0 to 3 generate
    on_g  : if i < NVOICES generate  led(i) <= active(i); end generate;
    off_g : if i >= NVOICES generate led(i) <= '0';       end generate;
  end generate;

end architecture rtl;
