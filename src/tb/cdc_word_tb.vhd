-------------------------------------------------------------------------------
-- cdc_word_tb.vhd  -  multi-clock CDC: no loss / no corruption across the boundary
--
-- Two cdc_word instances exercise both directions of the I2S <-> mesh boundary
-- with asynchronous clocks of different frequency:
--   dut_in  : audio domain -> system domain (excitation sample)
--   dut_out : system domain -> audio domain (L/R pickup outputs)
--
-- Each direction streams a table of distinct 24-bit words (including the rails
-- and alternating bit patterns) and checks the destination recovers every word,
-- in order, bit-for-bit. Transfers are spaced wider than the destination
-- synchroniser latency, as in the real per-frame audio use.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity cdc_word_tb is
end entity cdc_word_tb;

architecture sim of cdc_word_tb is

  constant SYS_HALF : time := 5 ns;    -- 100 MHz system clock
  constant AUD_HALF : time := 35 ns;   -- ~14 MHz, async to sys
  constant N        : integer := 16;

  type tbl_t is array (0 to N-1) of integer;
  constant TBL : tbl_t := (
    0, 8388607, -8388608, 1, -1, 5592405, -5592406, 1193046,
    -1193046, 4194304, -4194304, 2796202, -2796203, 16, -16, 8388606);

  function w24(i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(i, 24));
  end function;

  signal sys_clk, aud_clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- excitation path: aud -> sys
  signal in_sd  : std_logic_vector(23 downto 0) := (others => '0');
  signal in_sv  : std_logic := '0';
  signal in_dd  : std_logic_vector(23 downto 0);
  signal in_dv  : std_logic;
  -- pickup path: sys -> aud
  signal out_sd : std_logic_vector(23 downto 0) := (others => '0');
  signal out_sv : std_logic := '0';
  signal out_dd : std_logic_vector(23 downto 0);
  signal out_dv : std_logic;

  signal rx_in  : integer := 0;
  signal rx_out : integer := 0;
  signal done   : boolean := false;

begin

  sys_gen : process begin
    while not done loop sys_clk <= '0'; wait for SYS_HALF; sys_clk <= '1'; wait for SYS_HALF; end loop; wait;
  end process;
  aud_gen : process begin
    while not done loop aud_clk <= '0'; wait for AUD_HALF; aud_clk <= '1'; wait for AUD_HALF; end loop; wait;
  end process;

  watchdog : process begin
    wait for 50 us;
    assert done report "cdc_word_tb: timeout" severity failure;
    wait;
  end process;

  dut_in : entity work.cdc_word
    generic map (WIDTH => 24)
    port map (src_clk => aud_clk, src_rst => rst, src_data => in_sd, src_valid => in_sv,
              dst_clk => sys_clk, dst_rst => rst, dst_data => in_dd, dst_valid => in_dv);

  dut_out : entity work.cdc_word
    generic map (WIDTH => 24)
    port map (src_clk => sys_clk, src_rst => rst, src_data => out_sd, src_valid => out_sv,
              dst_clk => aud_clk, dst_rst => rst, dst_data => out_dd, dst_valid => out_dv);

  -- ---- excitation source (audio domain) -----------------------------------
  src_in : process
  begin
    wait until rst = '0';
    for i in 0 to N-1 loop
      wait until rising_edge(aud_clk);
      in_sd <= w24(TBL(i)); in_sv <= '1';
      wait until rising_edge(aud_clk);
      in_sv <= '0';
      for w in 1 to 4 loop wait until rising_edge(aud_clk); end loop;
    end loop;
    wait;
  end process;

  -- ---- excitation sink (system domain) ------------------------------------
  dst_in : process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      if rst = '0' and in_dv = '1' and rx_in < N then
        assert in_dd = w24(TBL(rx_in))
          report "excitation CDC word " & integer'image(rx_in) & " corrupted"
          severity failure;
        rx_in <= rx_in + 1;
      end if;
    end if;
  end process;

  -- ---- pickup source (system domain) --------------------------------------
  src_out : process
  begin
    wait until rst = '0';
    for i in 0 to N-1 loop
      wait until rising_edge(sys_clk);
      out_sd <= w24(TBL(i)); out_sv <= '1';
      wait until rising_edge(sys_clk);
      out_sv <= '0';
      for w in 1 to 30 loop wait until rising_edge(sys_clk); end loop;  -- > slow-dst latency
    end loop;
    wait;
  end process;

  -- ---- pickup sink (audio domain) -----------------------------------------
  dst_out : process (aud_clk)
  begin
    if rising_edge(aud_clk) then
      if rst = '0' and out_dv = '1' and rx_out < N then
        assert out_dd = w24(TBL(rx_out))
          report "pickup CDC word " & integer'image(rx_out) & " corrupted"
          severity failure;
        rx_out <= rx_out + 1;
      end if;
    end if;
  end process;

  -- ---- finish when both directions have delivered all words ---------------
  fin : process
  begin
    rst <= '1';
    wait for 200 ns;
    rst <= '0';
    wait until rx_in = N and rx_out = N;
    report "cdc_word_tb: all checks passed (" & integer'image(N) &
           " words each way, no loss or corruption across async clocks)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
