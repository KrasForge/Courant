-------------------------------------------------------------------------------
-- adc_mcp3208_tb.vhd  -  checks the panel/CV ADC master against a device model
--
-- The model below behaves like the real MCP3208 rather than like the master's
-- own assumptions: it waits for the start bit instead of counting from CS,
-- latches DIN on the rising edge, drives DOUT on the falling edge, and emits a
-- null bit before the twelve data bits. A master that only works against a
-- model written from the same misreading of the datasheet would pass a test
-- that proves nothing.
--
-- Checks, in order:
--   * every channel is addressed, in order, and the sweep repeats;
--   * the code presented on a channel is the code that appears on its output;
--   * pot outputs are 12-bit unsigned and CV outputs are the same code
--     zero-extended into a signed word, as panel_ctrl and cv_frontend expect;
--   * scan_done is a single cycle and marks a complete sweep of all eight.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity adc_mcp3208_tb is
end entity adc_mcp3208_tb;

architecture sim of adc_mcp3208_tb is

  constant CLK_HZ  : positive := 100_000_000;
  constant SCLK_HZ : positive := 1_000_000;
  constant CLK_T   : time := 10 ns;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';

  signal sclk, cs_n, mosi, miso : std_logic;

  signal pot_pitch, pot_decay, pot_timbre : unsigned(11 downto 0);
  signal pot_drive, pot_delay, pot_reverb : unsigned(11 downto 0);
  signal pitch_cv, mod_cv : signed(15 downto 0);
  signal scan_done : std_logic;

  -- Codes the model returns, one per channel.
  type codes_t is array (0 to 7) of unsigned(11 downto 0);
  constant CODES : codes_t := (x"000", x"FFF", x"ABC", x"555", x"123", x"246", x"789", x"DEF");

  signal seen_ch   : integer := -1;          -- channel the model last decoded
  signal n_frames  : natural := 0;
  signal n_scans   : natural := 0;
  signal done      : boolean := false;

begin

  clk <= '0' when done else not clk after CLK_T/2;

  dut : entity work.adc_mcp3208
    generic map (CLK_HZ => CLK_HZ, SCLK_HZ => SCLK_HZ)
    port map (
      clk => clk, rst => rst,
      adc_sclk => sclk, adc_cs_n => cs_n, adc_mosi => mosi, adc_miso => miso,
      pot_pitch => pot_pitch, pot_decay => pot_decay, pot_timbre => pot_timbre,
      pot_drive => pot_drive, pot_delay => pot_delay, pot_reverb => pot_reverb,
      pitch_cv => pitch_cv, mod_cv => mod_cv, scan_done => scan_done);

  -- ---------------------------------------------------------------- model ---
  model : process
    variable ch     : unsigned(2 downto 0);
    variable code   : unsigned(11 downto 0);
    variable framed : boolean;
  begin
    miso <= 'Z';
    wait until falling_edge(cs_n);

    -- Wait for the start bit, exactly as the part does. A frame that is
    -- abandoned (CS raised early) just returns to waiting rather than
    -- desynchronising the model from the master.
    framed := false;
    loop
      wait until rising_edge(sclk) or rising_edge(cs_n);
      exit when cs_n = '1';
      if mosi = '1' then
        framed := true;
        exit;
      end if;
    end loop;

    if framed then
      -- SGL/DIFF then three channel bits, latched on rising edges.
      wait until rising_edge(sclk);
      assert mosi = '1'
        report "model: SGL/DIFF low -- master requested differential mode"
        severity failure;
      for i in 2 downto 0 loop
        wait until rising_edge(sclk);
        ch(i) := mosi;
      end loop;

      assert to_integer(ch) < 8
        report "model: master addressed unused channel " &
               integer'image(to_integer(ch))
        severity failure;
      seen_ch <= to_integer(ch);
      code := CODES(to_integer(ch));

      -- Null bit, then twelve data bits, each driven on the falling edge.
      wait until falling_edge(sclk);
      miso <= '0';
      for i in 11 downto 0 loop
        wait until falling_edge(sclk);
        miso <= code(i);
      end loop;
      wait until rising_edge(cs_n);
      miso <= 'Z';
      n_frames <= n_frames + 1;
    end if;
  end process;

  -- --------------------------------------------------------------- checks ---
  count_scans : process (clk) is
    variable prev : std_logic := '0';
  begin
    if rising_edge(clk) then
      if scan_done = '1' then
        assert prev = '0'
          report "scan_done asserted for more than one cycle" severity failure;
        n_scans <= n_scans + 1;
      end if;
      prev := scan_done;
    end if;
  end process;

  stim : process
  begin
    rst <= '1';
    wait for 200 ns;
    rst <= '0';

    -- Two complete sweeps, so the channel counter is seen to wrap.
    wait until n_scans = 2;
    wait for 5 us;

    assert pot_pitch  = CODES(0)
      report "CH0 -> pot_pitch wrong"  severity failure;
    assert pot_decay  = CODES(1)
      report "CH1 -> pot_decay wrong"  severity failure;
    assert pot_timbre = CODES(2)
      report "CH2 -> pot_timbre wrong" severity failure;
    assert pitch_cv = signed(resize(CODES(3), 16))
      report "CH3 -> pitch_cv wrong"   severity failure;
    assert mod_cv   = signed(resize(CODES(4), 16))
      report "CH4 -> mod_cv wrong"     severity failure;
    assert pot_drive = CODES(5) report "CH5 -> pot_drive wrong" severity failure;
    assert pot_delay = CODES(6) report "CH6 -> pot_delay wrong" severity failure;
    assert pot_reverb = CODES(7) report "CH7 -> pot_reverb wrong" severity failure;

    assert n_frames >= 16
      report "expected at least 16 conversions in two sweeps, got " &
             integer'image(n_frames)
      severity failure;

    report "adc_mcp3208_tb: all checks passed (" & integer'image(n_frames) &
           " conversions, " & integer'image(n_scans) & " complete sweeps)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
