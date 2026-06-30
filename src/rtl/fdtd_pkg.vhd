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

end package body fdtd_pkg;
