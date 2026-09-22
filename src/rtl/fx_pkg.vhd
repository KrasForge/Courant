-------------------------------------------------------------------------------
-- fx_pkg.vhd - fixed-point helpers shared by the RADIAN stereo FX chain.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

package fx_pkg is
  subtype u8_t is unsigned(7 downto 0);
  subtype q15_t is signed(15 downto 0); -- Q1.15 for BRAM-backed wet paths

  function to_q15(x : q123_t) return q15_t;
  function from_q15(x : q15_t) return q123_t;
  function scale_acc_u8(x : acc_t; g : u8_t) return acc_t;
  function scale_u8(x : q123_t; g : u8_t) return q123_t;
  function mix_u8(dry, wet : q123_t; amount : u8_t) return q123_t;
  function soft_clip_acc(x : acc_t) return q123_t;
  function stereo_pack(l, r : q123_t) return std_logic_vector;
  function pack_l(x : std_logic_vector(47 downto 0)) return q123_t;
  function pack_r(x : std_logic_vector(47 downto 0)) return q123_t;
end package fx_pkg;

package body fx_pkg is
  function to_q15(x : q123_t) return q15_t is
  begin
    return resize(shift_right(x,8),16);
  end function;

  function from_q15(x : q15_t) return q123_t is
  begin
    return shift_left(resize(x,Q_BITS),8);
  end function;

  function scale_acc_u8(x : acc_t; g : u8_t) return acc_t is
    variable gs : signed(8 downto 0);
    variable p  : signed(ACC_BITS + 9 - 1 downto 0);
    variable r  : signed(ACC_BITS + 9 - 1 downto 0);
  begin
    gs := signed('0' & std_logic_vector(g));
    p := x * gs;
    r := shift_right(p + to_signed(128, p'length), 8);
    return resize(r, ACC_BITS);
  end function;

  function scale_u8(x : q123_t; g : u8_t) return q123_t is
  begin
    return sat_store(scale_acc_u8(to_acc(x), g));
  end function;

  function mix_u8(dry, wet : q123_t; amount : u8_t) return q123_t is
    variable delta : acc_t;
    variable y     : acc_t;
  begin
    delta := to_acc(wet) - to_acc(dry);
    y := to_acc(dry) + scale_acc_u8(delta, amount);
    return sat_store(y);
  end function;

  function soft_clip_acc(x : acc_t) return q123_t is
    constant THRESH : acc_t := to_signed(2**22, ACC_BITS); -- 0.5
    variable mag, y : acc_t;
    variable neg    : boolean;
  begin
    neg := x < 0;
    if neg then mag := -x; else mag := x; end if;
    if mag <= THRESH then
      y := mag;
    else
      -- Gentle piecewise knee: 0.5 + (|x|-0.5)/4.
      y := THRESH + shift_right(mag - THRESH, 2);
    end if;
    if neg then y := -y; end if;
    return sat_store(y);
  end function;

  function stereo_pack(l, r : q123_t) return std_logic_vector is
    variable v : std_logic_vector(47 downto 0);
  begin
    v := std_logic_vector(l) & std_logic_vector(r);
    return v;
  end function;

  function pack_l(x : std_logic_vector(47 downto 0)) return q123_t is
  begin
    return signed(x(47 downto 24));
  end function;

  function pack_r(x : std_logic_vector(47 downto 0)) return q123_t is
  begin
    return signed(x(23 downto 0));
  end function;
end package body fx_pkg;
