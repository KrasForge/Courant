-------------------------------------------------------------------------------
-- mallet_tb.vhd - stateful physical mallet / HARDNESS acceptance (#87)
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
library work;
use work.fdtd_pkg.all;

entity mallet_tb is end;
architecture sim of mallet_tb is
  constant T:time:=10 ns;
  signal clk:std_logic:='0'; signal rst:std_logic:='1';
  signal step,trig,en:std_logic:='0';
  signal vel,surf,force_sig,hx,hv:q123_t:=Q123_ZERO;
  signal hard:unsigned(7 downto 0):=(others=>'0');
  signal contact,active:std_logic;
  signal m_rst,m_strobe,m_exen:std_logic:='1';
  signal m_exc:q123_t:=Q123_ZERO;
  signal coeffs:coeffs_t;
  signal sp_l,sp_r,tm_l,tm_r:q123_t; signal sp_v,tm_v:std_logic;
  signal done:boolean:=false;
begin
  clock:process begin
    while not done loop clk<='0';wait for T/2;clk<='1';wait for T/2;end loop;wait;
  end process;
  dut:entity work.physical_mallet
    port map(clk=>clk,rst=>rst,enable=>en,step=>step,trigger=>trig,
             strike_velocity=>vel,hardness=>hard,surface_u=>surf,
             force_out=>force_sig,contact=>contact,active=>active,
             hammer_x=>hx,hammer_v=>hv);

  spatial:entity work.grid_mesh
    generic map(NX=>8,NY=>8,FREE_BOUNDARY=>false)
    port map(clk=>clk,rst=>m_rst,strobe=>m_strobe,coeffs=>coeffs,
      mallet_enable=>'1',hardness_ctrl=>x"80",strike_x=>4,strike_y=>4,
      exc_in=>m_exc,exc_en=>m_exen,pick_l=>sp_l,pick_r=>sp_r,valid=>sp_v);
  folded:entity work.grid_mesh_tdm
    generic map(NX=>8,NY=>8,FREE_BOUNDARY=>false)
    port map(clk=>clk,rst=>m_rst,strobe=>m_strobe,coeffs=>coeffs,
      mallet_enable=>'1',hardness_ctrl=>x"80",strike_x=>4,strike_y=>4,
      exc_in=>m_exc,exc_en=>m_exen,pick_l=>tm_l,pick_r=>tm_r,valid=>tm_v);

  stim:process
    procedure tick is begin wait until rising_edge(clk);end;
    procedure reset_mallet is begin
      rst<='1';en<='1';step<='0';trig<='0';surf<=Q123_ZERO;
      tick;tick;rst<='0';tick;
    end;
    procedure run_contact(h:unsigned(7 downto 0); amplitude:real;
                          variable csteps:out natural; variable energy:out integer) is
      variable started:boolean:=false; variable quiet:natural:=0;
    begin
      reset_mallet; hard<=h;vel<=to_q123(amplitude);
      step<='1';trig<='1';tick;trig<='0';
      csteps:=0;energy:=0;
      for k in 0 to 1200 loop
        tick;
        if contact='1' then
          csteps:=csteps+1;started:=true;energy:=energy+abs(to_integer(force_sig));
        elsif started then
          quiet:=quiet+1; exit when active='0' and quiet>1;
        end if;
      end loop;
      step<='0';
      assert started and energy>0 report "mallet_tb: contact never started" severity failure;
      assert active='0' and force_sig=Q123_ZERO report "mallet_tb: mallet did not release cleanly" severity failure;
    end;

    procedure mesh_reset is begin
      m_rst<='1';m_strobe<='0';m_exen<='0';m_exc<=Q123_ZERO;
      tick;tick;m_rst<='0';tick;
    end;
    procedure mesh_step(first:boolean) is begin
      m_exc<=to_q123(0.55);
      if first then m_exen<='1';else m_exen<='0';end if;
      m_strobe<='1';tick;m_strobe<='0';m_exen<='0';
      wait until rising_edge(clk) and tm_v='1';
    end;
    variable cs,cm,ch,cvslow,cvfast:natural;
    variable es,em,eh,evs,evf:integer;
    variable f0,f1:q123_t;
    variable mesh_energy:integer:=0;
    file ft:text; variable fs:file_open_status; variable ln:line;
    variable gf,gc,ga,gx,gv:integer; variable trace_n:natural:=0;
  begin
    coeffs<=(gamma2=>to_q123(0.09),a0=>to_q123(0.9995),
             sigk1=>to_q123(0.9995),alpha=>Q123_ZERO,
             gamma2_max=>to_q123(0.451));

    run_contact(x"20",0.50,cs,es);
    run_contact(x"80",0.50,cm,em);
    run_contact(x"FF",0.50,ch,eh);
    assert cs>cm and cm>ch
      report "mallet_tb: HARDNESS did not shorten contact monotonically: "&
             integer'image(cs)&"/"&integer'image(cm)&"/"&integer'image(ch) severity failure;

    run_contact(x"80",0.20,cvslow,evs);
    run_contact(x"80",0.85,cvfast,evf);
    assert cvslow>cvfast
      report "mallet_tb: higher strike velocity did not shorten contact" severity failure;

    -- Independent Python fixed-point golden: medium HARDNESS, velocity 0.5.
    reset_mallet;hard<=x"80";vel<=to_q123(0.5);
    step<='1';trig<='1';tick;trig<='0';
    file_open(fs,ft,"../src/tb/mallet_trace.txt",read_mode);
    assert fs=open_ok report "mallet_tb: cannot open mallet_trace.txt" severity failure;
    readline(ft,ln); -- header
    trace_n:=0;
    while not endfile(ft) loop
      readline(ft,ln);read(ln,gf);read(ln,gc);read(ln,ga);read(ln,gx);read(ln,gv);
      tick;wait for 1 ps;trace_n:=trace_n+1;
      assert to_integer(force_sig)=gf and to_integer(hx)=gx and to_integer(hv)=gv
        report "mallet_tb: golden force/state mismatch at sample "&integer'image(trace_n)&
               " got F/X/V="&integer'image(to_integer(force_sig))&"/"&integer'image(to_integer(hx))&"/"&integer'image(to_integer(hv))&
               " expected "&integer'image(gf)&"/"&integer'image(gx)&"/"&integer'image(gv) severity failure;
      assert (contact='1')=(gc=1) and (active='1')=(ga=1)
        report "mallet_tb: golden contact/active mismatch at sample "&integer'image(trace_n) severity failure;
    end loop;
    file_close(ft);step<='0';
    assert trace_n>100 report "mallet_tb: golden trace unexpectedly short" severity failure;

    -- Bidirectional dependency: changing the surface position changes contact
    -- force even though hammer state/HARDNESS are otherwise untouched.
    reset_mallet;hard<=x"80";vel<=to_q123(0.5);step<='1';trig<='1';tick;trig<='0';
    for k in 0 to 80 loop tick;exit when contact='1';end loop;
    assert contact='1' severity failure;
    f0:=force_sig; surf<=to_q123(0.01); wait for 1 ns; f1:=force_sig;
    assert f1/=f0 report "mallet_tb: surface displacement did not feed back into contact force" severity failure;
    step<='0';en<='0';tick;

    -- If contact is made impossible, MAX_AGE must still terminate the state
    -- machine with zero output rather than leaving a stuck active/DC exciter.
    reset_mallet;hard<=x"80";vel<=to_q123(0.10);step<='1';trig<='1';tick;trig<='0';
    surf<=to_q123(0.90);
    for k in 0 to 2060 loop tick; end loop;
    assert active='0' and force_sig=Q123_ZERO
      report "mallet_tb: no-contact timeout failed" severity failure;
    step<='0';en<='0';tick;surf<=Q123_ZERO;

    -- Full mesh integration: same stateful mallet must drive both backends
    -- identically and continue injecting after the one-cycle trigger is gone.
    mesh_reset;
    for k in 0 to 159 loop
      mesh_step(k=0);
      assert sp_l=tm_l and sp_r=tm_r
        report "mallet_tb: spatial/TDM physical-mallet mismatch at step "&integer'image(k) severity failure;
      mesh_energy:=mesh_energy+abs(to_integer(tm_l))+abs(to_integer(tm_r));
    end loop;
    assert mesh_energy>0 report "mallet_tb: integrated physical mallet was silent" severity failure;

    report "mallet_tb: HARDNESS/velocity contact ordering, release, feedback and backend parity passed" severity note;
    done<=true;finish;wait;
  end process;
  watchdog:process begin wait for 10 ms;assert done report "mallet_tb timeout" severity failure;wait;end process;
end architecture;
