-------------------------------------------------------------------------------
-- fx_chain.vhd - complete post-mesh RADIAN stereo effects chain.
--
-- Addresses 10..15 retain the existing preset layout. Improvements here are
-- RTL-only: sample-rate parameter smoothing, click-free effect fades, optional
-- tempo-grid delay encoding, the modulated FDN, and POLISH mastering.
--
-- ctrl2 raw mode: bit23=0, bits23..8 = delay samples (legacy compatible).
-- ctrl2 sync mode: bit23=1, bits22..16=BPM-60 (60..187), bits15..13=division.
-- ctrl3(6..0) is POLISH (0 = exact mastering-stage bypass).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;
use work.fx_pkg.all;

entity fx_chain is
  generic (FS_HZ : positive := 48_000);
  port (
    clk, rst, valid_in : in std_logic;
    in_l, in_r         : in q123_t;
    ctrl0, ctrl1, ctrl2, ctrl3, ctrl4, ctrl5 : in std_logic_vector(23 downto 0);
    out_l, out_r       : out q123_t;
    valid_out          : out std_logic
  );
end entity;

architecture rtl of fx_chain is
  constant MAX_DELAY : positive := FS_HZ/2; -- 500 ms physical delay RAM
  type quarter_tab_t is array(0 to 127) of natural range 1 to FS_HZ;
  function build_quarter_tab return quarter_tab_t is
    variable t : quarter_tab_t;
    variable bpm,q : integer;
  begin
    for b in 0 to 127 loop
      bpm:=60+b; q:=(FS_HZ*60)/bpm;
      if q<1 then q:=1; end if;
      if q>FS_HZ then q:=FS_HZ; end if;
      t(b):=q;
    end loop;
    return t;
  end function;
  constant QUARTER_TAB : quarter_tab_t := build_quarter_tab;
  function build_triplet_tab return quarter_tab_t is
    variable t : quarter_tab_t;
    variable bpm,n : integer;
  begin
    for b in 0 to 127 loop
      bpm:=60+b; n:=(FS_HZ*60)/(3*bpm);
      if n<1 then n:=1; end if;
      if n>FS_HZ then n:=FS_HZ; end if;
      t(b):=n;
    end loop;
    return t;
  end function;
  constant TRIPLET_TAB : quarter_tab_t := build_triplet_tab;

  function approach8(cur,tgt : unsigned(7 downto 0); step : natural) return unsigned is
    variable c,t : integer; variable n : integer;
  begin
    c:=to_integer(cur); t:=to_integer(tgt);
    if c<t then n:=c+integer(step); if n>t then n:=t; end if;
    elsif c>t then n:=c-integer(step); if n<t then n:=t; end if;
    else n:=c; end if;
    return to_unsigned(n,8);
  end function;
  function approach7(cur,tgt : unsigned(6 downto 0); step : natural) return unsigned is
    variable c,t,n : integer;
  begin
    c:=to_integer(cur); t:=to_integer(tgt); n:=c;
    if c<t then n:=c+integer(step); if n>t then n:=t; end if;
    elsif c>t then n:=c-integer(step); if n<t then n:=t; end if; end if;
    return to_unsigned(n,7);
  end function;
  function approach16(cur,tgt : unsigned(15 downto 0); step : natural) return unsigned is
    variable c,t,n : integer;
  begin
    c:=to_integer(cur); t:=to_integer(tgt); n:=c;
    if c<t then n:=c+integer(step); if n>t then n:=t; end if;
    elsif c>t then n:=c-integer(step); if n<t then n:=t; end if; end if;
    return to_unsigned(n,16);
  end function;
  function delay_target(w : std_logic_vector(23 downto 0)) return unsigned is
    variable q,tr,n,dv,bi : integer;
  begin
    if w(23)='1' then
      bi:=to_integer(unsigned(w(22 downto 16)));
      q:=QUARTER_TAB(bi); tr:=TRIPLET_TAB(bi);
      dv:=to_integer(unsigned(w(15 downto 13)));
      case dv is
        when 0 => n:=q/4;          -- 1/16
        when 1 => n:=q/2;          -- 1/8
        when 2 => n:=(3*q)/4;      -- dotted 1/8
        when 3 => n:=q;            -- 1/4
        when 4 => n:=(3*q)/2;      -- dotted 1/4
        when 5 => n:=2*q;          -- 1/2
        when 6 => n:=tr;           -- 1/8 triplet
        when others => n:=2*tr;    -- 1/4 triplet
      end case;
      if n<1 then n:=1; end if;
      if n>MAX_DELAY-1 then n:=MAX_DELAY-1; end if;
      return to_unsigned(n,16);
    end if;
    return unsigned(w(23 downto 8));
  end function;

  signal d_l,d_r,t_l,t_r,c_l,c_r,dl_l,dl_r,rv_l,rv_r,mb_l,mb_r : q123_t := Q123_ZERO;
  signal d_v,t_v,c_v,dl_v,rv_v,mb_v : std_logic := '0';
  signal master_en,drive_en,tone_en,chorus_en,delay_en,reverb_en : std_logic;
  signal master_run,drive_run,tone_run,chorus_run,delay_run,reverb_run : std_logic;
  signal master_prev,first_active : std_logic := '0';

  signal drive_s : unsigned(7 downto 0) := (others=>'0');
  signal tone_s : unsigned(7 downto 0) := to_unsigned(128,8);
  signal ch_rate_s,ch_depth_s,ch_mix_s : unsigned(7 downto 0) := (others=>'0');
  signal delay_time_s : unsigned(15 downto 0) := to_unsigned(1,16);
  signal delay_mix_s,delay_fb_s,delay_damp_s : unsigned(7 downto 0) := (others=>'0');
  signal rev_decay_s,rev_damp_s,rev_mix_s,rev_size_s,rev_diff_s : unsigned(7 downto 0) := (others=>'0');
  signal out_trim_s : unsigned(7 downto 0) := x"FF";
  signal master_mix_s : unsigned(7 downto 0) := (others=>'0');
  signal dry_hold_l,dry_hold_r : q123_t := Q123_ZERO;
  signal polish_s : unsigned(6 downto 0) := (others=>'0');
  signal drive_eff,tone_eff,ch_rate_eff,ch_depth_eff,ch_mix_eff : unsigned(7 downto 0);
  signal delay_time_eff : unsigned(15 downto 0);
  signal delay_mix_eff,delay_fb_eff,delay_damp_eff : unsigned(7 downto 0);
  signal rev_decay_eff,rev_damp_eff,rev_mix_eff,rev_size_eff,rev_diff_eff,out_trim_eff : unsigned(7 downto 0);
  signal polish_eff : unsigned(6 downto 0);
  signal delay_ping : std_logic;
begin
  master_en<=ctrl0(23); drive_en<=ctrl0(22); tone_en<=ctrl0(21);
  chorus_en<=ctrl0(20); delay_en<=ctrl0(19); reverb_en<=ctrl0(18);
  delay_ping<=ctrl3(7);
  first_active<=master_en and not master_prev;
  master_run<='1' when master_en='1' or master_mix_s/=0 else '0';
  drive_eff<=unsigned(ctrl0(17 downto 10)) when first_active='1' and drive_en='1' else drive_s;
  tone_eff<=unsigned(ctrl0(9 downto 2)) when first_active='1' and tone_en='1' else tone_s;
  ch_rate_eff<=unsigned(ctrl1(23 downto 16)) when first_active='1' else ch_rate_s;
  ch_depth_eff<=unsigned(ctrl1(15 downto 8)) when first_active='1' else ch_depth_s;
  ch_mix_eff<=unsigned(ctrl1(7 downto 0)) when first_active='1' and chorus_en='1' else ch_mix_s;
  delay_time_eff<=delay_target(ctrl2) when first_active='1' else delay_time_s;
  delay_mix_eff<=unsigned(ctrl2(7 downto 0)) when first_active='1' and delay_en='1' else delay_mix_s;
  delay_fb_eff<=unsigned(ctrl3(23 downto 16)) when first_active='1' else delay_fb_s;
  delay_damp_eff<=unsigned(ctrl3(15 downto 8)) when first_active='1' else delay_damp_s;
  rev_decay_eff<=unsigned(ctrl4(23 downto 16)) when first_active='1' else rev_decay_s;
  rev_damp_eff<=unsigned(ctrl4(15 downto 8)) when first_active='1' else rev_damp_s;
  rev_mix_eff<=unsigned(ctrl4(7 downto 0)) when first_active='1' and reverb_en='1' else rev_mix_s;
  rev_size_eff<=unsigned(ctrl5(23 downto 16)) when first_active='1' else rev_size_s;
  rev_diff_eff<=unsigned(ctrl5(15 downto 8)) when first_active='1' else rev_diff_s;
  out_trim_eff<=unsigned(ctrl5(7 downto 0)) when first_active='1' else out_trim_s;
  polish_eff<=unsigned(ctrl3(6 downto 0)) when first_active='1' else polish_s;

  drive_run<=master_run when drive_en='1' or drive_s/=0 else '0';
  tone_run<=master_run when tone_en='1' or tone_s/=to_unsigned(128,8) else '0';
  chorus_run<=master_run when chorus_en='1' or ch_mix_s/=0 else '0';
  delay_run<=master_run when delay_en='1' or delay_mix_s/=0 else '0';
  reverb_run<=master_run when reverb_en='1' or rev_mix_s/=0 else '0';
  smooth : process(clk)
    variable dt : unsigned(15 downto 0);
    variable da,ta,cr,cd,cm,dm,df,dd,rd,rda,rm,rs,rdf,ot,mm : unsigned(7 downto 0);
    variable pa : unsigned(6 downto 0);
  begin
    if rising_edge(clk) then
      if rst='1' then
        master_prev<='0'; drive_s<=(others=>'0'); tone_s<=to_unsigned(128,8);
        ch_rate_s<=(others=>'0'); ch_depth_s<=(others=>'0'); ch_mix_s<=(others=>'0');
        delay_time_s<=to_unsigned(1,16); delay_mix_s<=(others=>'0');
        delay_fb_s<=(others=>'0'); delay_damp_s<=(others=>'0');
        rev_decay_s<=(others=>'0'); rev_damp_s<=(others=>'0'); rev_mix_s<=(others=>'0');
        rev_size_s<=(others=>'0'); rev_diff_s<=(others=>'0');
        out_trim_s<=x"FF"; master_mix_s<=(others=>'0');
        dry_hold_l<=Q123_ZERO; dry_hold_r<=Q123_ZERO; polish_s<=(others=>'0');
      elsif valid_in='1' then
        da:=unsigned(ctrl0(17 downto 10)); if drive_en='0' then da:=(others=>'0'); end if;
        ta:=unsigned(ctrl0(9 downto 2)); if tone_en='0' then ta:=to_unsigned(128,8); end if;
        cr:=unsigned(ctrl1(23 downto 16)); cd:=unsigned(ctrl1(15 downto 8));
        cm:=unsigned(ctrl1(7 downto 0)); if chorus_en='0' then cm:=(others=>'0'); end if;
        dt:=delay_target(ctrl2); dm:=unsigned(ctrl2(7 downto 0));
        if delay_en='0' then dm:=(others=>'0'); end if;
        df:=unsigned(ctrl3(23 downto 16)); dd:=unsigned(ctrl3(15 downto 8));
        rd:=unsigned(ctrl4(23 downto 16)); rda:=unsigned(ctrl4(15 downto 8));
        rm:=unsigned(ctrl4(7 downto 0)); if reverb_en='0' then rm:=(others=>'0'); end if;
        rs:=unsigned(ctrl5(23 downto 16)); rdf:=unsigned(ctrl5(15 downto 8));
        ot:=unsigned(ctrl5(7 downto 0)); pa:=unsigned(ctrl3(6 downto 0));
        if master_en='1' then mm:=x"FF"; else
          mm:=(others=>'0'); da:=(others=>'0'); ta:=to_unsigned(128,8);
          cm:=(others=>'0'); dm:=(others=>'0'); rm:=(others=>'0'); pa:=(others=>'0');
        end if;
        dry_hold_l<=in_l; dry_hold_r<=in_r;
        master_mix_s<=approach8(master_mix_s,mm,2);

        -- Initial activation snaps to the preset. Subsequent edits/macro moves
        -- slew at audio rate, avoiding zippering without slow startup.
        if master_en='1' and master_prev='0' then
          drive_s<=da; tone_s<=ta; ch_rate_s<=cr; ch_depth_s<=cd; ch_mix_s<=cm;
          delay_time_s<=dt; delay_mix_s<=dm; delay_fb_s<=df; delay_damp_s<=dd;
          rev_decay_s<=rd; rev_damp_s<=rda; rev_mix_s<=rm; rev_size_s<=rs; rev_diff_s<=rdf;
          out_trim_s<=ot; polish_s<=pa;
        else
          drive_s<=approach8(drive_s,da,2); tone_s<=approach8(tone_s,ta,2);
          ch_rate_s<=approach8(ch_rate_s,cr,1); ch_depth_s<=approach8(ch_depth_s,cd,1);
          ch_mix_s<=approach8(ch_mix_s,cm,2);
          delay_time_s<=approach16(delay_time_s,dt,1); delay_mix_s<=approach8(delay_mix_s,dm,2);
          delay_fb_s<=approach8(delay_fb_s,df,1); delay_damp_s<=approach8(delay_damp_s,dd,1);
          rev_decay_s<=approach8(rev_decay_s,rd,1); rev_damp_s<=approach8(rev_damp_s,rda,1);
          rev_mix_s<=approach8(rev_mix_s,rm,2); rev_size_s<=approach8(rev_size_s,rs,1);
          rev_diff_s<=approach8(rev_diff_s,rdf,1); out_trim_s<=approach8(out_trim_s,ot,2);
          polish_s<=approach7(polish_s,pa,1);
        end if;
        master_prev<=master_en;
      end if;
    end if;
  end process;
  drive_i : entity work.fx_drive
    port map(clk=>clk,rst=>rst,valid_in=>valid_in,enable=>drive_run,amount=>drive_eff,
             in_l=>in_l,in_r=>in_r,out_l=>d_l,out_r=>d_r,valid_out=>d_v);
  tone_i : entity work.fx_tone
    port map(clk=>clk,rst=>rst,valid_in=>d_v,enable=>tone_run,tone=>tone_eff,
             in_l=>d_l,in_r=>d_r,out_l=>t_l,out_r=>t_r,valid_out=>t_v);
  chorus_i : entity work.fx_chorus
    port map(clk=>clk,rst=>rst,valid_in=>t_v,enable=>chorus_run,
             rate=>ch_rate_eff,depth=>ch_depth_eff,mix=>ch_mix_eff,
             in_l=>t_l,in_r=>t_r,out_l=>c_l,out_r=>c_r,valid_out=>c_v);
  delay_i : entity work.fx_delay
    generic map(MAX_DELAY_SAMPLES=>MAX_DELAY)
    port map(clk=>clk,rst=>rst,valid_in=>c_v,enable=>delay_run,
             time_samples=>delay_time_eff,feedback=>delay_fb_eff,damping=>delay_damp_eff,
             pingpong=>delay_ping,mix=>delay_mix_eff,
             in_l=>c_l,in_r=>c_r,out_l=>dl_l,out_r=>dl_r,valid_out=>dl_v);
  reverb_i : entity work.fx_fdn_reverb
    port map(clk=>clk,rst=>rst,valid_in=>dl_v,enable=>reverb_run,
             decay=>rev_decay_eff,damping=>rev_damp_eff,size=>rev_size_eff,diffusion=>rev_diff_eff,
             mix=>rev_mix_eff,in_l=>dl_l,in_r=>dl_r,out_l=>rv_l,out_r=>rv_r,valid_out=>rv_v);
  master_i : entity work.fx_master_bus
    port map(clk=>clk,rst=>rst,valid_in=>rv_v,enable=>master_run,amount=>polish_eff,
             in_l=>rv_l,in_r=>rv_r,out_l=>mb_l,out_r=>mb_r,valid_out=>mb_v);

  finish : process(clk)
    variable yl,yr : q123_t;
  begin
    if rising_edge(clk) then
      valid_out<='0';
      if rst='1' then out_l<=Q123_ZERO; out_r<=Q123_ZERO;
      elsif mb_v='1' then
        if master_run='1' then
          if out_trim_eff=x"FF" then yl:=mb_l;yr:=mb_r;
          else yl:=scale_u8(mb_l,out_trim_eff);yr:=scale_u8(mb_r,out_trim_eff);end if;
          yl:=soft_clip_acc(to_acc(yl)); yr:=soft_clip_acc(to_acc(yr));
        else yl:=mb_l;yr:=mb_r; end if;
        if master_mix_s=0 then
          out_l<=dry_hold_l; out_r<=dry_hold_r;
        elsif master_mix_s=x"FF" then
          out_l<=yl; out_r<=yr;
        else
          out_l<=mix_u8(dry_hold_l,yl,master_mix_s);
          out_r<=mix_u8(dry_hold_r,yr,master_mix_s);
        end if;
        valid_out<='1';
      end if;
    end if;
  end process;
end architecture rtl;
