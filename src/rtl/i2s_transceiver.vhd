-------------------------------------------------------------------------------
-- i2s_transceiver.vhd  -  I2S RX/TX (README §3 Interfaces, §5)
--
-- Standard (Philips) I2S slave: BCLK and LRCLK (word select) are inputs from
-- the codec. Data is MSB-first with the one-BCLK delay after each WS edge;
-- WS = '0' selects the left channel, '1' the right.
--
--   * RX (serial -> parallel): captures the incoming stereo sample. rx_l is the
--     "mallet" excitation; rx_valid pulses once per L+R frame.
--   * TX (parallel -> serial): streams tx_l / tx_r (the two pickup nodes).
--
-- SD is sampled by RX on the BCLK rising edge and driven by TX on the falling
-- edge, so a direct sd_tx -> sd_rx loopback is bit-accurate. The shift logic is
-- slot-width agnostic (24-bit data, MSB-justified): any extra LSBs in a wider
-- slot (e.g. 32-bit) are sent as zeros and ignored on receive.
--
-- DATA_BITS = 24 maps the I2S word directly onto signed Q1.23 (q123_t).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity i2s_transceiver is
  generic (
    DATA_BITS : positive := 24            -- I2S word width (= Q1.23)
  );
  port (
    rst      : in  std_logic;
    bclk     : in  std_logic;             -- bit clock (from codec)
    lrclk    : in  std_logic;             -- word select: '0' left, '1' right
    sd_rx    : in  std_logic;             -- serial data in  (from ADC)
    sd_tx    : out std_logic;             -- serial data out (to DAC)
    -- parallel receive (excitation / mallet)
    rx_l     : out q123_t;
    rx_r     : out q123_t;
    rx_valid : out std_logic;             -- pulse: a full L+R frame received
    -- parallel transmit (stereo pickups), latched at each channel's WS edge
    tx_l     : in  q123_t;
    tx_r     : in  q123_t
  );
end entity i2s_transceiver;

architecture rtl of i2s_transceiver is
  signal rx_ws_d : std_logic := '0';
  signal rx_sr   : std_logic_vector(DATA_BITS-1 downto 0) := (others => '0');
  signal rx_cnt  : integer range 0 to DATA_BITS := 0;

  signal tx_ws_d : std_logic := '0';
  signal tx_sr   : std_logic_vector(DATA_BITS-1 downto 0) := (others => '0');
begin

  -- ---- Receive: sample SD on the rising edge, MSB-first --------------------
  rx_proc : process (bclk)
  begin
    if rising_edge(bclk) then
      if rst = '1' then
        rx_ws_d  <= lrclk;
        rx_sr    <= (others => '0');
        rx_cnt   <= 0;
        rx_l     <= (others => '0');
        rx_r     <= (others => '0');
        rx_valid <= '0';
      else
        rx_valid <= '0';
        if lrclk /= rx_ws_d then               -- channel boundary
          if rx_ws_d = '0' then                -- left word completed
            rx_l <= signed(rx_sr);
          else                                 -- right word completed: frame done
            rx_r     <= signed(rx_sr);
            rx_valid <= '1';
          end if;
          rx_cnt <= 0;                          -- one-BCLK delay slot, no shift
        elsif rx_cnt < DATA_BITS then
          rx_sr  <= rx_sr(DATA_BITS-2 downto 0) & sd_rx;
          rx_cnt <= rx_cnt + 1;
        end if;
        rx_ws_d <= lrclk;
      end if;
    end if;
  end process;

  -- ---- Transmit: drive SD on the falling edge, MSB-first -------------------
  tx_proc : process (bclk)
  begin
    if falling_edge(bclk) then
      if rst = '1' then
        tx_ws_d <= lrclk;
        tx_sr   <= (others => '0');
        sd_tx   <= '0';
      else
        if lrclk /= tx_ws_d then               -- channel boundary: load word
          if lrclk = '0' then
            tx_sr <= std_logic_vector(tx_l);
          else
            tx_sr <= std_logic_vector(tx_r);
          end if;
          sd_tx <= '0';                         -- one-BCLK delay slot
        else
          sd_tx <= tx_sr(DATA_BITS-1);          -- MSB out
          tx_sr <= tx_sr(DATA_BITS-2 downto 0) & '0';
        end if;
        tx_ws_d <= lrclk;
      end if;
    end if;
  end process;

end architecture rtl;
