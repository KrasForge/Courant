library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
library work;
use work.fdtd_pkg.all;
use work.physical_pkg.all;

entity musical_refine_tb is end entity;
architecture sim of musical_refine_tb is
  constant T:time:=10 ns;
  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal frame:std_logic:='0';
  signal coeffs:coeffs_t;
  signal free_m:boolean:=false;
  signal mat:material_t:=(others=>'0'); signal exmode:exciter_t:=(others=>'0');
  signal aniso:aniso_t:=(others=>'0');
  signal rim,size,hardness:unsigned(7 downto 0):=(others=>'0');
  signal sx:natural range 0 to 7:=2; signal sy:natural range 0 to 7:=2;
  signal sfx,sfy,lfx,lfy,rfx,rfy:frac2_t:=(others=>'0');
  signal exc:q123_t:=Q123_ZERO; signal exen:std_logic:='0';
  signal sl,sr,tl,tr:q123_t; signal sv,tv:std_logic;
  signal p_on,p_off:std_logic:='0'; signal p_note:std_logic_vector(6 downto 0):=(others=>'0');
  signal pl,pr:q123_t; signal pv:std_logic; signal pact:std_logic_vector(0 downto 0);
  signal done:boolean:=false;
begin
  clock:process begin
    while not done loop clk<='0';wait for T/2;clk<='1';wait for T/2;end loop;wait;
  end process;

  spatial:entity work.mesh_resonator
    generic map(NX=>8,NY=>8,OS=>4,TIME_MUX=>false,BALANCED_FREE_STRIKE=>true,
                HF_DAMPING=>true,STRIKE_SHAPING=>true)
    port map(free_mode=>free_m,
             tap_lfx=>lfx,tap_lfy=>lfy,tap_rfx=>rfx,tap_rfy=>rfy,
             material=>mat,exciter_mode=>exmode,anisotropy=>aniso,
             hardness_ctrl=>hardness,rim_ctrl=>rim,strike_size=>size,
             strike_x=>sx,strike_y=>sy,strike_fx=>sfx,strike_fy=>sfy,
             clk=>clk,rst=>rst,frame=>frame,coeffs=>coeffs,
             exc_in=>exc,exc_en=>exen,out_l=>sl,out_r=>sr,out_valid=>sv);

  folded:entity work.mesh_resonator
    generic map(NX=>8,NY=>8,OS=>4,TIME_MUX=>true,BALANCED_FREE_STRIKE=>true,
                HF_DAMPING=>true,STRIKE_SHAPING=>true)
    port map(free_mode=>free_m,
             tap_lfx=>lfx,tap_lfy=>lfy,tap_rfx=>rfx,tap_rfy=>rfy,
             material=>mat,exciter_mode=>exmode,anisotropy=>aniso,
             hardness_ctrl=>hardness,rim_ctrl=>rim,strike_size=>size,
             strike_x=>sx,strike_y=>sy,strike_fx=>sfx,strike_fy=>sfy,
             clk=>clk,rst=>rst,frame=>frame,coeffs=>coeffs,
             exc_in=>exc,exc_en=>exen,out_l=>tl,out_r=>tr,out_valid=>tv);

  musical_poly:entity work.poly_voices
    generic map(MUSICAL_VOICES=>true,NVOICES=>1,NX=>8,NY=>8,OS=>4,TIME_MUX=>true)
    port map(free_mode=>free_m,clk=>clk,rst=>rst,frame=>frame,
             note_on=>p_on,note_off=>p_off,note=>p_note,coeffs_in=>coeffs,exc_in=>exc,
             out_l=>pl,out_r=>pr,out_valid=>pv,active=>pact);
  stim:process
    procedure step is begin wait until rising_edge(clk); end;
    procedure one_frame(strike:boolean; amp:real; variable energy:inout integer) is
      variable a,b,c,d:integer;
    begin
      exc<=to_q123(amp); if strike then exen<='1';else exen<='0';end if;
      frame<='1';step;frame<='0';
      loop step; exit when sv='1'; end loop; a:=to_integer(sl);b:=to_integer(sr);
      loop step; exit when tv='1'; end loop; c:=to_integer(tl);d:=to_integer(tr);
      exen<='0';
      assert a=c and b=d report "musical_refine_tb: spatial/TDM mismatch" severity failure;
      energy:=energy+abs(a)+abs(b);
    end;
    procedure poly_strike(n:natural) is
    begin
      p_note<=std_logic_vector(to_unsigned(n,7)); p_on<='1'; step; p_on<='0'; step; step;
    end;
    procedure poly_frames(n:natural; variable energy:inout integer) is
    begin
      for k in 1 to n loop
        frame<='1';step;frame<='0';
        loop step; exit when pv='1'; end loop;
        energy:=energy+abs(to_integer(pl))+abs(to_integer(pr));
      end loop;
    end;
    variable hard_energy,soft_energy,free_energy,physical_energy,shape_energy,scrape_energy,scrape_hard_energy,human_a,human_b:integer:=0;
  begin
    coeffs<=(gamma2=>to_q123(0.18),a0=>to_q123(0.99997),
             sigk1=>to_q123(0.99997),alpha=>to_q123(0.03),
             gamma2_max=>to_q123(0.451));
    rst<='1';step;step;rst<='0';step;
    for f in 0 to 47 loop one_frame(f=0,0.72,hard_energy); end loop;
    assert hard_energy>0 report "musical_refine_tb: hard shaped strike silent" severity failure;

    rst<='1';step;step;rst<='0';step;
    for f in 0 to 47 loop one_frame(f=0,0.18,soft_energy); end loop;
    assert soft_energy>0 report "musical_refine_tb: soft shaped strike silent" severity failure;
    assert hard_energy/=soft_energy
      report "musical_refine_tb: velocity-dependent strike shaping had no effect" severity failure;

    free_m<=true; rst<='1';step;step;rst<='0';step;
    for f in 0 to 47 loop one_frame(f=0,0.55,free_energy); end loop;
    assert free_energy>0 report "musical_refine_tb: balanced free-boundary strike silent" severity failure;

    -- New physical-model pass: MATERIAL + explicit anisotropy + quarter-grid
    -- strike/pickup positions must remain bit-exact across the two backends.
    free_m<=false; mat<=to_unsigned(3,3); aniso<=to_signed(2,4); exmode<=(others=>'0');
    sfx<=to_unsigned(1,2); sfy<=to_unsigned(2,2);
    lfx<=to_unsigned(2,2); lfy<=to_unsigned(1,2); rfx<=to_unsigned(1,2); rfy<=to_unsigned(3,2);
    rst<='1';step;step;rst<='0';step;
    for f in 0 to 47 loop one_frame(f=0,0.55,physical_energy); end loop;
    assert physical_energy>0 and physical_energy/=hard_energy
      report "musical_refine_tb: MATERIAL/anisotropy/fractional geometry had no effect" severity failure;
    assert material_alpha(to_q123(0.20),to_unsigned(3,3))>to_q123(0.20)
      report "musical_refine_tb: metal MATERIAL did not increase nonlinearity macro" severity failure;

    -- Mode-B membrane controls: compliant rim, broad contact and moved strike.
    mat<=(others=>'0');aniso<=(others=>'0');rim<=x"80";size<=x"C0";sx<=3;sy<=4;
    sfx<=to_unsigned(2,2);sfy<=to_unsigned(1,2);exmode<=(others=>'0');
    rst<='1';step;step;rst<='0';step;
    for f in 0 to 47 loop one_frame(f=0,0.55,shape_energy); end loop;
    assert shape_energy>0 and shape_energy/=hard_energy
      report "musical_refine_tb: RIM/STRIKE SIZE/XY had no effect" severity failure;

    -- Explicit scrape/bow-burst mode uses all four oversample substeps.
    mat<=(others=>'0'); aniso<=(others=>'0');rim<=(others=>'0');size<=(others=>'0');sx<=2;sy<=2;
    exmode<=to_unsigned(5,3);
    sfx<=(others=>'0'); sfy<=(others=>'0'); lfx<=(others=>'0'); lfy<=(others=>'0');
    rfx<=(others=>'0'); rfy<=(others=>'0');
    rst<='1';step;step;rst<='0';step;
    for f in 0 to 31 loop one_frame(f=0,0.55,scrape_energy); end loop;
    assert scrape_energy>0 and scrape_energy/=hard_energy
      report "musical_refine_tb: explicit scrape exciter had no distinct response" severity failure;

    -- HARDNESS must not hijack explicit non-mallet CHARACTER modes. With
    -- SCRAPE selected, enabling HARDNESS must be bit-identical to the legacy
    -- scrape envelope after reset.
    hardness<=x"80";rst<='1';step;step;rst<='0';step;
    for f in 0 to 31 loop one_frame(f=0,0.55,scrape_hard_energy); end loop;
    assert scrape_hard_energy=scrape_energy
      report "musical_refine_tb: HARDNESS altered explicit SCRAPE mode" severity failure;
    hardness<=(others=>'0');

    -- Same note/velocity twice without global reset: musical_poly advances its
    -- deterministic LFSR, varying strike level and pickup coordinates slightly.
    free_m<=false; rst<='1';step;step;rst<='0';step; exc<=to_q123(0.48); exen<='0';
    poly_strike(60); poly_frames(12,human_a);
    poly_strike(60); poly_frames(12,human_b);
    assert human_a>0 and human_b>0 report "musical_refine_tb: humanized poly strike silent" severity failure;
    assert human_a/=human_b report "musical_refine_tb: repeated musical strikes were identical" severity failure;

    report "musical_refine_tb: shaped strikes + HF damping bit-exact across backends; repeated-note micro-variation active"
      severity note;
    done<=true;finish;wait;
  end process;
  watchdog:process begin wait for 10 ms;assert done report "musical_refine_tb timeout" severity failure;wait;end process;
end architecture;
