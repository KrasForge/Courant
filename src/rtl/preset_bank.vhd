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
--   5  pick_lx    left  pickup column
--   6  pick_ly    left  pickup row
--   7  pick_rx    right pickup column
--   8  pick_ry    right pickup row
--   9  boundary   bit 0: 0 = fixed (Dirichlet), 1 = free (Neumann)
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
-- The live registers drive the mesh continuously (sampled when it strobes).
-- boundary is exposed as free_boundary for observability; the mesh's boundary is
-- still a build-time generic today, so recall of the boundary bit is advisory
-- (see docs/presets.md).
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
    free_boundary: out std_logic
  );
end entity preset_bank;

architecture rtl of preset_bank is

  constant NUM_REGS  : natural := 10;
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
    return b;
  end function;

  -- Factory presets (see docs/presets.md for the physical rationale). Damping
  -- pairs are consistent: a0 = 1/(1+x), sigk1 = 1-x with x = sigma*k.
  --                   gamma2  a0          sigk1       alpha  g2max  Lx Ly Rx Ry free
  constant FACTORY : bank_t(0 to N_FACTORY-1) := (
    0 => mk(0.180, 0.995025, 0.995000, 0.10, 0.451,  2, 4, 6, 4, 0),  -- drum
    1 => mk(0.300, 0.999990, 0.999990, 0.40, 0.451,  1, 6, 6, 1, 1),  -- gong
    2 => mk(0.400, 0.999800, 0.999800, 0.30, 0.451,  3, 3, 5, 5, 1)); -- metallic plate

  -- Reset default: the safe linear operating point (matches control_bus).
  constant DEF_PRESET : bundle_t := mk(0.09, 0.99996875, 0.99996875, 0.0, 0.451,
                                    2, 4, 6, 4, 0);

  signal regs : bundle_t := DEF_PRESET;              -- live registers
  signal user : bank_t(0 to N_USER-1) := (others => DEF_PRESET);

begin

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
