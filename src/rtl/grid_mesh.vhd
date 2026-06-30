-------------------------------------------------------------------------------
-- grid_mesh.vhd  -  parameterisable NX x NY structural mesh of node_element PEs
--
-- The "Parallel Node Mesh" of README §3: one node_element per grid point, wired
-- to its N/S/E/W neighbours, with the sample strobe and control coefficients
-- broadcast to every node. Mesh dimensions are generics so the same RTL builds
-- at any size (8x8, 16x16, 32x32, ...).
--
-- Boundaries (FREE_BOUNDARY generic):
--   false : fixed   (Dirichlet u=0) - off-grid neighbours read 0.
--   true  : free    (Neumann)       - off-grid neighbour mirrors the inward
--           neighbour, matching the reference model's reflect convention
--           (model/Mesh2D.m / QMesh2D.m). Requires NX, NY >= 2.
--
-- Excitation ("mallet"): when exc_en = '1', exc_in is injected as additive
-- forcing at the single excitation node (EXC_X, EXC_Y) for that sample.
-- Pickups: two taps (pick_l / pick_r) at configurable coordinates, matching
-- the reference stereo pickups (default NX/4 and 3*NX/4 on the centre row).
--
-- All nodes share one strobe and have identical 3-clock latency, so the mesh
-- advances in lockstep; `valid` pulses when the step has committed.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity grid_mesh is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    FREE_BOUNDARY : boolean  := false;
    -- excitation node (default: centre)
    EXC_X   : natural := NX / 2;
    EXC_Y   : natural := NY / 2;
    -- stereo pickup taps (default: centre row, quarter / three-quarter columns)
    PICK_LX : natural := NX / 4;
    PICK_LY : natural := NY / 2;
    PICK_RX : natural := (3 * NX) / 4;
    PICK_RY : natural := NY / 2
  );
  port (
    clk    : in  std_logic;
    rst    : in  std_logic;            -- synchronous, resets the whole mesh to rest
    strobe : in  std_logic;            -- advance one mesh time-step
    coeffs : in  coeffs_t;             -- broadcast gamma2 / a0 / sigk1
    exc_in : in  q123_t;               -- excitation sample ("mallet")
    exc_en : in  std_logic;            -- inject exc_in at (EXC_X,EXC_Y) this step
    pick_l : out q123_t;               -- left  pickup tap
    pick_r : out q123_t;               -- right pickup tap
    valid  : out std_logic             -- pulses when a mesh step has committed
  );
end entity grid_mesh;

architecture structural of grid_mesh is

  type grid_t   is array (0 to NY-1, 0 to NX-1) of q123_t;
  type nbgrid_t is array (0 to NY-1, 0 to NX-1) of neighbours_t;

  signal u   : grid_t;       -- each node's current displacement (u_out)
  signal nbw : nbgrid_t;     -- assembled N/S/E/W neighbour inputs per node

  signal exc_node : q123_t;                            -- forcing for the exc node
  signal vsr      : std_logic_vector(2 downto 0) := (others => '0');

begin

  -- Free (reflect) boundaries need an inward neighbour to mirror.
  assert not FREE_BOUNDARY or (NX >= 2 and NY >= 2)
    report "grid_mesh: FREE_BOUNDARY requires NX >= 2 and NY >= 2"
    severity failure;

  exc_node <= exc_in when exc_en = '1' else (others => '0');

  pick_l <= u(PICK_LY, PICK_LX);
  pick_r <= u(PICK_RY, PICK_RX);

  -- Mesh-level valid: mirrors node_element's 3-clock strobe-to-commit latency.
  valid <= vsr(2);
  vld : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        vsr <= (others => '0');
      else
        vsr <= vsr(1 downto 0) & strobe;
      end if;
    end if;
  end process;

  -- Structural fabric: one PE per node, neighbour wiring generated per edge.
  gen_rows : for i in 0 to NY-1 generate
  begin
    gen_cols : for j in 0 to NX-1 generate
    begin

      -- North (i-1)
      n_int : if i > 0 generate nbw(i, j).n <= u(i-1, j); end generate;
      n_bnd : if i = 0 generate
        n_free : if FREE_BOUNDARY generate nbw(i, j).n <= u(i+1, j); end generate;
        n_fix  : if not FREE_BOUNDARY generate nbw(i, j).n <= Q123_ZERO; end generate;
      end generate;

      -- South (i+1)
      s_int : if i < NY-1 generate nbw(i, j).s <= u(i+1, j); end generate;
      s_bnd : if i = NY-1 generate
        s_free : if FREE_BOUNDARY generate nbw(i, j).s <= u(i-1, j); end generate;
        s_fix  : if not FREE_BOUNDARY generate nbw(i, j).s <= Q123_ZERO; end generate;
      end generate;

      -- East (j+1)
      e_int : if j < NX-1 generate nbw(i, j).e <= u(i, j+1); end generate;
      e_bnd : if j = NX-1 generate
        e_free : if FREE_BOUNDARY generate nbw(i, j).e <= u(i, j-1); end generate;
        e_fix  : if not FREE_BOUNDARY generate nbw(i, j).e <= Q123_ZERO; end generate;
      end generate;

      -- West (j-1)
      w_int : if j > 0 generate nbw(i, j).w <= u(i, j-1); end generate;
      w_bnd : if j = 0 generate
        w_free : if FREE_BOUNDARY generate nbw(i, j).w <= u(i, j+1); end generate;
        w_fix  : if not FREE_BOUNDARY generate nbw(i, j).w <= Q123_ZERO; end generate;
      end generate;

      -- Processing element. Only the excitation node drives `exc`; every other
      -- node leaves it at its default (rest), so the mesh is linear elsewhere.
      exc_node_g : if (i = EXC_Y) and (j = EXC_X) generate
        pe : entity work.node_element
          port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
                    nb => nbw(i, j), exc => exc_node, u_out => u(i, j), valid => open);
      end generate;
      plain_node_g : if not ((i = EXC_Y) and (j = EXC_X)) generate
        pe : entity work.node_element
          port map (clk => clk, rst => rst, strobe => strobe, coeffs => coeffs,
                    nb => nbw(i, j), u_out => u(i, j), valid => open);
      end generate;

    end generate;
  end generate;

end architecture structural;
