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
use work.physical_pkg.all;

entity grid_mesh is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    FREE_BOUNDARY : boolean  := false;
    BALANCED_FREE_STRIKE : boolean := false;
    HF_DAMPING : boolean := false;
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

  function mirror_x return natural is
  begin if NX >= NY then return NX-1-EXC_X; else return EXC_X; end if; end;
  function mirror_y return natural is
  begin if NX >= NY then return EXC_Y; else return NY-1-EXC_Y; end if; end;
  type grid_t   is array (0 to NY-1, 0 to NX-1) of q123_t;
  type nbgrid_t is array (0 to NY-1, 0 to NX-1) of neighbours_t;
  type bgrid_t  is array (0 to NY-1, 0 to NX-1) of acc_t;

  signal u   : grid_t := (others=>(others=>Q123_ZERO)); -- current displacement
  signal nbw : nbgrid_t;     -- assembled N/S/E/W neighbour inputs per node
  signal biharm_g : bgrid_t := (others=>(others=>(others=>'0')));

  -- Sample the second-ring/diagonal stencil with the same boundary semantics
  -- as the legacy first ring. Fixed edges zero-pad; free/compliant edges mirror
  -- the inward sample and apply the RIM reflection factor once per crossed axis.
  impure function sample_grid(y,x:integer; fm:boolean; rim:unsigned(7 downto 0))
    return q123_t is
    variable yy,xx:integer; variable v:q123_t;
    variable cross_y,cross_x:boolean:=false;
  begin
    yy:=y; xx:=x;
    if yy<0 then yy:=-yy; cross_y:=true;
    elsif yy>=NY then yy:=2*(NY-1)-yy; cross_y:=true; end if;
    if xx<0 then xx:=-xx; cross_x:=true;
    elsif xx>=NX then xx:=2*(NX-1)-xx; cross_x:=true; end if;
    if yy<0 then yy:=0; elsif yy>=NY then yy:=NY-1; end if;
    if xx<0 then xx:=0; elsif xx>=NX then xx:=NX-1; end if;
    v:=u(yy,xx);
    if cross_y then v:=rim_neighbor(v,fm,rim); end if;
    if cross_x then v:=rim_neighbor(v,fm,rim); end if;
    return v;
  end;

  signal exc_node : q123_t;
  signal contact_u,mallet_force : q123_t := Q123_ZERO;
  signal mallet_contact,mallet_active : std_logic;
  signal vsr      : std_logic_vector(3 downto 0) := (others => '0');

begin

  -- Free (reflect) boundaries need an inward neighbour to mirror.
  assert not FREE_BOUNDARY or (NX >= 2 and NY >= 2)
    report "grid_mesh: FREE_BOUNDARY requires NX >= 2 and NY >= 2"
    severity failure;

  -- Physical contact reads the actual quarter-cell strike position.
  contact_interp : process(all)
    variable x1,y1:natural;
  begin
    if strike_x<NX-1 then x1:=strike_x+1; else x1:=strike_x; end if;
    if strike_y<NY-1 then y1:=strike_y+1; else y1:=strike_y; end if;
    contact_u<=bilerp_quarter(u(strike_y,strike_x),u(strike_y,x1),
                              u(y1,strike_x),u(y1,x1),strike_fx,strike_fy);
  end process;

  mallet : entity work.physical_mallet
    port map(clk=>clk,rst=>rst,enable=>mallet_enable,step=>strobe,
             trigger=>exc_en,strike_velocity=>exc_in,hardness=>hardness_ctrl,
             surface_u=>contact_u,force_out=>mallet_force,
             contact=>mallet_contact,active=>mallet_active,
             hammer_x=>open,hammer_v=>open);

  exc_node <= mallet_force when mallet_enable='1' else
              exc_in when exc_en='1' else Q123_ZERO;

  -- Wider 13-point plate operator. The first axial ring comes from the exact
  -- legacy neighbour fabric; only diagonals and the second axial ring require
  -- the boundary-aware sampler above.
  biharm_calc : process(all)
  begin
    for i in 0 to NY-1 loop
      for j in 0 to NX-1 loop
        biharm_g(i,j) <= biharmonic_term(
          u(i,j), nbw(i,j).n, nbw(i,j).s, nbw(i,j).e, nbw(i,j).w,
          sample_grid(i-1,j+1,free_mode,rim_ctrl),
          sample_grid(i-1,j-1,free_mode,rim_ctrl),
          sample_grid(i+1,j+1,free_mode,rim_ctrl),
          sample_grid(i+1,j-1,free_mode,rim_ctrl),
          sample_grid(i-2,j,free_mode,rim_ctrl),
          sample_grid(i+2,j,free_mode,rim_ctrl),
          sample_grid(i,j+2,free_mode,rim_ctrl),
          sample_grid(i,j-2,free_mode,rim_ctrl));
      end loop;
    end loop;
  end process;

  pickup_interp : process(all)
    variable lx1,ly1,rx1,ry1:natural;
  begin
    if tap_lx<NX-1 then lx1:=tap_lx+1; else lx1:=tap_lx; end if;
    if tap_ly<NY-1 then ly1:=tap_ly+1; else ly1:=tap_ly; end if;
    if tap_rx<NX-1 then rx1:=tap_rx+1; else rx1:=tap_rx; end if;
    if tap_ry<NY-1 then ry1:=tap_ry+1; else ry1:=tap_ry; end if;
    pick_l<=bilerp_quarter(u(tap_ly,tap_lx),u(tap_ly,lx1),
                           u(ly1,tap_lx),u(ly1,lx1),tap_lfx,tap_lfy);
    pick_r<=bilerp_quarter(u(tap_ry,tap_rx),u(tap_ry,rx1),
                           u(ry1,tap_rx),u(ry1,rx1),tap_rfx,tap_rfy);
  end process;

  -- Mesh-level valid: mirrors node_element's 4-clock strobe-to-commit latency.
  valid <= vsr(3);
  vld : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        vsr <= (others => '0');
      else
        vsr <= vsr(2 downto 0) & strobe;
      end if;
    end if;
  end process;

  -- Structural fabric: one PE per node, neighbour wiring generated per edge.
  gen_rows : for i in 0 to NY-1 generate
  begin
    gen_cols : for j in 0 to NX-1 generate
      signal forcing : q123_t;
    begin

      -- North (i-1)
      n_int : if i > 0 generate nbw(i, j).n <= u(i-1, j); end generate;
      n_bnd : if i = 0 generate
        n_many : if NY > 1 generate
          nbw(i,j).n <= rim_neighbor(u(i+1,j),free_mode,rim_ctrl);
        end generate;
        n_one : if NY = 1 generate nbw(i,j).n <= Q123_ZERO; end generate;
      end generate;

      -- South (i+1)
      s_int : if i < NY-1 generate nbw(i, j).s <= u(i+1, j); end generate;
      s_bnd : if i = NY-1 generate
        s_many : if NY > 1 generate
          nbw(i,j).s <= rim_neighbor(u(i-1,j),free_mode,rim_ctrl);
        end generate;
        s_one : if NY = 1 generate nbw(i,j).s <= Q123_ZERO; end generate;
      end generate;

      -- East (j+1)
      e_int : if j < NX-1 generate nbw(i, j).e <= u(i, j+1); end generate;
      e_bnd : if j = NX-1 generate
        e_many : if NX > 1 generate
          nbw(i,j).e <= rim_neighbor(u(i,j-1),free_mode,rim_ctrl);
        end generate;
        e_one : if NX = 1 generate nbw(i,j).e <= Q123_ZERO; end generate;
      end generate;

      -- West (j-1)
      w_int : if j > 0 generate nbw(i, j).w <= u(i, j-1); end generate;
      w_bnd : if j = 0 generate
        w_many : if NX > 1 generate
          nbw(i,j).w <= rim_neighbor(u(i,j+1),free_mode,rim_ctrl);
        end generate;
        w_one : if NX = 1 generate nbw(i,j).w <= Q123_ZERO; end generate;
      end generate;

      -- Runtime strike position + footprint. Size 0 is the fractional 2x2
      -- point contact; larger sizes use normalized 3x3 membrane footprints.
      force_interp : process(all)
        variable pos,neg:q123_t; variable w:natural;
        variable dx,dy,mx,my:integer;
      begin
        pos:=Q123_ZERO; neg:=Q123_ZERO;
        dx:=j-integer(strike_x); dy:=i-integer(strike_y);
        w:=footprint_weight(strike_size,dx,dy,strike_fx,strike_fy);
        if w/=0 then pos:=scale_sixteenth(exc_node,w); end if;
        if NX>=NY then mx:=NX-1-integer(strike_x); my:=integer(strike_y);
        else mx:=integer(strike_x); my:=NY-1-integer(strike_y); end if;
        if BALANCED_FREE_STRIKE and free_mode and i=my and j=mx then
          neg:=sat_store(-to_acc(exc_node));
        end if;
        forcing<=sat_store(to_acc(pos)+to_acc(neg));
      end process;
      pe : entity work.node_element
        generic map (HF_DAMPING=>HF_DAMPING)
        port map (clk=>clk, rst=>rst, strobe=>strobe, coeffs=>coeffs,
                  nb=>nbw(i,j), material=>material,anisotropy=>anisotropy,
                  stiffness_ctrl=>stiffness_ctrl,biharm=>biharm_g(i,j),
                  exc=>forcing, u_out=>u(i,j), valid=>open);


    end generate;
  end generate;

end architecture structural;
