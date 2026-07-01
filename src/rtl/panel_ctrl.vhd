-------------------------------------------------------------------------------
-- panel_ctrl.vhd  -  front-panel controls -> engine (issue #78)
--
-- Wires the physical panel to the engine: three macro potentiometers set the
-- live coefficients, and a rotary encoder + its push-button select and recall
-- presets, all via the preset_bank register / preset interface (#30, #69).
--
--   pot_pitch  -> gamma2 (reg 0)         pitch / tension
--   pot_decay  -> sigk1 (reg 2) + a0 (reg 1)   decay time (a0 ~= sigk1 for the
--                                              small sigma*k a knob spans)
--   pot_timbre -> alpha (reg 3)          chaos coupling / timbre
--   encoder    -> preset_index (turn), button short = recall, long = save
--
-- Each pot is scaled from its ADC range into a per-register Q1.23 range and
-- written on change only (a dead-band rejects ADC LSB jitter), one register per
-- scan step, so the single-port register bus is never flooded. After a preset
-- recall the live registers hold the recalled values until a knob is actually
-- moved (its target then differs from the last panel write and takes over) -
-- simple "pickup" behaviour.
--
-- ADC pot samples are assumed synchronous to clk; the encoder and button are
-- brought in through two-flop synchronisers.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity panel_ctrl is
  generic (
    POT_W      : positive := 12;             -- ADC width
    N_PRESETS  : positive := 7;              -- selectable presets (3 factory + 4 user)
    DEADBAND   : natural  := 4096;           -- Q1.23 LSB dead-band on pot writes
    LONG_CYC   : positive := 50_000_000;     -- long-press threshold (~0.5 s @100 MHz)
    -- per-pot Q1.23 mapping ranges
    PITCH_LO   : real := 0.02;   PITCH_HI  : real := 0.44;   -- gamma2
    DECAY_LO   : real := 0.9950; DECAY_HI  : real := 0.99999;-- sigk1 / a0
    TIMBRE_LO  : real := 0.0;    TIMBRE_HI : real := 0.40    -- alpha
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    -- panel inputs
    pot_pitch  : in  unsigned(POT_W-1 downto 0);
    pot_decay  : in  unsigned(POT_W-1 downto 0);
    pot_timbre : in  unsigned(POT_W-1 downto 0);
    enc_a      : in  std_logic;
    enc_b      : in  std_logic;
    enc_btn    : in  std_logic;
    -- to preset_bank: register edit + preset control
    cfg_wr_en    : out std_logic;
    cfg_wr_addr  : out unsigned(3 downto 0);
    cfg_wr_data  : out std_logic_vector(23 downto 0);
    preset_index : out unsigned(3 downto 0);
    preset_recall: out std_logic;
    preset_save  : out std_logic
  );
end entity panel_ctrl;

architecture rtl of panel_ctrl is

  constant PITCH_LO_Q  : q123_t := to_q123(PITCH_LO);
  constant PITCH_SPAN  : q123_t := to_q123(PITCH_HI  - PITCH_LO);
  constant DECAY_LO_Q  : q123_t := to_q123(DECAY_LO);
  constant DECAY_SPAN  : q123_t := to_q123(DECAY_HI  - DECAY_LO);
  constant TIMBRE_LO_Q : q123_t := to_q123(TIMBRE_LO);
  constant TIMBRE_SPAN : q123_t := to_q123(TIMBRE_HI - TIMBRE_LO);

  -- q = lo + span * pot / 2^POT_W
  function scale_pot(pot : unsigned; lo, span : q123_t) return q123_t is
    variable p : signed(span'length + POT_W downto 0);
  begin
    p := span * signed('0' & pot);
    return sat_add(lo, resize(shift_right(p, POT_W), Q_BITS));
  end function;

  -- scan list: 4 register writes (addr + which pot maps to it)
  type addr_arr is array (0 to 3) of unsigned(3 downto 0);
  constant REG_ADDR : addr_arr := (x"0", x"2", x"1", x"3");   -- gamma2, sigk1, a0, alpha
  type q_arr is array (0 to 3) of q123_t;
  signal last : q_arr := (others => (others => '0'));
  signal sel  : integer range 0 to 3 := 0;

  -- encoder + button synchronisers
  signal a_s, b_s : std_logic_vector(1 downto 0) := (others => '0');
  signal a_d      : std_logic := '0';         -- synced-A delayed 1 cycle (edge det)
  signal btn_s    : std_logic_vector(1 downto 0) := (others => '0');
  signal idx           : unsigned(3 downto 0) := (others => '0');
  signal held          : integer range 0 to LONG_CYC := 0;
  signal saved         : std_logic := '0';

  function pot_for(s : integer; pp, pd, pt : unsigned) return q123_t is
  begin
    case s is
      when 0      => return scale_pot(pp, PITCH_LO_Q,  PITCH_SPAN);   -- gamma2
      when 1      => return scale_pot(pd, DECAY_LO_Q,  DECAY_SPAN);   -- sigk1
      when 2      => return scale_pot(pd, DECAY_LO_Q,  DECAY_SPAN);   -- a0 (= sigk1)
      when others => return scale_pot(pt, TIMBRE_LO_Q, TIMBRE_SPAN);  -- alpha
    end case;
  end function;

begin

  preset_index <= idx;

  process (clk)
    variable target : q123_t;
    variable diff   : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cfg_wr_en <= '0'; cfg_wr_addr <= (others => '0'); cfg_wr_data <= (others => '0');
        preset_recall <= '0'; preset_save <= '0';
        last <= (others => (others => '0'));
        sel  <= 0; idx <= (others => '0'); held <= 0; saved <= '0';
        a_s <= "00"; b_s <= "00"; a_d <= '0'; btn_s <= "00";
      else
        -- synchronise async panel inputs (2FF), plus a 1-cycle delay of synced A
        a_s   <= a_s(0)   & enc_a;
        b_s   <= b_s(0)   & enc_b;
        a_d   <= a_s(1);
        btn_s <= btn_s(0) & enc_btn;

        cfg_wr_en     <= '0';
        preset_recall <= '0';
        preset_save   <= '0';

        --------------------------------------------------------------------
        -- pot scan: write one register per cycle, on change only
        --------------------------------------------------------------------
        target := pot_for(sel, pot_pitch, pot_decay, pot_timbre);
        diff   := to_integer(target) - to_integer(last(sel));
        if diff > DEADBAND or diff < -DEADBAND then
          cfg_wr_en   <= '1';
          cfg_wr_addr <= REG_ADDR(sel);
          cfg_wr_data <= std_logic_vector(target);
          last(sel)   <= target;
        end if;
        if sel = 3 then sel <= 0; else sel <= sel + 1; end if;

        --------------------------------------------------------------------
        -- encoder: 1 step per rising edge of A, direction from B
        --------------------------------------------------------------------
        if a_s(1) = '1' and a_d = '0' then             -- A rising edge (1 cycle)
          if b_s(1) = '0' then
            if idx < N_PRESETS-1 then idx <= idx + 1; end if;
          else
            if idx > 0 then idx <= idx - 1; end if;
          end if;
        end if;

        --------------------------------------------------------------------
        -- button: short press = recall, long press = save
        --------------------------------------------------------------------
        if btn_s(1) = '1' then                          -- held
          if held = LONG_CYC then
            if saved = '0' then preset_save <= '1'; saved <= '1'; end if;
          else
            held <= held + 1;
          end if;
        else                                            -- released
          if held > 0 and saved = '0' then preset_recall <= '1'; end if;
          held  <= 0;
          saved <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
