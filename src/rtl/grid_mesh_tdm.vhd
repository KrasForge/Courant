-------------------------------------------------------------------------------
-- grid_mesh_tdm.vhd  -  time-multiplexed mesh (one PE folded over the grid)
--
-- Functionally identical to grid_mesh (same ports, same Q1.23 result), but
-- instead of one node_element per node it stores the whole grid in memory and
-- sweeps it through a SINGLE shared datapath, one node per clock. This breaks
-- the O(N^2) DSP ceiling of the fully-spatial mesh (README §3): the datapath is
-- ~18 DSP regardless of NX*NY, at the cost of NX*NY clocks per mesh step.
--
-- State storage: two memories (mem_a / mem_b) hold the grid, ping-ponged each
-- step. Reads gather the 5-point stencil from the "current" memory (u^n) and
-- the node's own u^{n-1} from the "previous" memory; the result u^{n+1} is
-- written back into the previous memory (whose u^{n-1} value is no longer
-- needed once that node is computed). After the sweep the roles swap. Because
-- every neighbour is read from the consistent u^n snapshot, the result is
-- bit-exact with the spatial grid_mesh.
--
-- One strobe = one full sweep; `valid` pulses when the sweep completes (so
-- mesh_resonator's per-step handshake works unchanged). For larger meshes the
-- single datapath becomes a pool of P PEs over partitioned nodes, and the
-- combinational-read memory becomes registered-read block RAM with row line
-- buffers; both are width/throughput refinements of this structure.
--
-- Budget: a sweep is NX*NY + a few clocks; with oversampling OS the mesh costs
-- ~OS*NX*NY clocks/frame, well within ~2083 clocks at 100 MHz / 48 kHz for a
-- modest grid (e.g. 16x16 at OS=4 ~ 1024 clocks). See docs/timing_budget.md.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity grid_mesh_tdm is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    FREE_BOUNDARY : boolean  := false;
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
end entity grid_mesh_tdm;

architecture rtl of grid_mesh_tdm is

  constant N      : natural := NX * NY;
  constant A_EXC  : natural := EXC_Y * NX + EXC_X;
  constant A_PL   : natural := PICK_LY * NX + PICK_LX;
  constant A_PR   : natural := PICK_RY * NX + PICK_RX;

  type mem_t is array (0 to N-1) of q123_t;
  signal mem_a : mem_t := (others => (others => '0'));
  signal mem_b : mem_t := (others => (others => '0'));
  signal cur_sel : std_logic := '0';            -- '0': cur=mem_a, prev=mem_b

  type state_t is (IDLE, SWEEP, FINISH);
  signal state : state_t := IDLE;
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

begin

  assert not FREE_BOUNDARY or (NX >= 2 and NY >= 2)
    report "grid_mesh_tdm: FREE_BOUNDARY requires NX >= 2 and NY >= 2"
    severity failure;

  process (clk)
    variable vC, vP, vN, vS, vE, vW : q123_t;
    variable u2, au2, g2l           : q123_t;
    variable lap, su1, two_u, acc   : acc_t;
    variable exc_v                  : q123_t;
    variable u_new                  : q123_t;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        mem_a   <= (others => (others => '0'));
        mem_b   <= (others => (others => '0'));
        cur_sel <= '0';
        state   <= IDLE;
        a_cnt   <= 0; i_cnt <= 0; j_cnt <= 0;
        pick_l  <= (others => '0');
        pick_r  <= (others => '0');
        valid   <= '0';
      else
        valid <= '0';
        case state is

          when IDLE =>
            if strobe = '1' then
              a_cnt <= 0; i_cnt <= 0; j_cnt <= 0;
              exc_lat  <= exc_in;          -- hold excitation for the whole sweep
              exen_lat <= exc_en;
              state <= SWEEP;
            end if;

          when SWEEP =>
            -- gather the 5-point stencil from u^n (boundary handled), self u^{n-1}
            vC := cur_rd(a_cnt);
            vP := prev_rd(a_cnt);
            if    i_cnt > 0        then vN := cur_rd(a_cnt - NX);
            elsif FREE_BOUNDARY    then vN := cur_rd(a_cnt + NX);
            else                        vN := (others => '0'); end if;
            if    i_cnt < NY-1     then vS := cur_rd(a_cnt + NX);
            elsif FREE_BOUNDARY    then vS := cur_rd(a_cnt - NX);
            else                        vS := (others => '0'); end if;
            if    j_cnt < NX-1     then vE := cur_rd(a_cnt + 1);
            elsif FREE_BOUNDARY    then vE := cur_rd(a_cnt - 1);
            else                        vE := (others => '0'); end if;
            if    j_cnt > 0        then vW := cur_rd(a_cnt - 1);
            elsif FREE_BOUNDARY    then vW := cur_rd(a_cnt + 1);
            else                        vW := (others => '0'); end if;

            -- node update (matches node_element exactly, incl. exc forcing)
            u2  := q_mul(vC, vC);
            au2 := q_mul(coeffs.alpha, u2);
            g2l := clamp(sat_add(coeffs.gamma2, au2), Q123_ZERO, coeffs.gamma2_max);
            lap := to_acc(vN) + to_acc(vS) + to_acc(vE) + to_acc(vW)
                   - shift_left(to_acc(vC), 2);
            su1 := mul_coeff(coeffs.sigk1, to_acc(vP));
            two_u := shift_left(to_acc(vC), 1);
            acc := two_u - su1 + mul_coeff(g2l, lap);
            if exen_lat = '1' and a_cnt = A_EXC then exc_v := exc_lat;
            else exc_v := (others => '0'); end if;
            u_new := sat_store(mul_coeff(coeffs.a0, acc) + to_acc(exc_v));

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
            end if;

          when FINISH =>
            -- the just-written (previous) memory becomes the new current
            if cur_sel = '0' then
              pick_l <= mem_b(A_PL); pick_r <= mem_b(A_PR);
            else
              pick_l <= mem_a(A_PL); pick_r <= mem_a(A_PR);
            end if;
            cur_sel <= not cur_sel;
            valid   <= '1';
            state   <= IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
