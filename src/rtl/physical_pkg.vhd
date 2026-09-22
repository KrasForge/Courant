-------------------------------------------------------------------------------
-- physical_pkg.vhd - shared low-cost physical-model helpers.
--
-- New physical controls deliberately use shift/add arithmetic so anisotropy,
-- sub-grid interpolation and material shaping do not consume another bank of
-- DSP multipliers. All-zero control fields preserve the existing musical path.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;

package physical_pkg is
  subtype frac2_t    is unsigned(1 downto 0);
  subtype material_t is unsigned(2 downto 0);
  subtype exciter_t  is unsigned(2 downto 0);
  subtype aniso_t    is signed(3 downto 0);

  function lerp_quarter(a,b:q123_t; f:frac2_t) return q123_t;
  function bilerp_quarter(a00,a10,a01,a11:q123_t;
                          fx,fy:frac2_t) return q123_t;
  function frac_weight(fx,fy:frac2_t; dx,dy:natural) return natural;
  function scale_sixteenth(x:q123_t; w:natural) return q123_t;
  function rim_neighbor(x:q123_t; free_mode:boolean; rim:unsigned(7 downto 0)) return q123_t;
  function footprint_weight(size:unsigned(7 downto 0); dx,dy:integer;
                            fx,fy:frac2_t) return natural;
  function effective_aniso(user:aniso_t; material:material_t) return aniso_t;
  function anisotropic_lap(lapx,lapy:acc_t; a:aniso_t) return acc_t;
  -- STIFFNESS is stored as an unsigned byte. Production encoding is
  -- mu2 = ctrl / 4096, spanning 0 .. 255/4096 ~= 0.06226 (near pure plate).
  function stiffness_mu2(ctrl:unsigned(7 downto 0)) return q123_t;
  function stiff_gamma2_max(base_max:q123_t; ctrl:unsigned(7 downto 0)) return q123_t;
  function biharmonic_term(c,n,s,e,w,ne,nw,se,sw,nn,ss,ee,ww:q123_t) return acc_t;
  function stiffness_term(biharm:acc_t; ctrl:unsigned(7 downto 0)) return acc_t;
  -- Multiplier-free physical mallet helpers (#87). The contact law is a
  -- piecewise-leading-bit approximation to eta^2, scaled continuously by the
  -- 8-bit HARDNESS control. The mesh coupling scale is applied once in
  -- physical_mallet after this raw contact force is computed.
  function mallet_contact_force(compression:q123_t; hardness:unsigned(7 downto 0)) return q123_t;
  function mallet_launch_velocity(strike:q123_t) return q123_t;
  function hf_loss_term(delta:acc_t; material:material_t) return acc_t;
  function material_alpha(x:q123_t; material:material_t) return q123_t;
  function effective_exciter(user:exciter_t; material:material_t) return exciter_t;
end package;
package body physical_pkg is
  function lerp_quarter(a,b:q123_t; f:frac2_t) return q123_t is
    variable d,y:acc_t;
  begin
    if is_x(std_logic_vector(a)) or is_x(std_logic_vector(b)) or is_x(std_logic_vector(f)) then return Q123_ZERO; end if;
    d:=to_acc(b)-to_acc(a); y:=to_acc(a);
    case to_integer(f) is
      when 1 => y:=y+shift_right(d,2);
      when 2 => y:=y+shift_right(d,1);
      when 3 => y:=y+shift_right(d,1)+shift_right(d,2);
      when others => null;
    end case;
    return sat_store(y);
  end;

  function bilerp_quarter(a00,a10,a01,a11:q123_t;
                          fx,fy:frac2_t) return q123_t is
    variable lo,hi:q123_t;
  begin
    lo:=lerp_quarter(a00,a10,fx);
    hi:=lerp_quarter(a01,a11,fx);
    return lerp_quarter(lo,hi,fy);
  end;

  function frac_weight(fx,fy:frac2_t; dx,dy:natural) return natural is
    variable x,y:natural;
  begin
    if is_x(std_logic_vector(fx)) or is_x(std_logic_vector(fy)) then return 0; end if;
    if dx=0 then x:=4-to_integer(fx); else x:=to_integer(fx); end if;
    if dy=0 then y:=4-to_integer(fy); else y:=to_integer(fy); end if;
    case x is
      when 0 => return 0;
      when 1 => return y;
      when 2 => return y+y;
      when 3 => return y+y+y;
      when others => return y+y+y+y;
    end case;
  end;
  function scale_sixteenth(x:q123_t; w:natural) return q123_t is
    variable a,y:acc_t;
  begin
    if is_x(std_logic_vector(x)) then return Q123_ZERO; end if;
    a:=to_acc(x); y:=(others=>'0');
    case w is
      when 1=>y:=shift_right(a,4); when 2=>y:=shift_right(a,3);
      when 3=>y:=shift_right(a,3)+shift_right(a,4); when 4=>y:=shift_right(a,2);
      when 5=>y:=shift_right(a,2)+shift_right(a,4); when 6=>y:=shift_right(a,2)+shift_right(a,3);
      when 7=>y:=shift_right(a,2)+shift_right(a,3)+shift_right(a,4); when 8=>y:=shift_right(a,1);
      when 9=>y:=shift_right(a,1)+shift_right(a,4); when 10=>y:=shift_right(a,1)+shift_right(a,3);
      when 11=>y:=shift_right(a,1)+shift_right(a,3)+shift_right(a,4); when 12=>y:=shift_right(a,1)+shift_right(a,2);
      when 13=>y:=shift_right(a,1)+shift_right(a,2)+shift_right(a,4);
      when 14=>y:=shift_right(a,1)+shift_right(a,2)+shift_right(a,3);
      when 15=>y:=a-shift_right(a,4); when 16=>y:=a; when others=>null;
    end case;
    return sat_store(y);
  end;

  function rim_neighbor(x:q123_t; free_mode:boolean; rim:unsigned(7 downto 0)) return q123_t is
    variable w:natural;
  begin
    if rim=0 then
      if free_mode then return x; else return Q123_ZERO; end if;
    end if;
    if rim=x"FF" then return x; end if;
    w:=to_integer(rim(7 downto 4));
    return scale_sixteenth(x,w);
  end;

  function footprint_weight(size:unsigned(7 downto 0); dx,dy:integer;
                            fx,fy:frac2_t) return natural is
    variable tier:natural;
  begin
    if is_x(std_logic_vector(size)) then tier:=0; else tier:=to_integer(size(7 downto 6)); end if;
    if tier=0 then
      if (dx=0 or dx=1) and (dy=0 or dy=1) then
        return frac_weight(fx,fy,natural(dx),natural(dy));
      else return 0; end if;
    elsif tier=1 then
      if dx=0 and dy=0 then return 8;
      elsif ((dx=1 or dx=-1) and dy=0) or ((dy=1 or dy=-1) and dx=0) then return 2;
      else return 0; end if;
    elsif tier=2 then
      if dx=0 and dy=0 then return 4;
      elsif ((dx=1 or dx=-1) and dy=0) or ((dy=1 or dy=-1) and dx=0) then return 2;
      elsif (dx=1 or dx=-1) and (dy=1 or dy=-1) then return 1;
      else return 0; end if;
    else
      -- Wide 13-node footprint: 3x3 unit skirt + four radius-2 axes.
      if dx=0 and dy=0 then return 4;
      elsif (dx>=-1 and dx<=1 and dy>=-1 and dy<=1) then return 1;
      elsif ((dx=2 or dx=-2) and dy=0) or ((dy=2 or dy=-2) and dx=0) then return 1;
      else return 0; end if;
    end if;
  end;

  function effective_aniso(user:aniso_t; material:material_t) return aniso_t is
    variable v,b:integer;
  begin
    if is_x(std_logic_vector(user)) or is_x(std_logic_vector(material)) then return (others=>'0'); end if;
    v:=to_integer(user);
    case to_integer(material) is
      when 2 => b:=2;   -- wood: mild grain direction
      when 3 => b:=-3;  -- metal: opposite-axis split
      when 4 => b:=5;   -- glass: stronger modal split
      when others => b:=0;
    end case;
    v:=v+b; if v>7 then v:=7; elsif v< -8 then v:=-8; end if;
    return to_signed(v,4);
  end;
  function anisotropic_lap(lapx,lapy:acc_t; a:aniso_t) return acc_t is
    variable base,d,adj:acc_t; variable k:integer;
  begin
    base:=lapx+lapy; d:=lapx-lapy; adj:=(others=>'0'); k:=to_integer(a);
    case k is
      when 1  => adj:=shift_right(d,5);
      when 2  => adj:=shift_right(d,4);
      when 3  => adj:=shift_right(d,4)+shift_right(d,5);
      when 4  => adj:=shift_right(d,3);
      when 5  => adj:=shift_right(d,3)+shift_right(d,5);
      when 6  => adj:=shift_right(d,3)+shift_right(d,4);
      when 7  => adj:=shift_right(d,3)+shift_right(d,4)+shift_right(d,5);
      when -1 => adj:=-shift_right(d,5);
      when -2 => adj:=-shift_right(d,4);
      when -3 => adj:=-shift_right(d,4)-shift_right(d,5);
      when -4 => adj:=-shift_right(d,3);
      when -5 => adj:=-shift_right(d,3)-shift_right(d,5);
      when -6 => adj:=-shift_right(d,3)-shift_right(d,4);
      when -7 => adj:=-shift_right(d,3)-shift_right(d,4)-shift_right(d,5);
      when -8 => adj:=-shift_right(d,2);
      when others => null;
    end case;
    return base+adj;
  end;
  function stiffness_mu2(ctrl:unsigned(7 downto 0)) return q123_t is
    variable q:q123_t;
  begin
    if is_x(std_logic_vector(ctrl)) then return Q123_ZERO; end if;
    -- q123(ctrl / 4096) = ctrl * 2^(23-12) = ctrl << 11.
    q:=signed(resize(ctrl,Q_BITS));
    return shift_left(q,11);
  end;

  function stiff_gamma2_max(base_max:q123_t; ctrl:unsigned(7 downto 0)) return q123_t is
    variable allowed_i:signed(Q_BITS downto 0);
    variable allowed:q123_t;
  begin
    if is_x(std_logic_vector(base_max)) or is_x(std_logic_vector(ctrl)) then return Q123_ZERO; end if;
    -- Isotropic/axis-biased RADIAN keeps g2x+g2y = 2*g2. The stiff CFL bound
    -- 2*g2 + 16*mu2 <= 1 therefore gives g2 <= 0.5 - 8*mu2.
    -- With mu2=ctrl/4096, Q1.23 allowed = 2^22 - ctrl*2^14 exactly.
    allowed_i:=to_signed(2**22,Q_BITS+1)
               - shift_left(resize(signed('0' & std_logic_vector(ctrl)),Q_BITS+1),14);
    if allowed_i<=0 then return Q123_ZERO; end if;
    allowed:=resize(allowed_i,Q_BITS);
    if allowed<base_max then return allowed; else return base_max; end if;
  end;

  function biharmonic_term(c,n,s,e,w,ne,nw,se,sw,nn,ss,ee,ww:q123_t) return acc_t is
    variable first4,diag4,second4,center:acc_t;
  begin
    center:=to_acc(c);
    first4:=to_acc(n)+to_acc(s)+to_acc(e)+to_acc(w);
    diag4:=to_acc(ne)+to_acc(nw)+to_acc(se)+to_acc(sw);
    second4:=to_acc(nn)+to_acc(ss)+to_acc(ee)+to_acc(ww);
    -- B = 20C - 8(N+S+E+W) + 2(diagonals) + (second axial ring).
    return shift_left(center,4)+shift_left(center,2)
           -shift_left(first4,3)+shift_left(diag4,1)+second4;
  end;

  function stiffness_term(biharm:acc_t; ctrl:unsigned(7 downto 0)) return acc_t is
    subtype wide_t is signed(ACC_BITS+8 downto 0);
    variable base,sum,rounded:wide_t;
  begin
    if is_x(std_logic_vector(biharm)) or is_x(std_logic_vector(ctrl)) then
      return (others=>'0');
    end if;
    -- Exact product for the production encoding mu2=ctrl/4096, implemented as
    -- eight static shift/add terms so this control does not claim another DSP.
    base:=resize(biharm,wide_t'length); sum:=(others=>'0');
    for b in 0 to 7 loop
      if ctrl(b)='1' then sum:=sum+shift_left(base,b); end if;
    end loop;
    -- Match mul_coeff's round-then-arithmetic-shift convention at /4096.
    rounded:=shift_right(sum+to_signed(2**11,wide_t'length),12);
    return resize(rounded,ACC_BITS);
  end;

  function mallet_contact_force(compression:q123_t; hardness:unsigned(7 downto 0)) return q123_t is
    variable sq_approx:q123_t:=Q123_ZERO;
    variable base,sum,scaled:acc_t;
    variable found:boolean:=false;
  begin
    if is_x(std_logic_vector(compression)) or is_x(std_logic_vector(hardness))
       or compression<=Q123_ZERO or hardness=0 then return Q123_ZERO; end if;

    -- Multiplier-free eta^2 approximation. If the leading one is bit p, eta
    -- lies in [2^(p-23), 2^(p-22)); eta*2^(p-23) approximates eta^2 within
    -- a factor <2, with continuous piecewise-linear segments.
    for p in 22 downto 0 loop
      if not found and compression(p)='1' then
        sq_approx:=shift_right(compression,FRAC-p);
        found:=true;
      end if;
    end loop;
    if not found then return Q123_ZERO; end if;

    -- Continuous HARDNESS gain: (32 + h)/64 = 0.5 .. 4.484375.
    -- The h multiplication is eight static shift/add terms, not a DSP.
    base:=to_acc(sq_approx); sum:=(others=>'0');
    for b in 0 to 7 loop
      if hardness(b)='1' then sum:=sum+shift_left(base,b); end if;
    end loop;
    scaled:=shift_right(base,1)+shift_right(sum+to_signed(32,ACC_BITS),6);
    return sat_store(scaled);
  end;

  function mallet_launch_velocity(strike:q123_t) return q123_t is
    variable a:acc_t; variable mag:q123_t;
  begin
    if is_x(std_logic_vector(strike)) then return Q123_ZERO; end if;
    a:=to_acc(strike);
    if a<0 then a:=-a; end if;
    mag:=sat_store(a);
    -- Velocity is displacement per oversampled mesh step. It depends only on
    -- strike energy/velocity, never HARDNESS.
    return shift_right(mag,9);
  end;

  function hf_loss_term(delta:acc_t; material:material_t) return acc_t is
  begin
    if is_x(std_logic_vector(material)) then return shift_right(delta,7); end if;
    case to_integer(material) is
      when 2 => return shift_right(delta,6); -- wood: fastest HF loss
      when 3 => return shift_right(delta,8); -- metal: long bright ring
      when 4 => return shift_right(delta,9); -- glass: longest HF ring
      when others => return shift_right(delta,7); -- current/neutral + membrane
    end case;
  end;

  function material_alpha(x:q123_t; material:material_t) return q123_t is
    variable a,y:acc_t;
  begin
    if is_x(std_logic_vector(x)) then return Q123_ZERO; end if;
    if is_x(std_logic_vector(material)) then return x; end if;
    a:=to_acc(x); y:=a;
    case to_integer(material) is
      when 1 => y:=a-shift_right(a,2); -- membrane: smoother / more linear
      when 2 => y:=a-shift_right(a,3); -- wood
      when 3 => y:=a+shift_right(a,2); -- metal
      when 4 => y:=a+shift_right(a,1); -- glass
      when others => null;
    end case;
    return sat_store(y);
  end;

  function effective_exciter(user:exciter_t; material:material_t) return exciter_t is
  begin
    if is_x(std_logic_vector(user)) or is_x(std_logic_vector(material)) then return (others=>'0'); end if;
    if user/=0 then return user; end if;
    case to_integer(material) is
      when 1 => return to_unsigned(2,3); -- soft mallet
      when 2 => return to_unsigned(2,3); -- broad wooden mallet
      when 3 => return to_unsigned(4,3); -- rim/hard impulse
      when 4 => return to_unsigned(3,3); -- pluck/bipolar
      when others => return to_unsigned(0,3); -- current velocity-auto behavior
    end case;
  end;
end package body;
