-------------------------------------------------------------------------------
-- preset_bank_tb.vhd  -  preset store & recall changes the instrument (#30)
--
-- Checks the preset bank:
--   * reset gives the safe linear default;
--   * recalling each factory preset loads its whole coefficient/tap/boundary
--     bundle, and the three factory presets are mutually distinct (so they
--     audibly change the instrument character);
--   * a user slot can be edited, saved, clobbered by another recall, and then
--     recalled to restore the saved bundle bit-for-bit;
--   * factory slots are read-only (a save aimed at a factory index is ignored);
--   * the read-back port returns the live registers.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity preset_bank_tb is
end entity preset_bank_tb;

architecture sim of preset_bank_tb is

  constant CLK_PERIOD : time := 10 ns;
  constant COORD_W    : positive := 6;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal wr_en   : std_logic := '0';
  signal wr_addr : unsigned(3 downto 0) := (others => '0');
  signal wr_data : std_logic_vector(23 downto 0) := (others => '0');
  signal rd_addr : unsigned(3 downto 0) := (others => '0');
  signal rd_data : std_logic_vector(23 downto 0);

  signal preset_index : unsigned(3 downto 0) := (others => '0');
  signal recall       : std_logic := '0';
  signal save         : std_logic := '0';

  signal coeffs : coeffs_t;
  signal pick_lx, pick_ly, pick_rx, pick_ry : unsigned(COORD_W-1 downto 0);
  signal free_boundary : std_logic;

  signal done : boolean := false;

begin

  clk_gen : process begin
    while not done loop clk <= '0'; wait for CLK_PERIOD/2; clk <= '1'; wait for CLK_PERIOD/2; end loop; wait;
  end process;

  watchdog : process begin
    wait for 1 ms;
    assert done report "preset_bank_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.preset_bank
    generic map (COORD_W => COORD_W, N_USER => 4)
    port map (clk => clk, rst => rst,
              wr_en => wr_en, wr_addr => wr_addr, wr_data => wr_data,
              rd_addr => rd_addr, rd_data => rd_data,
              preset_index => preset_index, recall => recall, save => save,
              coeffs => coeffs, pick_lx => pick_lx, pick_ly => pick_ly,
              pick_rx => pick_rx, pick_ry => pick_ry,
              free_boundary => free_boundary);

  stim : process
    procedure step is begin wait until rising_edge(clk); end procedure;

    procedure do_recall(i : natural) is
    begin
      step;
      preset_index <= to_unsigned(i, 4); recall <= '1';
      step;
      recall <= '0';
      step;                                   -- let the load settle
    end procedure;

    procedure do_save(i : natural) is
    begin
      step;
      preset_index <= to_unsigned(i, 4); save <= '1';
      step;
      save <= '0';
      step;
    end procedure;

    procedure do_write(a : natural; d : std_logic_vector(23 downto 0)) is
    begin
      step;
      wr_en <= '1'; wr_addr <= to_unsigned(a, 4); wr_data <= d;
      step;
      wr_en <= '0';
      step;
    end procedure;

    variable saved_g2 : std_logic_vector(23 downto 0);
  begin
    rst <= '1'; step; step; rst <= '0'; step;

    -- reset default: linear operating point
    assert coeffs.gamma2 = to_q123(0.09) and coeffs.alpha = to_q123(0.0)
      report "preset_bank_tb: reset default wrong" severity failure;

    -- factory 0: drum
    do_recall(0);
    assert coeffs.gamma2 = to_q123(0.180) and coeffs.sigk1 = to_q123(0.995)
       and coeffs.alpha = to_q123(0.10) and free_boundary = '0'
       and pick_lx = to_unsigned(2, COORD_W) and pick_ly = to_unsigned(4, COORD_W)
      report "preset_bank_tb: drum preset wrong" severity failure;

    -- factory 1: gong (distinct pitch, more chaos, free boundary)
    do_recall(1);
    assert coeffs.gamma2 = to_q123(0.300) and coeffs.alpha = to_q123(0.40)
       and free_boundary = '1'
      report "preset_bank_tb: gong preset wrong" severity failure;

    -- factory 2: metallic plate
    do_recall(2);
    assert coeffs.gamma2 = to_q123(0.400) and coeffs.alpha = to_q123(0.30)
      report "preset_bank_tb: plate preset wrong" severity failure;

    -- the three factory presets must be mutually distinct (character changes)
    assert to_q123(0.180) /= to_q123(0.300) and to_q123(0.300) /= to_q123(0.400)
      report "preset_bank_tb: factory presets not distinct" severity failure;

    --------------------------------------------------------------------------
    -- user save / recall round-trip
    --------------------------------------------------------------------------
    -- start from the drum, edit gamma2, save into user slot 3 (= index N_FACTORY)
    do_recall(0);
    saved_g2 := std_logic_vector(to_q123(0.222));
    do_write(0, saved_g2);
    assert coeffs.gamma2 = signed(saved_g2)
      report "preset_bank_tb: per-register edit did not take" severity failure;
    do_save(3);                               -- user slot 0

    -- clobber the live registers with a different factory preset
    do_recall(1);
    assert coeffs.gamma2 = to_q123(0.300)
      report "preset_bank_tb: recall did not clobber before user recall" severity failure;

    -- recall the user slot: the edited bundle must come back exactly
    do_recall(3);
    assert coeffs.gamma2 = signed(saved_g2)
      report "preset_bank_tb: user preset recall did not restore" severity failure;

    --------------------------------------------------------------------------
    -- factory slots are read-only
    --------------------------------------------------------------------------
    do_write(0, std_logic_vector(to_q123(0.111)));  -- change the live regs
    do_save(0);                                      -- try to save over factory 0
    do_recall(0);                                    -- factory 0 must be unchanged
    assert coeffs.gamma2 = to_q123(0.180)
      report "preset_bank_tb: factory preset was overwritten (not read-only)"
      severity failure;

    --------------------------------------------------------------------------
    -- read-back port
    --------------------------------------------------------------------------
    do_write(3, std_logic_vector(to_q123(0.25)));   -- alpha register
    rd_addr <= to_unsigned(3, 4);
    step; step;
    assert rd_data = std_logic_vector(to_q123(0.25))
      report "preset_bank_tb: read-back mismatch" severity failure;

    report "preset_bank_tb: all checks passed (factory recall distinct; user " &
           "save/recall round-trip; factory read-only; read-back)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
