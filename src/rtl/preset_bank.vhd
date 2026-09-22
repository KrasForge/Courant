-------------------------------------------------------------------------------
-- preset_bank.vhd  -  control/register bus with preset store & recall (issue #30)
--
-- A superset of control_bus (README §3 control bus, §4 coefficients): the same
-- live register file and distributed outputs, plus a bank of presets that bundle
-- a whole instrument's coefficients + tap positions + boundary mode so they can
-- be recalled in one operation (milestone M8).
--
-- Register / preset bundle layout (each word 24-bit; coefficients Q1.23):
--   0  gamma2     = gamma0^2 = (c*k/h)^2     pitch / tension
--   1  a0         = 1/(1+sigma*k)            forward damping scale
--   2  sigk1      = 1 - sigma*k              backward damping (decay time)
--   3  alpha      = chaos coupling           timbre (amplitude stiffening)
--   4  gamma2_max = CFL-safe clamp ceiling   (< 1/2)
--   5  low coord=pick_lx; bits15..8 RIM compliance; bits23..16 STIFFNESS
--   6  low coord=pick_ly; bits15..8 STRIKE SIZE; bits23..16 HARDNESS
--   7  low coord=pick_rx; bits15..8 STRIKE X
--   8  low coord=pick_ry; bits15..8 STRIKE Y
--   9  bit0 boundary; 3..1 MATERIAL; 6..4 CHARACTER/EXCITER;
--      10..7 signed ANISO; 12..11 MIDI/CV source mode;
--      16..15 L pick X frac; 18..17 L pick Y; 20..19 R X; 22..21 R Y
--  10  FX master/enables + drive + tone
--  11  chorus rate + depth + mix
--  12  delay time (samples) + mix
--  13  delay feedback + damping + ping-pong + POLISH macro (bits 6..0)
--  14  reverb decay + damping + mix
--  15  reverb size + diffusion + output trim
--
-- Presets are addressed in one index space:
--   0 .. N_FACTORY-1                    factory presets (ROM, read-only)
--   N_FACTORY .. N_FACTORY+N_USER-1     user slots (RAM: save + recall)
--
-- Operations (one-cycle strobes):
--   * per-register edit  : wr_en / wr_addr / wr_data          (as control_bus)
--   * recall preset      : recall  with preset_index -> live regs load
--   * save preset        : save    with preset_index -> live regs -> user slot
--
-- The live registers are exposed continuously. In the playable synth, TENSION,
-- DECAY, CHAOS, pickup taps and boundary mode are captured into each new voice;
-- standalone/legacy users can still consume the raw register outputs directly.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity preset_bank is
  generic (
    MUSICAL_MODE : boolean := false;
    NX : positive := 8; NY : positive := 8; OS : positive := 4;
    FS_HZ : positive := 48_000; RESET_FREE : boolean := false;
    COORD_W : positive := 6;             -- pickup-coordinate width
    N_USER  : positive := 4              -- writable user preset slots
  );
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    -- per-register edit port (same as control_bus)
    wr_en        : in  std_logic;
    wr_addr      : in  unsigned(3 downto 0);
    wr_data      : in  std_logic_vector(23 downto 0);
    -- registered read-back port
    rd_addr      : in  unsigned(3 downto 0);
    rd_data      : out std_logic_vector(23 downto 0);
    -- preset control
    preset_index : in  unsigned(3 downto 0);
    recall       : in  std_logic;        -- load preset_index -> live registers
    save         : in  std_logic;        -- store live registers -> user slot
    -- distributed outputs
    coeffs       : out coeffs_t;
    pick_lx      : out unsigned(COORD_W-1 downto 0);
    pick_ly      : out unsigned(COORD_W-1 downto 0);
    pick_rx      : out unsigned(COORD_W-1 downto 0);
    pick_ry      : out unsigned(COORD_W-1 downto 0);
    free_boundary: out std_logic;
    physical_ctrl: out std_logic_vector(23 downto 0);
    rim_ctrl, strike_size, strike_x_ctrl, strike_y_ctrl : out unsigned(7 downto 0);
    stiffness_ctrl, hardness_ctrl : out unsigned(7 downto 0);
    fx_ctrl0, fx_ctrl1, fx_ctrl2 : out std_logic_vector(23 downto 0);
    fx_ctrl3, fx_ctrl4, fx_ctrl5 : out std_logic_vector(23 downto 0)
  );
end entity preset_bank;

architecture rtl of preset_bank is

  constant NUM_REGS  : natural := 16;
  constant N_FACTORY : natural := 3;

  type bundle_t is array (0 to NUM_REGS-1) of std_logic_vector(23 downto 0);
  type bank_t   is array (natural range <>) of bundle_t;

  -- build a preset bundle from physical coefficients + tap coordinates
  function mk(g2, a0, s1, al, gm : real;
             lx, ly, rx, ry : natural; free : natural) return bundle_t is
    variable b : bundle_t;
  begin
    b(0) := std_logic_vector(to_q123(g2));
    b(1) := std_logic_vector(to_q123(a0));
    b(2) := std_logic_vector(to_q123(s1));
    b(3) := std_logic_vector(to_q123(al));
    b(4) := std_logic_vector(to_q123(gm));
    b(5) := std_logic_vector(to_unsigned(lx, 24));
    b(6) := std_logic_vector(to_unsigned(ly, 24));
    b(7) := std_logic_vector(to_unsigned(rx, 24));
    b(8) := std_logic_vector(to_unsigned(ry, 24));
    b(9) := std_logic_vector(to_unsigned(free, 24));
    -- FX reset/preset defaults: the musical chain is active out of reset.
    -- POLISH=64 gives a medium mastering curve without adding a panel control.
    b(10) := x"FC6200"; -- master+FX enabled; DRIVE=24, TONE=128 (neutral)
    b(11) := x"306040"; -- chorus rate=48, depth=96, mix=64
    b(12) := x"2EE040"; -- delay=12000 samples (250 ms), mix=64
    b(13) := x"6E50C0"; -- feedback=110, damping=80, ping-pong, POLISH=64
    b(14) := x"D26446"; -- reverb decay=210, damping=100, mix=70
    b(15) := x"B496FF"; -- size=180, diffusion=150, trim=unity
    return b;
  end function;

  -- Factory presets (see docs/presets.md for the physical rationale). Damping
  -- pairs are consistent: a0 = 1/(1+x), sigk1 = 1-x with x = sigma*k.
  --                   gamma2  a0          sigk1       alpha  g2max  Lx Ly Rx Ry free
  constant LEGACY_FACTORY : bank_t(0 to N_FACTORY-1) := (
    0 => mk(0.180, 0.995025, 0.995000, 0.10, 0.451,  2, 4, 6, 4, 0),  -- drum
    1 => mk(0.300, 0.999990, 0.999990, 0.40, 0.451,  1, 6, 6, 1, 1),  -- gong
    2 => mk(0.400, 0.999800, 0.999800, 0.30, 0.451,  3, 3, 5, 5, 1)); -- metallic plate

  -- The musical top uses normalized tension and damping at its actual step rate.
  function select_factory return bank_t is
    variable b: bank_t(0 to N_FACTORY-1) := LEGACY_FACTORY;
    variable x: real;
  begin
    if MUSICAL_MODE then
      x := 18.0/real(FS_HZ*OS);
      b(0) := mk(0.25,1.0/(1.0+x),1.0-x,0.0,0.451,NX/4,NY/2,3*NX/4,NY/2,0);
      b(0)(9)(3 downto 1):="001"; -- membrane MATERIAL
      b(0)(5)(15 downto 8):=x"00"; -- fixed rim
      b(0)(7)(15 downto 8):=std_logic_vector(to_unsigned(32*(NX/3),8));
      b(0)(8)(15 downto 8):=std_logic_vector(to_unsigned(32*(NY/3),8));
      x := 2.0/real(FS_HZ*OS);
      if NX >= NY then
        b(1) := mk(0.25,1.0/(1.0+x),1.0-x,0.0,0.451,1,NY/3,1,2*NY/3,1);
      else
        b(1) := mk(0.25,1.0/(1.0+x),1.0-x,0.0,0.451,NX/3,1,2*NX/3,1,1);
      end if;
      b(1)(9)(3 downto 1):="011"; -- metal MATERIAL for gong
      b(1)(5)(15 downto 8):=x"FF"; -- compliant/free rim
      b(1)(7)(15 downto 8):=std_logic_vector(to_unsigned(32*(NX/3),8));
      b(1)(8)(15 downto 8):=std_logic_vector(to_unsigned(32*(NY/3),8));
      x := 5.0/real(FS_HZ*OS);
      b(2) := mk(0.25,1.0/(1.0+x),1.0-x,0.02,0.451,NX/3,NY/3,2*NX/3,2*NY/3,0);
      b(2)(9)(3 downto 1):="011"; -- metal MATERIAL for plate
      b(2)(5)(15 downto 8):=x"00";
      b(2)(7)(15 downto 8):=std_logic_vector(to_unsigned(32*(NX/3),8));
      b(2)(8)(15 downto 8):=std_logic_vector(to_unsigned(32*(NY/3),8));
    end if;
    return b;
  end;
  constant FACTORY: bank_t(0 to N_FACTORY-1) := select_factory;
  -- Reset default: the safe linear operating point (matches control_bus).
  constant LEGACY_DEFAULT : bundle_t := mk(0.09, 0.99996875, 0.99996875, 0.0, 0.451,
                                    2, 4, 6, 4, 0);

  function select_default return bundle_t is
    variable b: bundle_t := LEGACY_DEFAULT;
  begin
    if MUSICAL_MODE then
      b := mk(0.25,1.0/(1.0+5.0/real(FS_HZ*OS)),1.0-5.0/real(FS_HZ*OS),
              0.0,0.451,NX/4,NY/2,3*NX/4,NY/2,0);
      b(7)(15 downto 8):=std_logic_vector(to_unsigned(32*(NX/3),8));
      b(8)(15 downto 8):=std_logic_vector(to_unsigned(32*(NY/3),8));
      if RESET_FREE then b(9)(0) := '1'; b(5)(15 downto 8):=x"FF"; end if;
    end if;
    return b;
  end;
  constant DEF_PRESET: bundle_t := select_default;
  signal regs : bundle_t := DEF_PRESET;              -- live registers
  signal user : bank_t(0 to N_USER-1) := (others => DEF_PRESET);

begin
  assert COORD_W<=8 report "preset_bank: upper bytes of regs 5..8 are reserved for physical controls" severity failure;

  -- continuous distribution to the mesh
  coeffs.gamma2     <= signed(regs(0));
  coeffs.a0         <= signed(regs(1));
  coeffs.sigk1      <= signed(regs(2));
  coeffs.alpha      <= signed(regs(3));
  coeffs.gamma2_max <= signed(regs(4));
  pick_lx <= unsigned(regs(5)(COORD_W-1 downto 0));
  pick_ly <= unsigned(regs(6)(COORD_W-1 downto 0));
  pick_rx <= unsigned(regs(7)(COORD_W-1 downto 0));
  pick_ry <= unsigned(regs(8)(COORD_W-1 downto 0));
  free_boundary <= regs(9)(0);
  physical_ctrl <= regs(9);
  rim_ctrl<=unsigned(regs(5)(15 downto 8));
  stiffness_ctrl<=unsigned(regs(5)(23 downto 16));
  strike_size<=unsigned(regs(6)(15 downto 8));
  hardness_ctrl<=unsigned(regs(6)(23 downto 16));
  strike_x_ctrl<=unsigned(regs(7)(15 downto 8));
  strike_y_ctrl<=unsigned(regs(8)(15 downto 8));
  fx_ctrl0 <= regs(10); fx_ctrl1 <= regs(11); fx_ctrl2 <= regs(12);
  fx_ctrl3 <= regs(13); fx_ctrl4 <= regs(14); fx_ctrl5 <= regs(15);

  process (clk)
    variable idx : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        regs    <= DEF_PRESET;
        user    <= (others => DEF_PRESET);
        rd_data <= (others => '0');
      else
        idx := to_integer(preset_index);

        -- recall takes priority: load the whole bundle in one cycle
        if recall = '1' then
          if idx < N_FACTORY then
            regs <= FACTORY(idx);
          elsif idx < N_FACTORY + N_USER then
            regs <= user(idx - N_FACTORY);
          end if;
        elsif wr_en = '1' and to_integer(wr_addr) < NUM_REGS then
          regs(to_integer(wr_addr)) <= wr_data;
        end if;

        -- save the live registers into a user slot (factory slots are read-only)
        if save = '1' and idx >= N_FACTORY and idx < N_FACTORY + N_USER then
          user(idx - N_FACTORY) <= regs;
        end if;

        -- registered read-back of the live register file
        if to_integer(rd_addr) < NUM_REGS then
          rd_data <= regs(to_integer(rd_addr));
        else
          rd_data <= (others => '0');
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
