-------------------------------------------------------------------------------
-- mesh.vhd  -  spatial / time-multiplexed selector
--
-- Picks the mesh architecture at synthesis time from the same RTL (README §3,
-- "Parallel vs. time-multiplexed"). The two implementations share an identical
-- port interface, so this is a thin if-generate wrapper:
--
--   TIME_MUX = false : grid_mesh      (one PE per node; lowest latency, O(N^2)
--                                      DSP - fully spatial)
--   TIME_MUX = true  : grid_mesh_tdm  (one PE folded over the grid; ~18 DSP
--                                      regardless of NX*NY, NX*NY clocks/step)
--
-- Both produce bit-identical Q1.23 output (verified in tdm_tb).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library work;
use work.fdtd_pkg.all;

entity mesh is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    FREE_BOUNDARY : boolean  := false;
    TIME_MUX      : boolean  := false;
    EXC_X   : natural := 8 / 2;
    EXC_Y   : natural := 8 / 2;
    PICK_LX : natural := 8 / 4;
    PICK_LY : natural := 8 / 2;
    PICK_RX : natural := (3 * 8) / 4;
    PICK_RY : natural := 8 / 2
  );
  port (
    clk    : in  std_logic;
    rst    : in  std_logic;
    strobe : in  std_logic;
    coeffs : in  coeffs_t;
    exc_in : in  q123_t;
    exc_en : in  std_logic;
    pick_l : out q123_t;
    pick_r : out q123_t;
    valid  : out std_logic
  );
end entity mesh;

architecture rtl of mesh is
begin

  spatial_g : if not TIME_MUX generate
    u_spatial : entity work.grid_mesh
      generic map (NX => NX, NY => NY, FREE_BOUNDARY => FREE_BOUNDARY,
                   EXC_X => EXC_X, EXC_Y => EXC_Y,
                   PICK_LX => PICK_LX, PICK_LY => PICK_LY,
                   PICK_RX => PICK_RX, PICK_RY => PICK_RY)
      port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
                exc_in => exc_in, exc_en => exc_en,
                pick_l => pick_l, pick_r => pick_r, valid => valid);
  end generate;

  tdm_g : if TIME_MUX generate
    u_tdm : entity work.grid_mesh_tdm
      generic map (NX => NX, NY => NY, FREE_BOUNDARY => FREE_BOUNDARY,
                   EXC_X => EXC_X, EXC_Y => EXC_Y,
                   PICK_LX => PICK_LX, PICK_LY => PICK_LY,
                   PICK_RX => PICK_RX, PICK_RY => PICK_RY)
      port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
                exc_in => exc_in, exc_en => exc_en,
                pick_l => pick_l, pick_r => pick_r, valid => valid);
  end generate;

end architecture rtl;
