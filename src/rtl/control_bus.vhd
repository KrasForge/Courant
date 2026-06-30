-------------------------------------------------------------------------------
-- control_bus.vhd  -  control / register bus for precomputed coefficients
--
-- A control-rate register file holding the precomputed coefficients and pickup
-- tap locations, distributed to the mesh (README §3 control bus, §4 precomputed
-- coefficients). The host computes a0 / sigk1 etc. off-node and writes them
-- here; the mesh never divides.
--
-- Register map (4-bit address, 24-bit data; coefficients are Q1.23):
--   0  gamma2     = gamma0^2 = (c*k/h)^2     base Courant number squared
--   1  a0         = 1/(1+sigma*k)            forward damping scale
--   2  sigk1      = 1 - sigma*k              backward damping coefficient
--   3  alpha      = chaos coupling           amplitude-dependent stiffening
--   4  gamma2_max = CFL-safe clamp ceiling   (< 1/2)
--   5  pick_lx    left  pickup column        (low COORD_W bits)
--   6  pick_ly    left  pickup row
--   7  pick_rx    right pickup column
--   8  pick_ry    right pickup row
--
-- Simple synchronous bus: a write port (wr_en/wr_addr/wr_data) and a registered
-- read-back port (rd_addr/rd_data). Coefficients and tap coordinates are driven
-- out continuously; the mesh samples them when it strobes (control-rate writes
-- are stable across the per-frame mesh step, same clock domain).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity control_bus is
  generic (
    COORD_W : positive := 6              -- pickup-coordinate width (0..63)
  );
  port (
    clk     : in  std_logic;
    rst     : in  std_logic;
    -- write port
    wr_en   : in  std_logic;
    wr_addr : in  unsigned(3 downto 0);
    wr_data : in  std_logic_vector(23 downto 0);
    -- registered read-back port
    rd_addr : in  unsigned(3 downto 0);
    rd_data : out std_logic_vector(23 downto 0);
    -- distributed outputs
    coeffs  : out coeffs_t;
    pick_lx : out unsigned(COORD_W-1 downto 0);
    pick_ly : out unsigned(COORD_W-1 downto 0);
    pick_rx : out unsigned(COORD_W-1 downto 0);
    pick_ry : out unsigned(COORD_W-1 downto 0)
  );
end entity control_bus;

architecture rtl of control_bus is

  constant NUM_REGS : natural := 9;
  type regfile_t is array (0 to NUM_REGS-1) of std_logic_vector(23 downto 0);

  -- Reset defaults: a safe linear operating point (alpha = 0, gamma2_max below
  -- the CFL limit), matching the reference-model defaults.
  constant DEFAULTS : regfile_t := (
    0 => std_logic_vector(to_q123(0.09)),         -- gamma2 (gamma0^2)
    1 => std_logic_vector(to_q123(0.99996875)),   -- a0
    2 => std_logic_vector(to_q123(0.99996875)),   -- sigk1
    3 => std_logic_vector(to_q123(0.0)),          -- alpha (linear)
    4 => std_logic_vector(to_q123(0.451)),        -- gamma2_max (issue #3)
    others => (others => '0'));                   -- pickup coords default 0

  signal regs : regfile_t := DEFAULTS;

begin

  -- continuous distribution
  coeffs.gamma2     <= signed(regs(0));
  coeffs.a0         <= signed(regs(1));
  coeffs.sigk1      <= signed(regs(2));
  coeffs.alpha      <= signed(regs(3));
  coeffs.gamma2_max <= signed(regs(4));
  pick_lx <= unsigned(regs(5)(COORD_W-1 downto 0));
  pick_ly <= unsigned(regs(6)(COORD_W-1 downto 0));
  pick_rx <= unsigned(regs(7)(COORD_W-1 downto 0));
  pick_ry <= unsigned(regs(8)(COORD_W-1 downto 0));

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        regs    <= DEFAULTS;
        rd_data <= (others => '0');
      else
        if wr_en = '1' and to_integer(wr_addr) < NUM_REGS then
          regs(to_integer(wr_addr)) <= wr_data;
        end if;
        if to_integer(rd_addr) < NUM_REGS then
          rd_data <= regs(to_integer(rd_addr));
        else
          rd_data <= (others => '0');
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
