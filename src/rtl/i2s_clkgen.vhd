-------------------------------------------------------------------------------
-- i2s_clkgen.vhd  -  I2S master clock generator for the Pmod I2S2 (README §6)
--
-- The Pmod I2S2 carries a Cirrus CS5343 (ADC) and CS4344 (DAC). Both are
-- HARDWARE-MODE (stand-alone) codecs: there is no I2C/SPI control port and no
-- register sequence to write. "Initialisation" is purely a matter of clocking:
-- the codec auto-detects its speed mode from the MCLK/LRCK ratio and starts
-- converting as soon as it sees valid, stable clocks at a supported ratio.
-- The FPGA must therefore be the I2S MASTER and generate all three clocks.
--
-- This block divides a single audio master clock `mclk` (e.g. 12.288 MHz =
-- 256 * 48 kHz, produced by an MMCM / clocking wizard from the 100 MHz board
-- oscillator) down to the serial bit clock and the word-select:
--
--   mclk  : audio master clock, forwarded to the codec MCLK pin    (256 * fs)
--   bclk  : serial bit clock = mclk / MCLK_TO_BCLK                 ( 64 * fs)
--   lrclk : word select      = bclk / BCLK_TO_LRCK                 (  1 * fs)
--
-- With the defaults (MCLK_TO_BCLK = 4, BCLK_TO_LRCK = 64) and a 12.288 MHz
-- mclk this yields BCLK = 3.072 MHz, LRCLK = 48 kHz, and MCLK/LRCK = 256, a
-- single-speed-mode ratio supported by both the CS5343 and the CS4344. LRCLK is
-- a 50%-duty square wave (32 BCLK low = left, 32 high = right), matching the
-- 24-bit (MSB-justified into a 32-bit slot) I2S frame of i2s_transceiver.
--
-- All outputs are derived from `mclk` in one synchronous process, so BCLK and
-- LRCLK are phase-locked to MCLK and to each other (no drift, deterministic
-- alignment). On real silicon, forward `mclk`/`bclk` to the codec through an
-- ODDR (clock-capable output) rather than logic; in simulation a direct
-- assignment is equivalent. The framing (1-BCLK delay, MSB-first) is handled by
-- i2s_transceiver; this block only provides the correctly-rated clocks.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2s_clkgen is
  generic (
    MCLK_TO_BCLK : positive := 4;    -- mclk / bclk  (must be even, >= 2)
    BCLK_TO_LRCK : positive := 64    -- bclk / lrclk (must be even, >= 2)
  );
  port (
    mclk   : in  std_logic;          -- audio master clock (e.g. 12.288 MHz)
    rst    : in  std_logic;          -- synchronous, active-high
    mclk_o : out std_logic;          -- master clock forwarded to the codec
    bclk   : out std_logic;          -- serial bit clock to the codec
    lrclk  : out std_logic           -- word select to the codec
  );
end entity i2s_clkgen;

architecture rtl of i2s_clkgen is
  signal bclk_cnt : integer range 0 to MCLK_TO_BCLK/2 - 1 := 0;
  signal lrck_cnt : integer range 0 to BCLK_TO_LRCK/2 - 1 := 0;
  signal bclk_i   : std_logic := '0';
  signal lrclk_i  : std_logic := '0';
begin

  assert (MCLK_TO_BCLK mod 2 = 0) and (BCLK_TO_LRCK mod 2 = 0)
    report "i2s_clkgen: MCLK_TO_BCLK and BCLK_TO_LRCK must both be even"
    severity failure;

  mclk_o <= mclk;          -- pass the master clock straight through to the codec
  bclk   <= bclk_i;
  lrclk  <= lrclk_i;

  process (mclk)
  begin
    if rising_edge(mclk) then
      if rst = '1' then
        bclk_cnt <= 0;
        lrck_cnt <= 0;
        bclk_i   <= '0';
        lrclk_i  <= '0';
      else
        if bclk_cnt = MCLK_TO_BCLK/2 - 1 then
          bclk_cnt <= 0;
          bclk_i   <= not bclk_i;
          -- advance the word-select once per BCLK period, counted on the edge
          -- where bclk is about to fall ('1' -> '0')
          if bclk_i = '1' then
            if lrck_cnt = BCLK_TO_LRCK/2 - 1 then
              lrck_cnt <= 0;
              lrclk_i  <= not lrclk_i;
            else
              lrck_cnt <= lrck_cnt + 1;
            end if;
          end if;
        else
          bclk_cnt <= bclk_cnt + 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
