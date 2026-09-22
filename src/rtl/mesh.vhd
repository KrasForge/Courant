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
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;
use work.physical_pkg.all;

entity mesh is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    FREE_BOUNDARY : boolean  := false;
    BALANCED_FREE_STRIKE : boolean := false;
    HF_DAMPING : boolean := false;
    TIME_MUX      : boolean  := false;
    EXC_X   : natural := NX / 2;
    EXC_Y   : natural := NY / 2;
    PICK_LX : natural := NX / 4;
    PICK_LY : natural := NY / 2;
    PICK_RX : natural := (3 * NX) / 4;
    PICK_RY : natural := NY / 2
  );
  port (
    free_mode : in boolean := FREE_BOUNDARY;
    tap_lx : in natural range 0 to NX-1 := PICK_LX;
    tap_ly : in natural range 0 to NY-1 := PICK_LY;
    tap_rx : in natural range 0 to NX-1 := PICK_RX;
    tap_ry : in natural range 0 to NY-1 := PICK_RY;
    tap_lfx,tap_lfy,tap_rfx,tap_rfy : in frac2_t := (others=>'0');
    material : in material_t := (others=>'0');
    anisotropy : in aniso_t := (others=>'0');
    stiffness_ctrl : in unsigned(7 downto 0) := (others=>'0');
    hardness_ctrl : in unsigned(7 downto 0) := (others=>'0');
    mallet_enable : in std_logic := '0';
    rim_ctrl,strike_size : in unsigned(7 downto 0) := (others=>'0');
    strike_x : in natural range 0 to NX-1 := EXC_X;
    strike_y : in natural range 0 to NY-1 := EXC_Y;
    strike_fx,strike_fy : in frac2_t := (others=>'0');
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
      generic map (NX => NX, NY => NY, FREE_BOUNDARY => FREE_BOUNDARY, BALANCED_FREE_STRIKE => BALANCED_FREE_STRIKE,
                   EXC_X => EXC_X, EXC_Y => EXC_Y,
                   PICK_LX => PICK_LX, PICK_LY => PICK_LY,
                   PICK_RX => PICK_RX, PICK_RY => PICK_RY)
      port map (free_mode => free_mode, tap_lx => tap_lx, tap_ly => tap_ly,
                tap_rx => tap_rx, tap_ry => tap_ry,
                tap_lfx=>tap_lfx,tap_lfy=>tap_lfy,tap_rfx=>tap_rfx,tap_rfy=>tap_rfy,
                material=>material,anisotropy=>anisotropy,stiffness_ctrl=>stiffness_ctrl,
                hardness_ctrl=>hardness_ctrl,mallet_enable=>mallet_enable,
                rim_ctrl=>rim_ctrl,strike_size=>strike_size,
                strike_x=>strike_x,strike_y=>strike_y,strike_fx=>strike_fx,strike_fy=>strike_fy,
                clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
                exc_in => exc_in, exc_en => exc_en,
                pick_l => pick_l, pick_r => pick_r, valid => valid);
  end generate;

  tdm_g : if TIME_MUX generate
    u_tdm : entity work.grid_mesh_tdm
      generic map (NX => NX, NY => NY, FREE_BOUNDARY => FREE_BOUNDARY, BALANCED_FREE_STRIKE => BALANCED_FREE_STRIKE,
                   EXC_X => EXC_X, EXC_Y => EXC_Y,
                   PICK_LX => PICK_LX, PICK_LY => PICK_LY,
                   PICK_RX => PICK_RX, PICK_RY => PICK_RY)
      port map (free_mode => free_mode, tap_lx => tap_lx, tap_ly => tap_ly,
                tap_rx => tap_rx, tap_ry => tap_ry,
                tap_lfx=>tap_lfx,tap_lfy=>tap_lfy,tap_rfx=>tap_rfx,tap_rfy=>tap_rfy,
                material=>material,anisotropy=>anisotropy,stiffness_ctrl=>stiffness_ctrl,
                hardness_ctrl=>hardness_ctrl,mallet_enable=>mallet_enable,
                rim_ctrl=>rim_ctrl,strike_size=>strike_size,
                strike_x=>strike_x,strike_y=>strike_y,strike_fx=>strike_fx,strike_fy=>strike_fy,
                clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
                exc_in => exc_in, exc_en => exc_en,
                pick_l => pick_l, pick_r => pick_r, valid => valid);
  end generate;

end architecture rtl;
