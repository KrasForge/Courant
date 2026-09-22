-------------------------------------------------------------------------------
-- node_element.vhd  -  single-node processing element (PE)
--
-- The per-node datapath of README §3: state registers u^n / u^{n-1}, the Q1.23
-- non-linear fixed-point update (node_update from fdtd_pkg) spread across a
-- 4-stage pipeline, and N/S/E/W neighbour ports. One mesh time-step is taken
-- per assertion of `strobe`; the result appears `valid` cycles later. Per
-- README §3 the update is a multi-stage pipeline, NOT a single combinational
-- edge.
--
-- Pipeline (signed multiplies isolated to map onto DSP slices with registered
-- operands and a registered result):
--   stage 1 : Laplacian sum, sigk1*u^{n-1}, u^2, 2*u^n        (capture inputs)
--   stage 2 : alpha*u^2, gamma2_local = clamp(gamma2+alpha*u^2, 0, gamma2_max)
--   stage 3 : gamma2_local*lap - mu2*biharm, form the guarded stiff-surface sum
--   stage 4 : a0*(...) + forcing, saturate, commit u^n / u^{n-1}
-- Latency from `strobe` to `valid` is 4 clocks. Strobes must be spaced at least
-- 4 clocks apart (the mesh has ~2083 clocks per sample at 100 MHz / 48 kHz).
--
-- With STIFFNESS=0 the committed result is bit-exact with node_update (and the
-- legacy Q1.23 reference) when forcing `exc` is 0. With coeffs.alpha=0 and
-- coeffs.gamma2_max>=coeffs.gamma2, that path reduces exactly to the linear
-- membrane update. Nonzero STIFFNESS adds the separately verified biharmonic
-- plate term.
--
-- `exc` is an optional additive forcing (the "mallet"), captured with the
-- update and added into the 48-bit guard before the store-saturate. It
-- defaults to rest (0).
--
-- Synthesisable VHDL-2008: one synchronous process, synchronous reset to rest.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;
use work.physical_pkg.all;

entity node_element is
  generic (HF_DAMPING : boolean := false);
  port (
    clk    : in  std_logic;
    rst    : in  std_logic;          -- synchronous, active-high; resets to rest
    strobe : in  std_logic;          -- begin one sample update
    coeffs : in  coeffs_t;           -- gamma2 / a0 / sigk1 / alpha / gamma2_max
    nb     : in  neighbours_t;       -- N/S/E/W neighbour displacements (u^n)
    material : in material_t := (others=>'0');
    anisotropy : in aniso_t := (others=>'0');
    stiffness_ctrl : in unsigned(7 downto 0) := (others=>'0');
    biharm : in acc_t := (others=>'0');      -- 13-point plate operator at u^n
    exc    : in  q123_t := (others => '0'); -- additive forcing (mallet); default rest
    u_out  : out q123_t;             -- this node's current displacement u^n
    valid  : out std_logic           -- 1-cycle pulse when u_out has advanced
  );
end entity node_element;

architecture rtl of node_element is

  -- Committed state
  signal u_n   : q123_t := (others => '0');
  signal u_nm1 : q123_t := (others => '0');

  -- Previous local curvature for the optional frequency-dependent loss.
  -- A 27-bit Q.23 word spans the full 5-point Laplacian range (about +/-8).
  signal lap_hist : signed(26 downto 0) := (others=>'0');

  -- Stage-1 registers
  signal s1_lap    : acc_t  := (others => '0');
  signal s1_lapv   : acc_t  := (others => '0');
  signal s1_biharm : acc_t  := (others => '0');
  signal s1_stiff  : unsigned(7 downto 0) := (others=>'0');
  signal s1_su1    : acc_t  := (others => '0');
  signal s1_u2     : q123_t := (others => '0');   -- u^2
  signal s1_two_u  : acc_t  := (others => '0');
  signal s1_ucap   : q123_t := (others => '0');   -- u^n captured (-> u^{n-1})
  signal s1_exc    : q123_t := (others => '0');
  signal s1_gamma2 : q123_t := (others => '0');
  signal s1_alpha  : q123_t := (others => '0');
  signal s1_gmax   : q123_t := (others => '0');
  signal s1_a0     : q123_t := (others => '0');

  -- Stage-2 registers
  signal s2_lap   : acc_t  := (others => '0');
  signal s2_lapv  : acc_t  := (others => '0');
  signal s2_biharm: acc_t  := (others => '0');
  signal s2_stiff : unsigned(7 downto 0) := (others=>'0');
  signal s2_su1   : acc_t  := (others => '0');
  signal s2_g2l   : q123_t := (others => '0');     -- gamma2_local (clamped)
  signal s2_two_u : acc_t  := (others => '0');
  signal s2_ucap  : q123_t := (others => '0');
  signal s2_exc   : q123_t := (others => '0');
  signal s2_a0    : q123_t := (others => '0');

  -- Stage-3 registers
  signal s3_acc  : acc_t  := (others => '0');
  signal s3_ucap : q123_t := (others => '0');
  signal s3_exc  : q123_t := (others => '0');
  signal s3_a0   : q123_t := (others => '0');

  -- Valid pipeline: vsr(0) = stage-1 loaded ... vsr(3) = committed result
  signal vsr : std_logic_vector(3 downto 0) := (others => '0');

begin

  u_out <= u_n;
  valid <= vsr(3);

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        u_n      <= (others => '0');
        u_nm1    <= (others => '0');
        lap_hist <= (others => '0');
        s1_lap   <= (others => '0'); s1_lapv  <= (others => '0');
        s1_biharm<= (others => '0'); s1_stiff <= (others=>'0'); s1_su1 <= (others => '0');
        s1_u2    <= (others => '0'); s1_two_u <= (others => '0');
        s1_ucap  <= (others => '0'); s1_exc   <= (others => '0');
        s1_gamma2<= (others => '0'); s1_alpha <= (others => '0');
        s1_gmax  <= (others => '0'); s1_a0    <= (others => '0');
        s2_lap   <= (others => '0'); s2_lapv  <= (others => '0');
        s2_biharm<= (others => '0'); s2_stiff <= (others=>'0'); s2_su1 <= (others => '0');
        s2_g2l   <= (others => '0'); s2_two_u <= (others => '0');
        s2_ucap  <= (others => '0'); s2_exc   <= (others => '0');
        s2_a0    <= (others => '0');
        s3_acc   <= (others => '0'); s3_ucap  <= (others => '0');
        s3_exc   <= (others => '0'); s3_a0    <= (others => '0');
        vsr      <= (others => '0');
      else
        -- valid shift register
        vsr(0) <= strobe;
        vsr(1) <= vsr(0);
        vsr(2) <= vsr(1);
        vsr(3) <= vsr(2);

        -- Stage 1: capture inputs and the first arithmetic layer
        if strobe = '1' then
          s1_lap <= anisotropic_lap(
                      to_acc(nb.e)+to_acc(nb.w)-shift_left(to_acc(u_n),1),
                      to_acc(nb.n)+to_acc(nb.s)-shift_left(to_acc(u_n),1),
                      effective_aniso(anisotropy,material));
          s1_lapv <= anisotropic_lap(
                       to_acc(nb.e)+to_acc(nb.w)-shift_left(to_acc(u_n),1),
                       to_acc(nb.n)+to_acc(nb.s)-shift_left(to_acc(u_n),1),
                       effective_aniso(anisotropy,material)) - resize(lap_hist,ACC_BITS);
          if HF_DAMPING then
            lap_hist <= resize(anisotropic_lap(
                          to_acc(nb.e)+to_acc(nb.w)-shift_left(to_acc(u_n),1),
                          to_acc(nb.n)+to_acc(nb.s)-shift_left(to_acc(u_n),1),
                          effective_aniso(anisotropy,material)),lap_hist'length);
          end if;
          s1_biharm <= biharm;
          s1_stiff  <= stiffness_ctrl;
          s1_su1    <= mul_coeff(coeffs.sigk1, to_acc(u_nm1));-- sigk1 * u^{n-1}
          s1_u2     <= q_mul(u_n, u_n);                       -- u^2 (saturating)
          s1_two_u  <= shift_left(to_acc(u_n), 1);            -- 2 * u^n
          s1_ucap   <= u_n;
          s1_exc    <= exc;
          s1_gamma2 <= coeffs.gamma2;
          s1_alpha  <= coeffs.alpha;
          s1_gmax   <= stiff_gamma2_max(coeffs.gamma2_max,stiffness_ctrl);
          s1_a0     <= coeffs.a0;
        end if;

        -- Stage 2: amplitude-dependent local stiffness, CFL-safe clamped
        if vsr(0) = '1' then
          s2_g2l  <= clamp(sat_add(s1_gamma2, q_mul(s1_alpha, s1_u2)),
                           Q123_ZERO, s1_gmax);
          s2_lap   <= s1_lap;
          s2_lapv  <= s1_lapv;
          s2_biharm<= s1_biharm;
          s2_stiff <= s1_stiff;
          s2_su1   <= s1_su1;
          s2_two_u <= s1_two_u;
          s2_ucap  <= s1_ucap;
          s2_exc   <= s1_exc;
          s2_a0    <= s1_a0;
        end if;

        -- Stage 3: gamma2_local * lap, then the guard-accumulator sum
        if vsr(1) = '1' then
          if HF_DAMPING then
            -- Kelvin-Voigt-like loss: high-curvature velocity components lose
            -- energy faster than low modes. 1/128 is deliberately subtle.
            s3_acc <= s2_two_u - s2_su1 + mul_coeff(s2_g2l,s2_lap)
                      - stiffness_term(s2_biharm,s2_stiff)
                      + hf_loss_term(s2_lapv,material);
          else
            s3_acc <= s2_two_u - s2_su1 + mul_coeff(s2_g2l,s2_lap)
                      - stiffness_term(s2_biharm,s2_stiff);
          end if;
          s3_ucap <= s2_ucap;
          s3_exc  <= s2_exc;
          s3_a0   <= s2_a0;
        end if;

        -- Stage 4: a0 scale, add forcing in the guard, saturate on store
        if vsr(2) = '1' then
          u_n   <= sat_store(mul_coeff(s3_a0, s3_acc) + to_acc(s3_exc));
          u_nm1 <= s3_ucap;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
