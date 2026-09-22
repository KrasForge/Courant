-------------------------------------------------------------------------------
-- grid_mesh_tdm.vhd  -  time-multiplexed mesh (one PE folded over the grid)
--
-- Functionally identical to grid_mesh (same ports, same Q1.23 result), but
-- instead of one node_element per node it stores the whole grid in memory and
-- sweeps it through a SINGLE shared datapath. STIFFNESS=0 retains the legacy
-- one-node-per-clock raster. Nonzero STIFFNESS uses four gather clocks plus one
-- update clock per node for the diagonal/second-ring plate stencil. This breaks
-- the O(N^2) DSP ceiling of the fully-spatial mesh: the datapath remains ~18 DSP
-- regardless of NX*NY.
--
-- State storage: two memories (mem_a / mem_b) hold the grid, ping-ponged each
-- step. The normal update reads the 5-point stencil from the "current" memory
-- (u^n) and u^{n-1} from the "previous" memory. For the plate term, four gather
-- states capture the additional eight taps two at a time from the same u^n
-- snapshot. The result u^{n+1} is written into the previous memory; after the
-- sweep the roles swap. This keeps the result bit-exact with spatial grid_mesh.
--
-- One strobe = one full sweep; `valid` pulses when the sweep completes, so
-- mesh_resonator's handshake is unchanged. At 8x8, nonzero stiffness measures
-- 322 clocks/mesh-step; OS=4 uses 1288 mesh clocks/frame before small wrapper
-- overhead, within ~2083 clocks at 100 MHz / 48 kHz. STIFFNESS=0 bypasses the
-- gather states and keeps legacy timing. See docs/timing_budget.md.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;
use work.physical_pkg.all;

entity grid_mesh_tdm is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    FREE_BOUNDARY : boolean  := false;
    BALANCED_FREE_STRIKE : boolean := false;
    HF_DAMPING : boolean := false;
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
end entity grid_mesh_tdm;

architecture rtl of grid_mesh_tdm is

  constant N      : natural := NX * NY;
  constant A_EXC  : natural := EXC_Y * NX + EXC_X;
  constant A_PL   : natural := PICK_LY * NX + PICK_LX;
  constant A_PR   : natural := PICK_RY * NX + PICK_RX;

  function mirror_x return natural is
  begin if NX >= NY then return NX-1-EXC_X; else return EXC_X; end if; end;
  function mirror_y return natural is
  begin if NX >= NY then return EXC_Y; else return NY-1-EXC_Y; end if; end;
  constant A_NEG : natural := mirror_y*NX+mirror_x;
  signal free_lat : boolean := FREE_BOUNDARY;
  signal al_lat, ar_lat : natural range 0 to N-1 := 0;
  signal tlx_lat,trx_lat,tlx1_lat,trx1_lat : natural range 0 to NX-1 := 0;
  signal tly_lat,try_lat,tly1_lat,try1_lat : natural range 0 to NY-1 := 0;
  signal lfx_lat,lfy_lat,rfx_lat,rfy_lat,sfx_lat,sfy_lat : frac2_t := (others=>'0');
  signal mat_lat : material_t := (others=>'0');
  signal aniso_lat : aniso_t := (others=>'0');
  signal rim_lat,size_lat,stiff_lat : unsigned(7 downto 0):=(others=>'0');
  signal sx_lat,sx1_lat : natural range 0 to NX-1 := EXC_X;
  signal sy_lat,sy1_lat : natural range 0 to NY-1 := EXC_Y;
  signal lp00,lp10,lp01,lp11,rp00,rp10,rp01,rp11 : q123_t := Q123_ZERO;
  signal cp00,cp10,cp01,cp11 : q123_t := Q123_ZERO;
  signal contact_u,mallet_force : q123_t := Q123_ZERO;
  signal mallet_contact,mallet_active : std_logic;
  type mem_t is array (0 to N-1) of q123_t;
  signal mem_a : mem_t := (others => (others => '0'));
  signal mem_b : mem_t := (others => (others => '0'));
  subtype lap27_t is signed(26 downto 0);
  type lap_mem_t is array (0 to N-1) of lap27_t;
  signal lap_hist : lap_mem_t := (others => (others=>'0'));
  signal cur_sel : std_logic := '0';            -- '0': cur=mem_a, prev=mem_b

  type state_t is (IDLE, GATHER_NE_NW, GATHER_SE_SW, GATHER_NN_SS, GATHER_EE_WW, SWEEP, FINISH);
  signal state : state_t := IDLE;
  signal g_ne,g_nw,g_se,g_sw,g_nn,g_ss,g_ee,g_ww : q123_t := Q123_ZERO;
  signal a_cnt : integer range 0 to N := 0;     -- node address being swept
  signal i_cnt : integer range 0 to NY-1 := 0;  -- its row
  signal j_cnt : integer range 0 to NX-1 := 0;  -- its column

  -- excitation latched at sweep start (the exc node is reached mid-sweep, long
  -- after the strobe, so the inputs must be held for the whole sweep)
  signal exc_lat : q123_t   := (others => '0');
  signal exen_lat : std_logic := '0';

  -- read the current (u^n) / previous (u^{n-1}) memory under the ping-pong
  impure function cur_rd(addr : integer) return q123_t is
  begin
    if cur_sel = '0' then return mem_a(addr); else return mem_b(addr); end if;
  end function;
  impure function prev_rd(addr : integer) return q123_t is
  begin
    if cur_sel = '0' then return mem_b(addr); else return mem_a(addr); end if;
  end function;

  -- Boundary-aware random access for diagonal and second-ring plate taps.
  impure function cur_xy(y,x:integer; fm:boolean; rim:unsigned(7 downto 0))
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
    v:=cur_rd(yy*NX+xx);
    if cross_y then v:=rim_neighbor(v,fm,rim); end if;
    if cross_x then v:=rim_neighbor(v,fm,rim); end if;
    return v;
  end function;


begin
  mallet : entity work.physical_mallet
    port map(clk=>clk,rst=>rst,enable=>mallet_enable,step=>strobe,
             trigger=>exc_en,strike_velocity=>exc_in,hardness=>hardness_ctrl,
             surface_u=>contact_u,force_out=>mallet_force,
             contact=>mallet_contact,active=>mallet_active,
             hammer_x=>open,hammer_v=>open);

  assert not BALANCED_FREE_STRIKE or A_NEG /= A_EXC
    report "Balanced free excitation needs distinct mirrored nodes" severity failure;

  assert not FREE_BOUNDARY or (NX >= 2 and NY >= 2)
    report "grid_mesh_tdm: FREE_BOUNDARY requires NX >= 2 and NY >= 2"
    severity failure;

  process (clk)
    variable vC, vP, vN, vS, vE, vW : q123_t;
    variable vNE,vNW,vSE,vSW,vNN,vSS,vEE,vWW : q123_t;
    variable u2, au2, g2l             : q123_t;
    variable lap,lapx,lapy,biharm,su1,two_u,acc : acc_t;
    variable exc_v,pos_v,neg_v       : q123_t;
    variable u_new                   : q123_t;
    variable w                       : natural;
    variable dx,dy,mx,my             : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        mem_a   <= (others => (others => '0'));
        mem_b   <= (others => (others => '0'));
        lap_hist <= (others => (others=>'0'));
        cur_sel <= '0';
        state   <= IDLE;
        a_cnt   <= 0; i_cnt <= 0; j_cnt <= 0;
        pick_l  <= (others => '0');
        pick_r  <= (others => '0');
        lp00<=Q123_ZERO;lp10<=Q123_ZERO;lp01<=Q123_ZERO;lp11<=Q123_ZERO;
        rp00<=Q123_ZERO;rp10<=Q123_ZERO;rp01<=Q123_ZERO;rp11<=Q123_ZERO;
        cp00<=Q123_ZERO;cp10<=Q123_ZERO;cp01<=Q123_ZERO;cp11<=Q123_ZERO;
        contact_u<=Q123_ZERO;
        stiff_lat<=(others=>'0');
        g_ne<=Q123_ZERO;g_nw<=Q123_ZERO;g_se<=Q123_ZERO;g_sw<=Q123_ZERO;
        g_nn<=Q123_ZERO;g_ss<=Q123_ZERO;g_ee<=Q123_ZERO;g_ww<=Q123_ZERO;
        valid   <= '0';
      else
        valid <= '0';
        case state is

          when IDLE =>
            if strobe = '1' then
              a_cnt <= 0; i_cnt <= 0; j_cnt <= 0;
              free_lat <= free_mode;
              al_lat <= tap_ly*NX+tap_lx; ar_lat <= tap_ry*NX+tap_rx;
              tlx_lat<=tap_lx; tly_lat<=tap_ly; trx_lat<=tap_rx; try_lat<=tap_ry;
              if tap_lx<NX-1 then tlx1_lat<=tap_lx+1; else tlx1_lat<=tap_lx; end if;
              if tap_ly<NY-1 then tly1_lat<=tap_ly+1; else tly1_lat<=tap_ly; end if;
              if tap_rx<NX-1 then trx1_lat<=tap_rx+1; else trx1_lat<=tap_rx; end if;
              if tap_ry<NY-1 then try1_lat<=tap_ry+1; else try1_lat<=tap_ry; end if;
              lp00<=Q123_ZERO;lp10<=Q123_ZERO;lp01<=Q123_ZERO;lp11<=Q123_ZERO;
              rp00<=Q123_ZERO;rp10<=Q123_ZERO;rp01<=Q123_ZERO;rp11<=Q123_ZERO;
              cp00<=Q123_ZERO;cp10<=Q123_ZERO;cp01<=Q123_ZERO;cp11<=Q123_ZERO;
              lfx_lat<=tap_lfx; lfy_lat<=tap_lfy; rfx_lat<=tap_rfx; rfy_lat<=tap_rfy;
              sfx_lat<=strike_fx; sfy_lat<=strike_fy; mat_lat<=material; aniso_lat<=anisotropy;
              rim_lat<=rim_ctrl; size_lat<=strike_size; stiff_lat<=stiffness_ctrl;
              sx_lat<=strike_x; sy_lat<=strike_y;
              if strike_x<NX-1 then sx1_lat<=strike_x+1; else sx1_lat<=strike_x; end if;
              if strike_y<NY-1 then sy1_lat<=strike_y+1; else sy1_lat<=strike_y; end if;
              -- Sample the mallet force before physical_mallet advances on this
              -- same strobe edge, matching the spatial backend's update order.
              if mallet_enable='1' then
                exc_lat<=mallet_force;
                if mallet_force/=Q123_ZERO then exen_lat<='1'; else exen_lat<='0'; end if;
              else
                exc_lat<=exc_in; exen_lat<=exc_en;
              end if;
              if stiffness_ctrl=0 then state<=SWEEP; else state<=GATHER_NE_NW; end if;
            end if;

          -- The extra eight plate taps are gathered two per clock. This keeps
          -- the TDM state memory at the old read-port pressure instead of
          -- synthesizing eight additional simultaneous read muxes. At 8x8,
          -- one mesh step is 5*64+1 clocks; OS=4 is 1284 clocks/frame.
          when GATHER_NE_NW =>
            g_ne<=cur_xy(i_cnt-1,j_cnt+1,free_lat,rim_lat);
            g_nw<=cur_xy(i_cnt-1,j_cnt-1,free_lat,rim_lat);
            state<=GATHER_SE_SW;
          when GATHER_SE_SW =>
            g_se<=cur_xy(i_cnt+1,j_cnt+1,free_lat,rim_lat);
            g_sw<=cur_xy(i_cnt+1,j_cnt-1,free_lat,rim_lat);
            state<=GATHER_NN_SS;
          when GATHER_NN_SS =>
            g_nn<=cur_xy(i_cnt-2,j_cnt,free_lat,rim_lat);
            g_ss<=cur_xy(i_cnt+2,j_cnt,free_lat,rim_lat);
            state<=GATHER_EE_WW;
          when GATHER_EE_WW =>
            g_ee<=cur_xy(i_cnt,j_cnt+2,free_lat,rim_lat);
            g_ww<=cur_xy(i_cnt,j_cnt-2,free_lat,rim_lat);
            state<=SWEEP;

          when SWEEP =>
            -- gather the 5-point stencil from u^n (boundary handled), self u^{n-1}
            vC := cur_rd(a_cnt);
            vP := prev_rd(a_cnt);
            if i_cnt>0 then vN:=cur_rd(a_cnt-NX);
            else vN:=rim_neighbor(cur_rd(a_cnt+NX),free_lat,rim_lat); end if;
            if i_cnt<NY-1 then vS:=cur_rd(a_cnt+NX);
            else vS:=rim_neighbor(cur_rd(a_cnt-NX),free_lat,rim_lat); end if;
            if j_cnt<NX-1 then vE:=cur_rd(a_cnt+1);
            else vE:=rim_neighbor(cur_rd(a_cnt-1),free_lat,rim_lat); end if;
            if j_cnt>0 then vW:=cur_rd(a_cnt-1);
            else vW:=rim_neighbor(cur_rd(a_cnt+1),free_lat,rim_lat); end if;

            -- node update (matches node_element exactly, incl. exc forcing)
            u2  := q_mul(vC, vC);
            au2 := q_mul(coeffs.alpha, u2);
            g2l := clamp(sat_add(coeffs.gamma2, au2), Q123_ZERO,
                         stiff_gamma2_max(coeffs.gamma2_max,stiff_lat));
            lapx:=to_acc(vE)+to_acc(vW)-shift_left(to_acc(vC),1);
            lapy:=to_acc(vN)+to_acc(vS)-shift_left(to_acc(vC),1);
            lap:=anisotropic_lap(lapx,lapy,effective_aniso(aniso_lat,mat_lat));
            vNE:=g_ne;vNW:=g_nw;vSE:=g_se;vSW:=g_sw;
            vNN:=g_nn;vSS:=g_ss;vEE:=g_ee;vWW:=g_ww;
            biharm:=biharmonic_term(vC,vN,vS,vE,vW,vNE,vNW,vSE,vSW,vNN,vSS,vEE,vWW);
            su1 := mul_coeff(coeffs.sigk1, to_acc(vP));
            two_u := shift_left(to_acc(vC), 1);
            acc := two_u - su1 + mul_coeff(g2l, lap) - stiffness_term(biharm,stiff_lat);
            if HF_DAMPING then
              acc:=acc+hf_loss_term(lap-resize(lap_hist(a_cnt),ACC_BITS),mat_lat);
              lap_hist(a_cnt)<=resize(lap,lap27_t'length);
            end if;
            pos_v:=Q123_ZERO; neg_v:=Q123_ZERO; w:=0;
            if exen_lat='1' then
              dx:=j_cnt-integer(sx_lat); dy:=i_cnt-integer(sy_lat);
              w:=footprint_weight(size_lat,dx,dy,sfx_lat,sfy_lat);
              if w/=0 then pos_v:=scale_sixteenth(exc_lat,w); end if;
              if NX>=NY then mx:=NX-1-integer(sx_lat);my:=integer(sy_lat);
              else mx:=integer(sx_lat);my:=NY-1-integer(sy_lat);end if;
              if i_cnt=my and j_cnt=mx and free_lat and BALANCED_FREE_STRIKE then
                neg_v:=sat_store(-to_acc(exc_lat));
              end if;
            end if;
            exc_v:=sat_store(to_acc(pos_v)+to_acc(neg_v));
            u_new := sat_store(mul_coeff(coeffs.a0, acc) + to_acc(exc_v));

            -- Capture pickup interpolation corners during the normal raster.
            if i_cnt=tly_lat and j_cnt=tlx_lat then lp00<=u_new; end if;
            if i_cnt=tly_lat and j_cnt=tlx1_lat then lp10<=u_new; end if;
            if i_cnt=tly1_lat and j_cnt=tlx_lat then lp01<=u_new; end if;
            if i_cnt=tly1_lat and j_cnt=tlx1_lat then lp11<=u_new; end if;
            if i_cnt=try_lat and j_cnt=trx_lat then rp00<=u_new; end if;
            if i_cnt=try_lat and j_cnt=trx1_lat then rp10<=u_new; end if;
            if i_cnt=try1_lat and j_cnt=trx_lat then rp01<=u_new; end if;
            if i_cnt=try1_lat and j_cnt=trx1_lat then rp11<=u_new; end if;
            if i_cnt=sy_lat and j_cnt=sx_lat then cp00<=u_new; end if;
            if i_cnt=sy_lat and j_cnt=sx1_lat then cp10<=u_new; end if;
            if i_cnt=sy1_lat and j_cnt=sx_lat then cp01<=u_new; end if;
            if i_cnt=sy1_lat and j_cnt=sx1_lat then cp11<=u_new; end if;

            -- write u^{n+1} into the previous memory
            if cur_sel = '0' then mem_b(a_cnt) <= u_new;
            else                  mem_a(a_cnt) <= u_new; end if;

            -- advance the raster sweep
            if a_cnt = N-1 then
              state <= FINISH;
            else
              a_cnt <= a_cnt + 1;
              if j_cnt = NX-1 then j_cnt <= 0; i_cnt <= i_cnt + 1;
              else                 j_cnt <= j_cnt + 1; end if;
              if stiff_lat=0 then state<=SWEEP; else state<=GATHER_NE_NW; end if;
            end if;

          when FINISH =>
            -- Bilinear pickup interpolation from corners captured during sweep.
            pick_l<=bilerp_quarter(lp00,lp10,lp01,lp11,lfx_lat,lfy_lat);
            pick_r<=bilerp_quarter(rp00,rp10,rp01,rp11,rfx_lat,rfy_lat);
            contact_u<=bilerp_quarter(cp00,cp10,cp01,cp11,sfx_lat,sfy_lat);
            cur_sel <= not cur_sel;
            valid   <= '1';
            state   <= IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
