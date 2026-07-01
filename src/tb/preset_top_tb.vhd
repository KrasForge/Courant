-------------------------------------------------------------------------------
-- preset_top_tb.vhd  -  presets are recallable through top_resonator (#69)
--
-- Exercises the preset controls on the top-level interface: after swapping
-- control_bus for preset_bank inside top_resonator, a factory preset can be
-- recalled via preset_index/recall and observed through the register read-back
-- port. Only the control port is driven (the audio clocks are idle); the
-- preset_bank is in the system-clock domain, so recall/read-back work
-- regardless of the I2S side.
--
-- Checks: the reset default matches the old control_bus, recalling factory
-- presets loads their coefficients (readable at the register port), and a
-- register edit read-back still works.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity preset_top_tb is
end entity preset_top_tb;

architecture sim of preset_top_tb is

  constant CLK_PERIOD : time := 10 ns;

  signal sys_clk : std_logic := '0';
  signal sys_rst : std_logic := '1';

  signal cfg_wr_en   : std_logic := '0';
  signal cfg_wr_addr : unsigned(3 downto 0) := (others => '0');
  signal cfg_wr_data : std_logic_vector(23 downto 0) := (others => '0');
  signal cfg_rd_addr : unsigned(3 downto 0) := (others => '0');
  signal cfg_rd_data : std_logic_vector(23 downto 0);

  signal preset_index  : unsigned(3 downto 0) := (others => '0');
  signal preset_recall : std_logic := '0';
  signal preset_save   : std_logic := '0';

  signal done : boolean := false;

begin

  clk_gen : process begin
    while not done loop sys_clk <= '0'; wait for CLK_PERIOD/2; sys_clk <= '1'; wait for CLK_PERIOD/2; end loop; wait;
  end process;

  watchdog : process begin
    wait for 1 ms;
    assert done report "preset_top_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.top_resonator
    generic map (NX => 8, NY => 8, OS => 4)
    port map (sys_clk => sys_clk, sys_rst => sys_rst,
              bclk => '0', lrclk => '0', sd_rx => '0', sd_tx => open,
              cfg_wr_en => cfg_wr_en, cfg_wr_addr => cfg_wr_addr,
              cfg_wr_data => cfg_wr_data, cfg_rd_addr => cfg_rd_addr,
              cfg_rd_data => cfg_rd_data,
              preset_index => preset_index, preset_recall => preset_recall,
              preset_save => preset_save);

  stim : process
    procedure step is begin wait until rising_edge(sys_clk); end procedure;

    -- registered read-back: drive address, wait for the registered data
    procedure read_reg(a : natural; v : out integer) is
    begin
      cfg_rd_addr <= to_unsigned(a, 4);
      step; step;
      v := to_integer(signed(cfg_rd_data));
    end procedure;

    procedure recall(i : natural) is
    begin
      step; preset_index <= to_unsigned(i, 4); preset_recall <= '1';
      step; preset_recall <= '0';
      step;
    end procedure;

    variable g2, al : integer;
  begin
    sys_rst <= '1'; step; step; sys_rst <= '0'; step;

    -- reset default matches the old control_bus (gamma2 = 0.09, alpha = 0)
    read_reg(0, g2); read_reg(3, al);
    assert g2 = to_integer(to_q123(0.09)) and al = to_integer(to_q123(0.0))
      report "preset_top_tb: reset default coefficients wrong" severity failure;

    -- recall factory 1 (gong): gamma2 = 0.300, alpha = 0.40
    recall(1);
    read_reg(0, g2); read_reg(3, al);
    assert g2 = to_integer(to_q123(0.300)) and al = to_integer(to_q123(0.40))
      report "preset_top_tb: gong preset not recalled through the top" severity failure;

    -- recall factory 0 (drum): gamma2 = 0.180
    recall(0);
    read_reg(0, g2);
    assert g2 = to_integer(to_q123(0.180))
      report "preset_top_tb: drum preset not recalled through the top" severity failure;

    -- a register edit is still visible at the read-back port
    step; cfg_wr_en <= '1'; cfg_wr_addr <= to_unsigned(0, 4);
    cfg_wr_data <= std_logic_vector(to_q123(0.123));
    step; cfg_wr_en <= '0';
    read_reg(0, g2);
    assert g2 = to_integer(to_q123(0.123))
      report "preset_top_tb: register edit/read-back through the top failed" severity failure;

    report "preset_top_tb: all checks passed (presets recalled + registers " &
           "edited through the top-level control interface)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
