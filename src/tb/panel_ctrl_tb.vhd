-------------------------------------------------------------------------------
-- panel_ctrl_tb.vhd  -  panel knobs/encoder drive the engine (issue #78)
--
-- Wires panel_ctrl into a real preset_bank and checks that the front panel
-- reaches the engine coefficients:
--   * moving a pot writes the mapped coefficient (pitch->gamma2, timbre->alpha,
--     decay->sigk1 & a0) and the change shows on preset_bank.coeffs;
--   * stable pots produce no further writes (dead-band);
--   * the encoder steps preset_index, and a short button press recalls the
--     selected preset (coeffs load the factory values); a long press emits save.
--
-- The long-press threshold is shrunk via a generic for a fast simulation.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity panel_ctrl_tb is
end entity panel_ctrl_tb;

architecture sim of panel_ctrl_tb is

  constant CLK_PERIOD : time := 10 ns;
  constant POT_W      : positive := 12;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal pot_pitch, pot_decay, pot_timbre : unsigned(POT_W-1 downto 0) := (others => '0');
  signal enc_a, enc_b, enc_btn : std_logic := '0';

  signal cfg_wr_en   : std_logic;
  signal cfg_wr_addr : unsigned(3 downto 0);
  signal cfg_wr_data : std_logic_vector(23 downto 0);
  signal p_index     : unsigned(3 downto 0);
  signal p_recall    : std_logic;
  signal p_save      : std_logic;

  signal coeffs : coeffs_t;

  signal done : boolean := false;
  signal recall_seen, save_seen : integer := 0;

begin

  clk_gen : process begin
    while not done loop clk <= '0'; wait for CLK_PERIOD/2; clk <= '1'; wait for CLK_PERIOD/2; end loop; wait;
  end process;

  watchdog : process begin
    wait for 2 ms;
    assert done report "panel_ctrl_tb: timeout" severity failure;
    wait;
  end process;

  dut : entity work.panel_ctrl
    generic map (POT_W => POT_W, N_PRESETS => 7, DEADBAND => 4096, LONG_CYC => 200)
    port map (clk => clk, rst => rst,
              pot_pitch => pot_pitch, pot_decay => pot_decay, pot_timbre => pot_timbre,
              enc_a => enc_a, enc_b => enc_b, enc_btn => enc_btn,
              cfg_wr_en => cfg_wr_en, cfg_wr_addr => cfg_wr_addr, cfg_wr_data => cfg_wr_data,
              preset_index => p_index, preset_recall => p_recall, preset_save => p_save);

  bank : entity work.preset_bank
    port map (clk => clk, rst => rst,
              wr_en => cfg_wr_en, wr_addr => cfg_wr_addr, wr_data => cfg_wr_data,
              rd_addr => (others => '0'), rd_data => open,
              preset_index => p_index, recall => p_recall, save => p_save,
              coeffs => coeffs,
              pick_lx => open, pick_ly => open, pick_rx => open, pick_ry => open,
              free_boundary => open);

  -- latch the recall/save pulses
  mon : process (clk) begin
    if rising_edge(clk) then
      if p_recall = '1' then recall_seen <= recall_seen + 1; end if;
      if p_save   = '1' then save_seen   <= save_seen + 1;   end if;
    end if;
  end process;

  stim : process
    procedure step is begin wait until rising_edge(clk); end procedure;
    procedure settle is begin for i in 0 to 15 loop step; end loop; end procedure;

    -- one encoder detent: rising edge of A with B held for direction
    procedure enc_step(up : boolean) is
    begin
      enc_b <= '0' when up else '1';
      step;
      enc_a <= '1'; for i in 0 to 5 loop step; end loop;   -- A rising (synced)
      enc_a <= '0'; for i in 0 to 5 loop step; end loop;
    end procedure;

    variable g_lo, g_mid, al_hi, sk_dec : integer;
  begin
    rst <= '1'; for i in 0 to 9 loop step; end loop; rst <= '0';
    settle;                                    -- startup writes (pots at 0) settle

    -- pots at 0 -> the LO end of each range
    g_lo := to_integer(coeffs.gamma2);
    assert g_lo = to_integer(to_q123(0.02))
      report "panel_ctrl_tb: pitch pot=0 did not map to gamma2 LO" severity failure;

    --------------------------------------------------------------------------
    -- 1. move pitch pot -> gamma2 rises to the scaled value
    --------------------------------------------------------------------------
    pot_pitch <= to_unsigned(2048, POT_W);     -- half scale -> ~0.23
    settle;
    g_mid := to_integer(coeffs.gamma2);
    assert g_mid > g_lo and abs(g_mid - to_integer(to_q123(0.23))) < to_integer(to_q123(0.01))
      report "panel_ctrl_tb: pitch pot did not scale gamma2 (" & integer'image(g_mid) & ")"
      severity failure;

    --------------------------------------------------------------------------
    -- 2. timbre pot -> alpha ; decay pot -> sigk1 (and a0)
    --------------------------------------------------------------------------
    pot_timbre <= to_unsigned(4095, POT_W);    -- full -> ~ALPHA_HI
    pot_decay  <= to_unsigned(4095, POT_W);    -- full -> ~DECAY_HI
    settle;
    al_hi  := to_integer(coeffs.alpha);
    sk_dec := to_integer(coeffs.sigk1);
    assert al_hi > to_integer(to_q123(0.3))
      report "panel_ctrl_tb: timbre pot did not raise alpha" severity failure;
    assert sk_dec > to_integer(to_q123(0.999)) and coeffs.a0 = coeffs.sigk1
      report "panel_ctrl_tb: decay pot did not set sigk1/a0" severity failure;

    --------------------------------------------------------------------------
    -- 3. stable pots -> no more writes
    --------------------------------------------------------------------------
    assert cfg_wr_en = '0' report "startup transient" severity note;  -- informational
    for i in 0 to 40 loop
      step;
      assert cfg_wr_en = '0'
        report "panel_ctrl_tb: writing with stable pots (dead-band failed)" severity failure;
    end loop;

    --------------------------------------------------------------------------
    -- 4. encoder steps preset_index
    --------------------------------------------------------------------------
    enc_step(true);                            -- -> 1
    assert p_index = to_unsigned(1, 4)
      report "panel_ctrl_tb: encoder up did not step preset_index" severity failure;

    --------------------------------------------------------------------------
    -- 5. short button press -> recall the selected preset (gong = index 1)
    --------------------------------------------------------------------------
    enc_btn <= '1'; for i in 0 to 20 loop step; end loop;   -- < LONG_CYC (200)
    enc_btn <= '0'; settle;
    assert recall_seen = 1 and save_seen = 0
      report "panel_ctrl_tb: short press did not recall" severity failure;
    assert coeffs.gamma2 = to_q123(0.300)
      report "panel_ctrl_tb: recall did not load the gong preset" severity failure;

    --------------------------------------------------------------------------
    -- 6. long button press -> save
    --------------------------------------------------------------------------
    enc_step(true); enc_step(true);            -- move to a user slot (index 3)
    enc_btn <= '1'; for i in 0 to 260 loop step; end loop;  -- > LONG_CYC
    enc_btn <= '0'; settle;
    assert save_seen = 1 and recall_seen = 1
      report "panel_ctrl_tb: long press did not save (or double-recalled)" severity failure;

    report "panel_ctrl_tb: all checks passed (pots -> coeffs; dead-band; encoder " &
           "-> preset_index; short=recall, long=save)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
