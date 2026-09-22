-------------------------------------------------------------------------------
-- fx_master_bus.vhd - resource-light post-FX mastering/polish stage.
--
-- POLISH is ctrl3(6 downto 0): 0 is bit-exact bypass; increasing values add
-- subsonic filtering, a fixed production-style EQ curve, low-mono/high-width
-- stereo shaping, linked compression/makeup, and soft limiting.
--
-- Filters use 24/29-bit shift-add arithmetic. A single 24x11 multiplier is
-- time-shared between the left/right compressor gain operations.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;
use work.fx_pkg.all;

entity fx_master_bus is
  port (
    clk, rst, valid_in : in std_logic;
    enable             : in std_logic;
    amount             : in unsigned(6 downto 0);
    in_l, in_r         : in q123_t;
    out_l, out_r       : out q123_t;
    valid_out          : out std_logic
  );
end entity fx_master_bus;

architecture rtl of fx_master_bus is
  subtype wide_t is signed(28 downto 0); -- Q*.23, ample headroom for bus sums
  type state_t is (IDLE, GAIN_L, GAIN_R, OUTPUT);
  signal state : state_t := IDLE;

  signal hp_lp_l, hp_lp_r : q123_t := Q123_ZERO;
  signal low_lp_l, low_lp_r : q123_t := Q123_ZERO;
  signal mid_lp_l, mid_lp_r : q123_t := Q123_ZERO;
  signal side_lp : wide_t := (others=>'0');

  signal pre_l, pre_r : q123_t := Q123_ZERO;
  signal comp_l : acc_t := (others=>'0');
  signal env_q : integer range 0 to 8388608 := 0;
  signal slow_env_q : integer range 0 to 8388608 := 0;
  signal gain_q : integer range 0 to 2047 := 256;
  signal mul_a : q123_t := Q123_ZERO;
  signal mul_g : unsigned(10 downto 0) := to_unsigned(256,11);
  signal mul_p : signed(35 downto 0) := (others=>'0');
  signal mul_scaled : acc_t := (others=>'0');

  function widen(x : q123_t) return wide_t is
  begin
    return resize(x,wide_t'length);
  end function;

  function lp_step(s, x : q123_t; sh : natural) return q123_t is
    variable d,n : signed(24 downto 0);
  begin
    d:=resize(x,25)-resize(s,25);
    n:=resize(s,25)+shift_right(d,sh);
    return sat_q123(n);
  end function;

  function sub_q(a,b : q123_t) return q123_t is
    variable d : signed(24 downto 0);
  begin
    d:=resize(a,25)-resize(b,25);
    return sat_q123(d);
  end function;

  function abs_q(x : q123_t) return integer is
    variable v : integer;
  begin
    v:=to_integer(x);
    if v<0 then return -v; else return v; end if;
  end function;

  function target_gain(env, amt : integer) return integer is
    variable base, floor_g, thr, red, g : integer;
  begin
    if amt < 32 then
      base:=320; floor_g:=240; thr:=1600000;
      if env<=thr then return base; end if;
      red:=(env-thr)/16384;
    elsif amt < 80 then
      base:=512; floor_g:=216; thr:=1000000;
      if env<=thr then return base; end if;
      red:=(env-thr)/8192;
    else
      base:=768; floor_g:=192; thr:=700000;
      if env<=thr then return base; end if;
      red:=(env-thr)/4096;
    end if;
    g:=base-red; if g<floor_g then g:=floor_g; end if;
    return g;
  end function;
begin
  mul_p <= mul_a * signed('0' & std_logic_vector(mul_g));
  mul_scaled <= resize(shift_right(resize(mul_p,ACC_BITS)+to_signed(128,ACC_BITS),8),ACC_BITS);

  mul_select : process(all)
  begin
    mul_a <= Q123_ZERO;
    mul_g <= to_unsigned(gain_q,11);
    case state is
      when GAIN_L => mul_a <= pre_l;
      when GAIN_R => mul_a <= pre_r;
      when others => null;
    end case;
  end process;

  process(clk)
    variable hpnl,hpnr,lowl,lowr,midl,midr,hpl,hpr : q123_t;
    variable bandl,bandr,highl,highr,eql,eqr : wide_t;
    variable m,s,slp,sout,wl,wr : wide_t;
    variable peak_i,env_i,slow_i,det_i,tgt,delta,amt_i : integer;
  begin
    if rising_edge(clk) then
      valid_out<='0';
      if rst='1' then
        state<=IDLE;
        hp_lp_l<=Q123_ZERO; hp_lp_r<=Q123_ZERO;
        low_lp_l<=Q123_ZERO; low_lp_r<=Q123_ZERO;
        mid_lp_l<=Q123_ZERO; mid_lp_r<=Q123_ZERO;
        side_lp<=(others=>'0'); pre_l<=Q123_ZERO; pre_r<=Q123_ZERO;
        comp_l<=(others=>'0'); env_q<=0; slow_env_q<=0; gain_q<=256;
        out_l<=Q123_ZERO; out_r<=Q123_ZERO;
      else
        case state is
          when IDLE =>
            if valid_in='1' then
              if enable='0' or amount=0 then
                out_l<=in_l; out_r<=in_r; valid_out<='1';
              else
                amt_i:=to_integer(amount);

                -- 1/256 pole ~= 30 Hz at 48 kHz.
                hpnl:=lp_step(hp_lp_l,in_l,8); hpnr:=lp_step(hp_lp_r,in_r,8);
                hp_lp_l<=hpnl; hp_lp_r<=hpnr;
                hpl:=sub_q(in_l,hpnl); hpr:=sub_q(in_r,hpnr);

                -- Approx. 120 Hz and 480 Hz production-EQ split points.
                lowl:=lp_step(low_lp_l,hpl,6); lowr:=lp_step(low_lp_r,hpr,6);
                midl:=lp_step(mid_lp_l,hpl,4); midr:=lp_step(mid_lp_r,hpr,4);
                low_lp_l<=lowl; low_lp_r<=lowr; mid_lp_l<=midl; mid_lp_r<=midr;
                bandl:=widen(midl)-widen(lowl); bandr:=widen(midr)-widen(lowr);
                highl:=widen(hpl)-widen(midl); highr:=widen(hpr)-widen(midr);

                if amt_i<32 then
                  eql:=widen(hpl)+shift_right(widen(lowl),4)-shift_right(bandl,5)+shift_right(highl,5);
                  eqr:=widen(hpr)+shift_right(widen(lowr),4)-shift_right(bandr,5)+shift_right(highr,5);
                elsif amt_i<80 then
                  eql:=widen(hpl)+shift_right(widen(lowl),3)-shift_right(bandl,4)+shift_right(highl,4);
                  eqr:=widen(hpr)+shift_right(widen(lowr),3)-shift_right(bandr,4)+shift_right(highr,4);
                else
                  eql:=widen(hpl)+shift_right(widen(lowl),2)-shift_right(bandl,3)+shift_right(highl,3);
                  eqr:=widen(hpr)+shift_right(widen(lowr),2)-shift_right(bandr,3)+shift_right(highr,3);
                end if;

                -- Keep bass nearly mono while opening the upper side signal.
                m:=shift_right(eql+eqr,1); s:=shift_right(eql-eqr,1);
                slp:=side_lp+shift_right(s-side_lp,6); side_lp<=slp;
                if amt_i<32 then
                  sout:=shift_right(slp,1)+(s-slp)+shift_right(s-slp,4);
                elsif amt_i<80 then
                  sout:=shift_right(slp,2)+(s-slp)+shift_right(s-slp,3);
                else
                  sout:=shift_right(slp,3)+(s-slp)+shift_right(s-slp,2);
                end if;
                wl:=m+sout; wr:=m-sout;
                pre_l<=sat_q123(wl); pre_r<=sat_q123(wr);
                -- Stereo-linked compressor envelope and makeup target.
                peak_i:=abs_q(sat_q123(wl));
                if abs_q(sat_q123(wr))>peak_i then peak_i:=abs_q(sat_q123(wr)); end if;
                env_i:=env_q;
                if peak_i>env_i then env_i:=env_i+(peak_i-env_i)/128;
                else env_i:=env_i+(peak_i-env_i)/2048; end if;
                if env_i<0 then env_i:=0; end if;
                env_q<=env_i;

                -- Slow absolute envelope: RMS-like program memory without a
                -- squaring multiplier. Blend it with the faster peak detector.
                slow_i:=slow_env_q;
                if peak_i>slow_i then slow_i:=slow_i+(peak_i-slow_i)/1024;
                else slow_i:=slow_i+(peak_i-slow_i)/8192; end if;
                if slow_i<0 then slow_i:=0; end if;
                slow_env_q<=slow_i;
                det_i:=(env_i+slow_i)/2;

                tgt:=target_gain(det_i,amt_i);
                if tgt<gain_q then
                  delta:=(gain_q-tgt)/32; if delta<1 then delta:=1; end if;
                  if gain_q-delta<tgt then gain_q<=tgt; else gain_q<=gain_q-delta; end if;
                elsif tgt>gain_q then
                  if amt_i>=80 then delta:=(tgt-gain_q)/2048;
                  else delta:=(tgt-gain_q)/1024; end if;
                  if delta<1 then delta:=1; end if;
                  if gain_q+delta>tgt then gain_q<=tgt; else gain_q<=gain_q+delta; end if;
                end if;
                state<=GAIN_L;
              end if;
            end if;

          when GAIN_L =>
            comp_l<=mul_scaled;
            state<=GAIN_R;

          when GAIN_R =>
            out_l<=soft_clip_acc(comp_l);
            out_r<=soft_clip_acc(mul_scaled);
            state<=OUTPUT;

          when OUTPUT =>
            valid_out<='1';
            state<=IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture rtl;
