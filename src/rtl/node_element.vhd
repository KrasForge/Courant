-------------------------------------------------------------------------------
-- node_element.vhd  -  single-node processing element (PE)
--
-- The per-node datapath of README §3: state registers u^n / u^{n-1}, the
-- Q1.23 fixed-point update (node_update from fdtd_pkg) spread across a 3-stage
-- pipeline, and N/S/E/W neighbour ports. One mesh time-step is taken per
-- assertion of `strobe`; the result appears `valid` cycles later. As README §3
-- notes, the update is a multi-stage pipeline, NOT a single combinational edge.
--
-- Pipeline (one signed multiply per stage, so each maps cleanly to a DSP slice
-- with registered operands and a registered result):
--   stage 1 : Laplacian sum, sigk1*u^{n-1}, 2*u^n   (capture inputs)
--   stage 2 : gamma2*lap, form 2u - sigk1*u1 + gamma2*lap
--   stage 3 : a0*(...), saturate, commit u^n / u^{n-1}
-- Latency from `strobe` to `valid` is 3 clocks. Strobes must be spaced at least
-- 3 clocks apart (the mesh has ~2083 clocks per sample at 100 MHz / 48 kHz).
--
-- The committed result is bit-exact with node_update (and hence the Q1.23
-- reference model, model/QMesh2D.m) when the forcing input `exc` is 0.
--
-- `exc` is an optional additive forcing (the "mallet"), captured with the
-- update and added into the 48-bit guard before the store-saturate. It
-- defaults to rest (0), so a node with `exc` left unconnected behaves exactly
-- as the pure linear update.
--
-- Synthesisable VHDL-2008: one synchronous process, synchronous reset to rest.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity node_element is
  port (
    clk    : in  std_logic;
    rst    : in  std_logic;          -- synchronous, active-high; resets to rest
    strobe : in  std_logic;          -- begin one sample update
    coeffs : in  coeffs_t;           -- precomputed gamma2 / a0 / sigk1
    nb     : in  neighbours_t;       -- N/S/E/W neighbour displacements (u^n)
    exc    : in  q123_t := (others => '0'); -- additive forcing (mallet); default rest
    u_out  : out q123_t;             -- this node's current displacement u^n
    valid  : out std_logic           -- 1-cycle pulse when u_out has advanced
  );
end entity node_element;

architecture rtl of node_element is

  -- Committed state
  signal u_n   : q123_t := (others => '0');
  signal u_nm1 : q123_t := (others => '0');

  -- Stage-1 registers
  signal s1_lap    : acc_t  := (others => '0');
  signal s1_su1    : acc_t  := (others => '0');
  signal s1_two_u  : acc_t  := (others => '0');
  signal s1_ucap   : q123_t := (others => '0');   -- u^n captured (-> u^{n-1})
  signal s1_gamma2 : q123_t := (others => '0');
  signal s1_a0     : q123_t := (others => '0');

  signal s1_exc    : q123_t := (others => '0');   -- forcing captured at strobe

  -- Stage-2 registers
  signal s2_acc  : acc_t  := (others => '0');
  signal s2_ucap : q123_t := (others => '0');
  signal s2_a0   : q123_t := (others => '0');
  signal s2_exc  : q123_t := (others => '0');

  -- Valid pipeline: vsr(0) tracks stage-1 loaded, vsr(2) the committed result
  signal vsr : std_logic_vector(2 downto 0) := (others => '0');

begin

  u_out <= u_n;
  valid <= vsr(2);

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        u_n      <= (others => '0');
        u_nm1    <= (others => '0');
        s1_lap   <= (others => '0');
        s1_su1   <= (others => '0');
        s1_two_u <= (others => '0');
        s1_ucap  <= (others => '0');
        s1_gamma2<= (others => '0');
        s1_a0    <= (others => '0');
        s1_exc   <= (others => '0');
        s2_acc   <= (others => '0');
        s2_ucap  <= (others => '0');
        s2_a0    <= (others => '0');
        s2_exc   <= (others => '0');
        vsr      <= (others => '0');
      else
        -- valid shift register
        vsr(0) <= strobe;
        vsr(1) <= vsr(0);
        vsr(2) <= vsr(1);

        -- Stage 1: capture inputs and the first arithmetic layer
        if strobe = '1' then
          s1_lap    <= to_acc(nb.n) + to_acc(nb.s) + to_acc(nb.e) + to_acc(nb.w)
                       - shift_left(to_acc(u_n), 2);          -- (uN+uS+uE+uW) - 4*u^n
          s1_su1    <= mul_coeff(coeffs.sigk1, to_acc(u_nm1));-- sigk1 * u^{n-1}
          s1_two_u  <= shift_left(to_acc(u_n), 1);            -- 2 * u^n
          s1_ucap   <= u_n;
          s1_gamma2 <= coeffs.gamma2;
          s1_a0     <= coeffs.a0;
          s1_exc    <= exc;
        end if;

        -- Stage 2: gamma2 * lap, then the guard-accumulator sum
        if vsr(0) = '1' then
          s2_acc  <= s1_two_u - s1_su1 + mul_coeff(s1_gamma2, s1_lap);
          s2_ucap <= s1_ucap;
          s2_a0   <= s1_a0;
          s2_exc  <= s1_exc;
        end if;

        -- Stage 3: a0 scale, add forcing in the guard, saturate on store
        if vsr(1) = '1' then
          u_n   <= sat_store(mul_coeff(s2_a0, s2_acc) + to_acc(s2_exc));
          u_nm1 <= s2_ucap;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
