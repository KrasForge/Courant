-------------------------------------------------------------------------------
-- fdtd_pkg.vhd  -  Q1.23 types and saturating math helpers
--
-- Foundation package for the Courant FDTD RTL. Defines the signed Q1.23 fixed-
-- point type (README §4) and the saturating arithmetic used by every node.
-- Bit-behaviour is matched to the M0 quantization study (issue #4,
-- model/QMesh2D.m, docs/fixed_point_analysis.md):
--
--   * Q1.23  : signed 24-bit two's complement, value = int * 2^-23,
--              range [-1.0, +1.0).
--   * Multiply: Q1.23 x Q1.23 -> Q2.46 product, ROUND-to-nearest >>23 rescale,
--              then saturate. Rounding (not truncation) is deliberate: the M0
--              study showed truncation injects a DC bias the recursion
--              integrates (docs/fixed_point_analysis.md §3).
--   * Accumulate: a wide 48-bit guard accumulator at Q.23 scale; saturate only
--              on store back to Q1.23.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package fdtd_pkg is

  -----------------------------------------------------------------------------
  -- Format parameters
  -----------------------------------------------------------------------------
  constant FRAC     : natural := 23;   -- fractional bits
  constant Q_BITS   : natural := 24;   -- total Q1.23 word width
  constant ACC_BITS : natural := 48;   -- guard accumulator width

  subtype q123_t is signed(Q_BITS-1 downto 0);    -- Q1.23, range [-1, 1)
  subtype acc_t  is signed(ACC_BITS-1 downto 0);  -- 48-bit guard, Q.23 scale

  -- Saturation limits and the rounding constant for a >>FRAC rescale.
  constant Q123_MAX  : q123_t := to_signed(2**(Q_BITS-1) - 1, Q_BITS); -- +0.9999999
  constant Q123_MIN  : q123_t := to_signed(-(2**(Q_BITS-1)),  Q_BITS); -- -1.0
  constant Q123_ZERO : q123_t := (others => '0');
  constant ROUND_BIT : integer := 2**(FRAC-1);                         -- 2^22

  -----------------------------------------------------------------------------
  -- Conversions
  -----------------------------------------------------------------------------
  -- Quantize a real (e.g. a coefficient) to Q1.23, round-to-nearest, saturate.
  function to_q123 (x : real)   return q123_t;
  -- Q1.23 -> real (for testbenches / debug).
  function to_real (q : q123_t) return real;
  -- Sign-extend a Q1.23 value into the 48-bit guard accumulator (Q.23 scale).
  function to_acc  (q : q123_t) return acc_t;

  -----------------------------------------------------------------------------
  -- Saturation
  -----------------------------------------------------------------------------
  -- Saturate any wider signed value (interpreted at Q.23 scale) to Q1.23.
  function sat_q123 (x : signed) return q123_t;
  -- Saturating store of the guard accumulator back to Q1.23.
  function sat_store(a : acc_t)  return q123_t;

  -----------------------------------------------------------------------------
  -- Arithmetic helpers
  -----------------------------------------------------------------------------
  -- Saturating Q1.23 + Q1.23.
  function sat_add (a, b : q123_t) return q123_t;
  -- Saturating Q1.23 x Q1.23: Q2.46 product, round >>23, saturate to Q1.23.
  function q_mul   (a, b : q123_t) return q123_t;
  -- Coefficient multiply: q1.23 coeff x wide Q.23 accumuland, round >>23,
  -- result kept wide (no saturation) for further accumulation.
  function mul_coeff(c : q123_t; a : acc_t) return acc_t;
  -- Clamp to [lo, hi].
  function clamp   (x, lo, hi : q123_t) return q123_t;

  -----------------------------------------------------------------------------
  -- Node update (linear explicit scheme, README §1)
  -----------------------------------------------------------------------------
  -- Four nearest neighbours of a node (N/S/E/W). The Laplacian sums all four,
  -- so the field assignment is symmetric.
  type neighbours_t is record
    n, s, e, w : q123_t;
  end record;

  -- Precomputed per-step coefficients (README §3 control bus, §4; no per-node
  -- division).
  --   gamma2     = gamma0^2 = (c*k/h)^2   base Courant number squared
  --   a0         = 1/(1+sigma*k)          forward damping scale
  --   sigk1      = 1 - sigma*k            backward damping coefficient
  --   alpha      = chaos coupling         amplitude-dependent stiffening (README §2)
  --   gamma2_max = CFL-safe clamp ceiling (< 1/2; see issue #3, ~0.451)
  -- The linear scheme is recovered with alpha = 0 and gamma2_max >= gamma2.
  type coeffs_t is record
    gamma2     : q123_t;
    a0         : q123_t;
    sigk1      : q123_t;
    alpha      : q123_t;
    gamma2_max : q123_t;
  end record;

  -- One explicit update for a single node, with the amplitude-dependent
  -- non-linearity (README §2):
  --   g2l       = clamp(gamma2 + alpha*u^2, 0, gamma2_max)   (per node, per step)
  --   u^{n+1}   = a0 * ( 2*u^n - sigk1*u^{n-1}
  --                      + g2l*(uN+uS+uE+uW - 4*u^n) )
  -- Bit-exact with the Q1.23 reference: every multiply rounds and the wide
  -- accumulator saturates only on store. With alpha = 0 and gamma2_max >=
  -- gamma2 this reduces exactly to the linear scheme.
  function node_update (u_n, u_nm1 : q123_t;
                        nb : neighbours_t;
                        c  : coeffs_t) return q123_t;

end package fdtd_pkg;

-------------------------------------------------------------------------------

package body fdtd_pkg is

  function to_q123 (x : real) return q123_t is
    constant HI     : real := real(2**(Q_BITS-1) - 1);   -- +0.9999999 * 2^23
    constant LO     : real := real(-(2**(Q_BITS-1)));    -- -1.0 * 2^23
    variable scaled : real := round(x * real(2**FRAC));
  begin
    if    scaled >  HI then return Q123_MAX;
    elsif scaled <  LO then return Q123_MIN;
    else  return to_signed(integer(scaled), Q_BITS);
    end if;
  end function;

  function to_real (q : q123_t) return real is
  begin
    return real(to_integer(q)) / real(2**FRAC);
  end function;

  function to_acc (q : q123_t) return acc_t is
  begin
    return resize(q, ACC_BITS);
  end function;

  function sat_q123 (x : signed) return q123_t is
    constant XMAX : integer := 2**(Q_BITS-1) - 1;
    constant XMIN : integer := -(2**(Q_BITS-1));
  begin
    if    x > to_signed(XMAX, x'length) then return Q123_MAX;
    elsif x < to_signed(XMIN, x'length) then return Q123_MIN;
    else  return resize(x, Q_BITS);
    end if;
  end function;

  function sat_store (a : acc_t) return q123_t is
  begin
    return sat_q123(a);
  end function;

  function sat_add (a, b : q123_t) return q123_t is
    -- One extra bit of head-room makes the sum exact before saturating.
    variable s : signed(Q_BITS downto 0) :=
      resize(a, Q_BITS+1) + resize(b, Q_BITS+1);
  begin
    return sat_q123(s);
  end function;

  function q_mul (a, b : q123_t) return q123_t is
    variable p : signed(2*Q_BITS-1 downto 0) := a * b;          -- Q2.46
    variable r : signed(2*Q_BITS-1 downto 0);
  begin
    -- round-to-nearest, then arithmetic >>FRAC (floor toward -inf)
    r := shift_right(p + to_signed(ROUND_BIT, 2*Q_BITS), FRAC); -- Q.23
    return sat_q123(r);
  end function;

  function mul_coeff (c : q123_t; a : acc_t) return acc_t is
    variable p : signed(Q_BITS + ACC_BITS - 1 downto 0) := c * a;
    variable r : signed(Q_BITS + ACC_BITS - 1 downto 0);
  begin
    r := shift_right(p + to_signed(ROUND_BIT, Q_BITS + ACC_BITS), FRAC);
    return resize(r, ACC_BITS);
  end function;

  function clamp (x, lo, hi : q123_t) return q123_t is
  begin
    if    x < lo then return lo;
    elsif x > hi then return hi;
    else  return x;
    end if;
  end function;

  function node_update (u_n, u_nm1 : q123_t;
                        nb : neighbours_t;
                        c  : coeffs_t) return q123_t is
    variable u2      : q123_t;  -- u^2  (saturating Q1.23)
    variable au2     : q123_t;  -- alpha * u^2
    variable g2l     : q123_t;  -- gamma2_local = clamp(gamma2+alpha*u^2, 0, max)
    variable lap     : acc_t;   -- (uN+uS+uE+uW - 4*u^n)  at Q.23, exact
    variable gl      : acc_t;   -- g2l * lap
    variable su1     : acc_t;   -- sigk1  * u^{n-1}
    variable two_u   : acc_t;   -- 2 * u^n
    variable acc     : acc_t;   -- guard accumulator
    variable out_acc : acc_t;   -- a0 * (...)
  begin
    -- Amplitude-dependent local stiffness (README §2), CFL-safe clamped.
    u2  := q_mul(u_n, u_n);                       -- u^2, saturating
    au2 := q_mul(c.alpha, u2);                    -- alpha * u^2
    g2l := clamp(sat_add(c.gamma2, au2), Q123_ZERO, c.gamma2_max);

    -- Laplacian stencil, accumulated exactly in the 48-bit guard.
    lap := to_acc(nb.n) + to_acc(nb.s) + to_acc(nb.e) + to_acc(nb.w)
           - shift_left(to_acc(u_n), 2);          -- -4*u^n

    gl    := mul_coeff(g2l, lap);                 -- round >>23
    su1   := mul_coeff(c.sigk1,  to_acc(u_nm1));  -- round >>23
    two_u := shift_left(to_acc(u_n), 1);          -- 2*u^n

    acc     := two_u - su1 + gl;                  -- 2u - sigk1*u1 + g2l*lap
    out_acc := mul_coeff(c.a0, acc);              -- a0 scale, round >>23

    return sat_store(out_acc);                    -- saturate to Q1.23 on store
  end function;

end package body fdtd_pkg;
