-------------------------------------------------------------------------------
-- midi_uart_rx.vhd  -  MIDI serial receiver (31250 baud, 8N1)
--
-- MIDI is asynchronous serial at 31250 baud, one start bit (0), eight data bits
-- LSB-first, one stop bit (1), no parity (README §2 control; milestone M8). This
-- is a standard oversampling UART receiver: it finds the start-bit falling edge,
-- waits half a bit to the centre, then samples each of the eight data bits at
-- its centre and emits the assembled byte with a one-cycle `valid` strobe.
--
-- The bit period in system clocks is CLK_HZ / BAUD, computed at elaboration.
-- (At 100 MHz / 31250 that is 3200 clocks per bit.) The input `rx` is assumed
-- already synchronised to `clk` by the caller's two-flop synchroniser, or is
-- sampled directly in simulation.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity midi_uart_rx is
  generic (
    CLK_HZ : positive := 100_000_000;
    BAUD   : positive := 31_250
  );
  port (
    clk    : in  std_logic;
    rst    : in  std_logic;
    rx     : in  std_logic;                       -- serial MIDI input (idles '1')
    dout   : out std_logic_vector(7 downto 0);    -- received byte
    dvalid : out std_logic                        -- 1-cycle pulse: dout valid
  );
end entity midi_uart_rx;

architecture rtl of midi_uart_rx is
  constant CLK_PER_BIT : positive := CLK_HZ / BAUD;

  type state_t is (IDLE, START, DATA, STOP);
  signal state  : state_t := IDLE;
  signal cnt    : integer range 0 to CLK_PER_BIT-1 := 0;   -- clocks within a bit
  signal bitn   : integer range 0 to 7 := 0;               -- data bit index
  signal shreg  : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_d   : std_logic := '1';                        -- registered input
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state  <= IDLE;
        cnt    <= 0;
        bitn   <= 0;
        shreg  <= (others => '0');
        rx_d   <= '1';
        dout   <= (others => '0');
        dvalid <= '0';
      else
        rx_d   <= rx;
        dvalid <= '0';

        case state is
          when IDLE =>
            cnt  <= 0;
            bitn <= 0;
            if rx_d = '0' then          -- start-bit edge (line pulled low)
              state <= START;
            end if;

          when START =>                  -- wait to the middle of the start bit
            if cnt = CLK_PER_BIT/2 - 1 then
              if rx_d = '0' then         -- still low: a real start bit
                cnt   <= 0;
                state <= DATA;
              else                       -- glitch: abandon
                state <= IDLE;
              end if;
            else
              cnt <= cnt + 1;
            end if;

          when DATA =>                   -- sample each data bit at its centre
            if cnt = CLK_PER_BIT-1 then
              cnt          <= 0;
              shreg(bitn)  <= rx_d;      -- LSB-first
              if bitn = 7 then
                state <= STOP;
              else
                bitn <= bitn + 1;
              end if;
            else
              cnt <= cnt + 1;
            end if;

          when STOP =>                   -- one stop bit, then publish the byte
            if cnt = CLK_PER_BIT-1 then
              cnt    <= 0;
              dout   <= shreg;
              dvalid <= '1';
              state  <= IDLE;
            else
              cnt <= cnt + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
