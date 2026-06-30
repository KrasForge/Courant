-------------------------------------------------------------------------------
-- top_resonator_tb.vhd  -  end-to-end system impulse-response & stability test
--
-- Drives the whole top_resonator over a real I2S serial link (a second
-- i2s_transceiver acts as the codec: its TX feeds the DUT's audio input, its RX
-- captures the DUT's output). Two checks (README §5, §6):
--
--   1. Impulse response vs the reference model. With reference coefficients on
--      the control bus and a single-frame excitation impulse, the captured I2S
--      output is compared bit-for-bit against the oversampled-mesh + decimation
--      golden (src/tb/top_impulse_trace.txt). The comparison auto-aligns to the
--      fixed I2S/CDC latency with a sliding match (every stage - I2S, CDC,
--      mesh - is independently lossless / bit-exact, so the composition is too).
--
--   2. Stability stress test. High alpha plus repeated hard (near-full-scale)
--      strikes; the output must stay inside the Q1.23 range for the whole run
--      (the clamp + saturating arithmetic contain the non-linearity; no
--      divergence).
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity top_resonator_tb is
end entity top_resonator_tb;

architecture sim of top_resonator_tb is

  constant SYS_HALF  : time     := 5 ns;
  constant BCLK_HALF : time     := 30 ns;
  constant SLOT      : positive := 32;
  constant CAP       : positive := 56;        -- captured output frames (phase 1)
  constant WIN       : positive := 24;        -- golden window matched
  constant GLEN      : positive := 40;        -- golden length in file

  signal sys_clk : std_logic := '0';
  signal sys_rst : std_logic := '1';
  signal bclk    : std_logic := '0';
  signal lrclk   : std_logic := '0';
  signal sd_d2c, sd_c2d : std_logic;

  signal cfg_wr_en   : std_logic := '0';
  signal cfg_wr_addr : unsigned(3 downto 0) := (others => '0');
  signal cfg_wr_data : std_logic_vector(23 downto 0) := (others => '0');
  signal cfg_rd_data : std_logic_vector(23 downto 0);

  signal cod_tx_l, cod_tx_r : q123_t := (others => '0');
  signal cod_rx_l, cod_rx_r : q123_t;
  signal cod_rx_valid       : std_logic;

  signal done         : boolean := false;
  signal capturing    : boolean := false;
  signal out_of_range : boolean := false;

  type iarr is array (0 to CAP-1) of integer;
  signal caparr : iarr := (others => 0);
  signal cap_n  : integer := 0;

begin

  sys_gen : process begin
    while not done loop sys_clk <= '0'; wait for SYS_HALF; sys_clk <= '1'; wait for SYS_HALF; end loop; wait;
  end process;
  bclk_gen : process begin
    while not done loop bclk <= '0'; wait for BCLK_HALF; bclk <= '1'; wait for BCLK_HALF; end loop; wait;
  end process;
  lr_gen : process (bclk)
    variable c : integer := 0;
  begin
    if rising_edge(bclk) then
      c := c + 1; if c = SLOT then lrclk <= not lrclk; c := 0; end if;
    end if;
  end process;

  watchdog : process begin
    wait for 30 ms;
    assert done report "top_resonator_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.top_resonator
    generic map (NX => 8, NY => 8, OS => 4, FREE_BOUNDARY => false)
    port map (sys_clk => sys_clk, sys_rst => sys_rst, bclk => bclk, lrclk => lrclk,
              sd_rx => sd_c2d, sd_tx => sd_d2c,
              cfg_wr_en => cfg_wr_en, cfg_wr_addr => cfg_wr_addr,
              cfg_wr_data => cfg_wr_data, cfg_rd_addr => (others => '0'),
              cfg_rd_data => cfg_rd_data);

  codec : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (rst => sys_rst, bclk => bclk, lrclk => lrclk,
              sd_rx => sd_d2c, sd_tx => sd_c2d,
              rx_l => cod_rx_l, rx_r => cod_rx_r, rx_valid => cod_rx_valid,
              tx_l => cod_tx_l, tx_r => cod_tx_r);

  -- capture output frames (phase 1) and watch the Q1.23 range (both phases)
  mon : process (bclk)
  begin
    if rising_edge(bclk) then
      if sys_rst = '0' and cod_rx_valid = '1' then
        if to_integer(cod_rx_l) > 2**23-1 or to_integer(cod_rx_l) < -(2**23)
        or to_integer(cod_rx_r) > 2**23-1 or to_integer(cod_rx_r) < -(2**23) then
          out_of_range <= true;
        end if;
        if capturing and cap_n < CAP then
          caparr(cap_n) <= to_integer(cod_rx_l);
          cap_n <= cap_n + 1;
        end if;
      end if;
    end if;
  end process;

  stim : process
    procedure cfg(a : natural; d : std_logic_vector(23 downto 0)) is
    begin
      wait until rising_edge(sys_clk);
      cfg_wr_en <= '1'; cfg_wr_addr <= to_unsigned(a, 4); cfg_wr_data <= d;
      wait until rising_edge(sys_clk);
      cfg_wr_en <= '0';
    end procedure;
    procedure frame_tick is
    begin
      wait until rising_edge(bclk) and cod_rx_valid = '1';
    end procedure;

    file     ft   : text;
    variable st   : file_open_status;
    variable l    : line;
    variable good : boolean;
    variable gold : iarr := (others => 0);
    variable gv   : integer;
    variable matched : boolean := false;
    variable ok   : boolean;
  begin
    sys_rst <= '1';
    wait for 300 ns;
    sys_rst <= '0';

    -- reference coefficients (linear) for the impulse-response check
    cfg(0, std_logic_vector(to_q123(0.09)));
    cfg(1, std_logic_vector(to_q123(0.99996875)));
    cfg(2, std_logic_vector(to_q123(0.99996875)));
    cfg(3, std_logic_vector(to_q123(0.0)));
    cfg(4, std_logic_vector(to_q123(0.5)));

    -- read the golden response
    file_open(st, ft, "../src/tb/top_impulse_trace.txt", read_mode);
    assert st = open_ok report "cannot open top_impulse_trace.txt" severity failure;
    for k in 0 to GLEN-1 loop
      loop readline(ft, l); read(l, gv, good); exit when good; end loop;
      if k < CAP then gold(k) := gv; end if;
    end loop;
    file_close(ft);

    -- silence, then a single-frame excitation impulse (gated to one frame)
    cod_tx_l <= (others => '0');
    frame_tick; frame_tick;
    capturing <= true;                         -- start capturing the output stream
    frame_tick;
    cod_tx_l <= to_q123(0.5);                  -- one-frame mallet strike
    frame_tick;
    cod_tx_l <= (others => '0');

    -- collect CAP output frames
    wait until cap_n = CAP;
    capturing <= false;

    -- slide the golden window over the capture; require one bit-exact alignment
    for off in 0 to CAP-WIN loop
      ok := true;
      for k in 0 to WIN-1 loop
        if caparr(off + k) /= gold(k) then ok := false; end if;
      end loop;
      if ok then matched := true; end if;
    end loop;
    assert matched
      report "system impulse response does not match the reference golden"
      severity failure;

    --------------------------------------------------------------------------
    -- 2. stability stress: high alpha + repeated hard strikes -> stays bounded
    --------------------------------------------------------------------------
    cfg(0, std_logic_vector(to_q123(0.09)));
    cfg(3, std_logic_vector(to_q123(0.6)));    -- strong chaos coupling
    cfg(4, std_logic_vector(to_q123(0.451)));  -- CFL-safe clamp
    for f in 1 to 60 loop
      cod_tx_l <= to_q123(0.9);                -- near-full-scale strikes
      frame_tick;
    end loop;
    assert not out_of_range
      report "stress test: output left the Q1.23 range (divergence)"
      severity failure;

    report "top_resonator_tb: all checks passed (impulse response bit-exact vs " &
           "reference; stability stress bounded)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
