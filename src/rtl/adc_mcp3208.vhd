-------------------------------------------------------------------------------
-- adc_mcp3208.vhd  -  SPI master for the panel/CV ADC (U4 on the Courant board)
--
-- The last piece between the board and the synth: cv_frontend and panel_ctrl
-- both expect samples "already digitised and presented synchronous to clk",
-- and this is what digitises them. It scans the five used channels of the
-- MCP3208 round-robin and holds the most recent conversion of each.
--
--   CH0 POT_PITCH   CH1 POT_DECAY   CH2 POT_TIMBRE      -> panel_ctrl (unsigned)
--   CH3 PITCH_ADC   CH4 MOD_ADC                         -> cv_frontend (signed)
--   CH5 POT_DRIVE   CH6 POT_DELAY   CH7 POT_REVERB     -> panel_ctrl FX macros
--
-- Protocol. Single-ended mode, MSB first. With CS low the part ignores leading
-- zeros until it sees the start bit, so the frame is:
--
--   DIN   1  1  D2 D1 D0                      start, SGL/DIFF=1, channel
--   DOUT              . null B11..B0          one null bit, then 12 data bits
--
-- DIN is sampled on the rising edge of SCLK and DOUT changes on the falling
-- edge, so MISO is sampled on the rising edge here. That is SPI mode 0. The
-- frame is 5 + 1 + 12 = 18 clocks; CS is raised between conversions, which the
-- part requires to start the next sample-and-hold.
--
-- Clock rate. The MCP3208 is specified for 2 MHz at 5 V but only 1 MHz at
-- 2.7 V. This board runs it at VDD = 3.3 V with VREF = 2.5 V, so SCLK_HZ
-- defaults to 1 MHz rather than interpolating between two datasheet corners on
-- a part whose sample-and-hold is the thing being traded away.
--
-- Scaling. The samples come out as the ADC's native 12-bit codes, zero-extended
-- for the CV outputs. Calibration belongs to cv_frontend's generics, not here.
-- Note that this board's CV divider is 20k/20k into a 2.5 V reference, so full
-- scale is 5 V in and one volt is 819.2 codes -- NOT the 4096 codes per volt
-- that cv_frontend's defaults assume. For 1V/oct tracking instantiate it with
-- CV_SCALE = 960, CV_SHIFT = 16 (65536/68.27 codes per semitone).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adc_mcp3208 is
  generic (
    CLK_HZ   : positive := 100_000_000;  -- system clock
    SCLK_HZ  : positive := 1_000_000;    -- SPI clock; see header before raising
    POT_W    : positive := 12;           -- panel_ctrl's width
    CV_W     : positive := 16            -- cv_frontend's width
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    -- SPI to U4
    adc_sclk   : out std_logic;
    adc_cs_n   : out std_logic;
    adc_mosi   : out std_logic;
    adc_miso   : in  std_logic;
    -- held conversions
    pot_pitch  : out unsigned(POT_W-1 downto 0);
    pot_decay  : out unsigned(POT_W-1 downto 0);
    pot_timbre : out unsigned(POT_W-1 downto 0);
    pot_drive  : out unsigned(POT_W-1 downto 0);
    pot_delay  : out unsigned(POT_W-1 downto 0);
    pot_reverb : out unsigned(POT_W-1 downto 0);
    pitch_cv   : out signed(CV_W-1 downto 0);
    mod_cv     : out signed(CV_W-1 downto 0);
    scan_done  : out std_logic           -- one cycle per completed sweep of all five
  );
end entity adc_mcp3208;

architecture rtl of adc_mcp3208 is

  -- Half-period of SCLK in system-clock cycles. At least 1, so the divider
  -- degrades to clk/2 rather than to a stuck output if CLK_HZ is ever small.
  constant HALF   : positive := maximum(1, CLK_HZ / (2 * SCLK_HZ));
  constant N_CH   : positive := 8;
  constant FRAME  : positive := 18;      -- 5 config + 1 null + 12 data

  type state_t is (IDLE, GAP, XFER);
  signal state  : state_t := IDLE;

  signal divcnt : natural range 0 to HALF-1  := 0;
  signal tick   : std_logic := '0';         -- one system cycle per SCLK half-period
  signal sclk_q : std_logic := '0';
  signal bitno  : natural range 0 to FRAME  := 0;
  signal chan   : natural range 0 to N_CH-1 := 0;
  signal shreg  : unsigned(11 downto 0) := (others => '0');
  signal gapcnt : natural range 0 to HALF*2 := 0;

  -- Config bits, MSB first: start, SGL/DIFF, D2, D1, D0.
  function cfg_bit (c : natural; i : natural) return std_logic is
    variable v : unsigned(4 downto 0);
  begin
    v := "11" & to_unsigned(c, 3);
    return v(4 - i);
  end function;

begin

  -- SCLK half-period strobe.
  process (clk) is
  begin
    if rising_edge(clk) then
      tick <= '0';
      if rst = '1' then
        divcnt <= 0;
      elsif divcnt = HALF-1 then
        divcnt <= 0;
        tick   <= '1';
      else
        divcnt <= divcnt + 1;
      end if;
    end if;
  end process;

  adc_sclk <= sclk_q;

  process (clk) is
  begin
    if rising_edge(clk) then
      scan_done <= '0';

      if rst = '1' then
        state      <= IDLE;
        sclk_q     <= '0';
        adc_cs_n   <= '1';
        adc_mosi   <= '0';
        bitno      <= 0;
        chan       <= 0;
        gapcnt     <= 0;
        shreg      <= (others => '0');
        pot_pitch  <= (others => '0');
        pot_decay  <= (others => '0');
        pot_timbre <= (others => '0');
        pot_drive  <= (others => '0');
        pot_delay  <= (others => '0');
        pot_reverb <= (others => '0');
        pitch_cv   <= (others => '0');
        mod_cv     <= (others => '0');

      elsif tick = '1' then
        case state is

          when IDLE =>
            -- Start a frame: CS low, first config bit presented before the
            -- first rising edge.
            adc_cs_n <= '0';
            sclk_q   <= '0';
            bitno    <= 0;
            adc_mosi <= cfg_bit(chan, 0);
            state    <= XFER;

          when XFER =>
            if sclk_q = '0' then
              -- Rising edge: the part samples DIN now, and DOUT is stable, so
              -- this is where MISO is read.
              sclk_q <= '1';
              if bitno >= 6 then          -- 0..4 config, 5 null, 6.. data
                shreg <= shreg(10 downto 0) & adc_miso;
              end if;
            else
              -- Falling edge: advance, present the next DIN bit.
              sclk_q <= '0';
              if bitno = FRAME-1 then
                adc_cs_n <= '1';
                gapcnt   <= 0;
                state    <= GAP;
              else
                bitno <= bitno + 1;
                if bitno + 1 <= 4 then
                  adc_mosi <= cfg_bit(chan, bitno + 1);
                else
                  adc_mosi <= '0';
                end if;
              end if;
            end if;

          when GAP =>
            -- CS must go high between conversions; hold it for one SCLK period
            -- so the sample-and-hold is released and re-acquired.
            if gapcnt = 1 then
              case chan is
                when 0 => pot_pitch  <= resize(shreg, POT_W);
                when 1 => pot_decay  <= resize(shreg, POT_W);
                when 2 => pot_timbre <= resize(shreg, POT_W);
                when 3 => pitch_cv   <= signed(resize(shreg, CV_W));
                when 4 => mod_cv     <= signed(resize(shreg, CV_W));
                when 5 => pot_drive  <= resize(shreg, POT_W);
                when 6 => pot_delay  <= resize(shreg, POT_W);
                when others => pot_reverb <= resize(shreg, POT_W);
              end case;
              if chan = N_CH-1 then
                chan      <= 0;
                scan_done <= '1';
              else
                chan <= chan + 1;
              end if;
              state <= IDLE;
            else
              gapcnt <= gapcnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
