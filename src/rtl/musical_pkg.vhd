-- Musical calibration for the actual discrete mesh, not a continuous string.
-- Tables are evaluated at elaboration; no real arithmetic is synthesized.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.fdtd_pkg.all;
package musical_pkg is
  function mode_eigenvalue(nx, ny: positive; free: boolean) return real;
  function note_gamma2(note: natural; nx, ny, os, fs: positive;
                       free: boolean) return q123_t;
  function tension_scale(g, tension: q123_t) return q123_t;
  function coordinate(v: unsigned; size: positive) return natural;
end package;
package body musical_pkg is
  function mode_eigenvalue(nx, ny: positive; free: boolean) return real is
    variable longest: positive := nx;
  begin
    if free then
      if ny > longest then longest := ny; end if;
      assert longest > 1 report "Free mesh requires at least two nodes" severity failure;
      return 4.0*sin(MATH_PI/(2.0*real(longest-1)))**2;
    end if;
    return 4.0*(sin(MATH_PI/(2.0*real(nx+1)))**2 +
                sin(MATH_PI/(2.0*real(ny+1)))**2);
  end;
  function note_gamma2(note: natural; nx, ny, os, fs: positive;
                       free: boolean) return q123_t is
    variable hz: real := 440.0*2.0**((real(note)-69.0)/12.0);
    variable g: real;
  begin
    g := 4.0*sin(MATH_PI*hz/real(fs*os))**2/mode_eigenvalue(nx,ny,free);
    if g > 0.45 then g := 0.45; end if;
    if g < 2.0**(-23) then g := 2.0**(-23); end if;
    return to_q123(g);
  end;
  -- Register 0 in musical presets is normalized tension: 0.25 = concert tuning.
  -- The wide product is rounded only once, preserving bass-note precision.
  function tension_scale(g, tension: q123_t) return q123_t is
    variable product: signed(47 downto 0);
  begin
    if tension <= 0 then return Q123_ZERO; end if;
    product := g*tension;
    return sat_q123(shift_right(product+to_signed(2**20,48),21));
  end;
  function coordinate(v: unsigned; size: positive) return natural is
    variable n: natural;
  begin
    if is_x(std_logic_vector(v)) then return 0; end if;
    n := to_integer(v);
    if n >= size then return size-1; end if;
    return n;
  end;
end package body;
