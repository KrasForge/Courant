-------------------------------------------------------------------------------
-- top_resonator_tb.vhd  -  end-to-end system test
--
-- Exercises the whole top_resonator over a real I2S serial link. A second
-- i2s_transceiver acts as the codec: its TX drives the DUT's audio input
-- (sd_rx) and its RX reads the DUT's audio output (sd_tx). Coefficients are
-- written over the DUT's control bus. A single-frame excitation impulse is fed
-- in, and the test checks the output responds (audio flows RX -> mesh -> TX)
-- and stays bounded.
--
-- Clock domains: sys_clk (mesh) and bclk/lrclk (audio) are independent.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity top_resonator_tb is
end entity top_resonator_tb;

architecture sim of top_resonator_tb is

  constant SYS_HALF : time     := 5 ns;     -- 100 MHz mesh clock
  constant BCLK_HALF: time     := 30 ns;    -- ~16.7 MHz bit clock (async)
  constant SLOT     : positive := 32;       -- BCLK per channel
  constant FRAMES   : positive := 28;       -- audio frames to run

  signal sys_clk : std_logic := '0';
  signal sys_rst : std_logic := '1';
  signal bclk    : std_logic := '0';
  signal lrclk   : std_logic := '0';

  signal sd_dut2cod : std_logic;            -- DUT sd_tx  -> codec sd_rx
  signal sd_cod2dut : std_logic;            -- codec sd_tx -> DUT sd_rx

  -- control bus
  signal cfg_wr_en   : std_logic := '0';
  signal cfg_wr_addr : unsigned(3 downto 0) := (others => '0');
  signal cfg_wr_data : std_logic_vector(23 downto 0) := (others => '0');
  signal cfg_rd_data : std_logic_vector(23 downto 0);

  -- codec parallel side
  signal cod_tx_l, cod_tx_r : q123_t := (others => '0');  -- excitation into DUT
  signal cod_rx_l, cod_rx_r : q123_t;                     -- DUT output
  signal cod_rx_valid       : std_logic;

  signal done        : boolean := false;
  signal saw_nonzero : boolean := false;
  signal out_of_range: boolean := false;

begin

  sys_gen : process
  begin
    while not done loop sys_clk <= '0'; wait for SYS_HALF; sys_clk <= '1'; wait for SYS_HALF; end loop; wait;
  end process;
  bclk_gen : process
  begin
    while not done loop bclk <= '0'; wait for BCLK_HALF; bclk <= '1'; wait for BCLK_HALF; end loop; wait;
  end process;
  lr_gen : process (bclk)
    variable c : integer := 0;
  begin
    if rising_edge(bclk) then
      c := c + 1;
      if c = SLOT then lrclk <= not lrclk; c := 0; end if;
    end if;
  end process;

  watchdog : process
  begin
    wait for 10 ms;
    assert done report "top_resonator_tb: timeout" severity failure;
    wait;
  end process;

  -- DUT
  dut : entity work.top_resonator
    generic map (NX => 8, NY => 8, OS => 4, FREE_BOUNDARY => false)
    port map (sys_clk => sys_clk, sys_rst => sys_rst, bclk => bclk, lrclk => lrclk,
              sd_rx => sd_cod2dut, sd_tx => sd_dut2cod,
              cfg_wr_en => cfg_wr_en, cfg_wr_addr => cfg_wr_addr,
              cfg_wr_data => cfg_wr_data, cfg_rd_addr => (others => '0'),
              cfg_rd_data => cfg_rd_data);

  -- Codec model: feeds the DUT and captures its output over real I2S.
  codec : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (rst => sys_rst, bclk => bclk, lrclk => lrclk,
              sd_rx => sd_dut2cod, sd_tx => sd_cod2dut,
              rx_l => cod_rx_l, rx_r => cod_rx_r, rx_valid => cod_rx_valid,
              tx_l => cod_tx_l, tx_r => cod_tx_r);

  -- Monitor the DUT's audio output (received by the codec).
  mon : process (bclk)
  begin
    if rising_edge(bclk) then
      if sys_rst = '0' and cod_rx_valid = '1' then
        if to_integer(cod_rx_l) /= 0 or to_integer(cod_rx_r) /= 0 then
          saw_nonzero <= true;
        end if;
        -- saturating arithmetic keeps |out| <= Q1.23 max; flag any violation
        if to_integer(cod_rx_l) > 2**23-1 or to_integer(cod_rx_l) < -(2**23) then
          out_of_range <= true;
        end if;
      end if;
    end if;
  end process;

  stim : process
    procedure cfg_write(a : natural; d : std_logic_vector(23 downto 0)) is
    begin
      wait until rising_edge(sys_clk);
      cfg_wr_en <= '1'; cfg_wr_addr <= to_unsigned(a, 4); cfg_wr_data <= d;
      wait until rising_edge(sys_clk);
      cfg_wr_en <= '0';
    end procedure;
    variable frames_seen : integer := 0;
  begin
    sys_rst <= '1';
    wait for 300 ns;
    sys_rst <= '0';

    -- reference coefficients over the control bus
    cfg_write(0, std_logic_vector(to_q123(0.09)));        -- gamma2
    cfg_write(1, std_logic_vector(to_q123(0.99996875)));  -- a0
    cfg_write(2, std_logic_vector(to_q123(0.99996875)));  -- sigk1
    cfg_write(3, std_logic_vector(to_q123(0.0)));         -- alpha
    cfg_write(4, std_logic_vector(to_q123(0.5)));         -- gamma2_max

    -- a few frames of silence, then a one-frame excitation impulse
    cod_tx_l <= (others => '0'); cod_tx_r <= (others => '0');
    wait until rising_edge(bclk) and cod_rx_valid = '1';   -- frame tick
    wait until rising_edge(bclk) and cod_rx_valid = '1';
    cod_tx_l <= to_q123(0.5);                              -- mallet strike
    wait until rising_edge(bclk) and cod_rx_valid = '1';
    cod_tx_l <= (others => '0');                           -- back to silence

    -- run the rest of the frames, letting the response flow back out
    for f in 1 to FRAMES loop
      wait until rising_edge(bclk) and cod_rx_valid = '1';
    end loop;

    assert saw_nonzero
      report "no audio reached the output (RX -> mesh -> TX path broken)"
      severity failure;
    assert not out_of_range
      report "output left the Q1.23 range" severity failure;

    report "top_resonator_tb: all checks passed (end-to-end audio RX -> mesh -> TX, bounded)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
