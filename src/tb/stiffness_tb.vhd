-------------------------------------------------------------------------------
-- stiffness_tb.vhd - runtime bending-stiffness / plate integration (#86)
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
library work;
use work.fdtd_pkg.all;
use work.physical_pkg.all;

entity stiffness_tb is end;
architecture sim of stiffness_tb is
  constant T:time:=10 ns;
  constant NX:positive:=8; constant NY:positive:=8;
  signal clk:std_logic:='0'; signal rst:std_logic:='1';
  signal strobe:std_logic:='0'; signal exc_en:std_logic:='0';
  signal exc:q123_t:=Q123_ZERO; signal coeffs:coeffs_t;
  signal stiff,rim:unsigned(7 downto 0):=(others=>'0');
  signal free_mode:boolean:=false;
  signal sl,sr,tl,tr,ml,mr:q123_t;
  signal sv,tv,mv:std_logic; signal done:boolean:=false;
begin
  clock:process begin
    while not done loop clk<='0';wait for T/2;clk<='1';wait for T/2;end loop;
    wait;
  end process;
  watchdog:process begin wait for 5 ms;
    assert done report "stiffness_tb timeout" severity failure; wait;
  end process;

  spatial:entity work.grid_mesh
    generic map(NX=>NX,NY=>NY,FREE_BOUNDARY=>false)
    port map(clk=>clk,rst=>rst,strobe=>strobe,coeffs=>coeffs,
      free_mode=>free_mode,rim_ctrl=>rim,stiffness_ctrl=>stiff,exc_in=>exc,exc_en=>exc_en,
      pick_l=>sl,pick_r=>sr,valid=>sv);

  folded:entity work.grid_mesh_tdm
    generic map(NX=>NX,NY=>NY,FREE_BOUNDARY=>false)
    port map(clk=>clk,rst=>rst,strobe=>strobe,coeffs=>coeffs,
      free_mode=>free_mode,rim_ctrl=>rim,stiffness_ctrl=>stiff,exc_in=>exc,exc_en=>exc_en,
      pick_l=>tl,pick_r=>tr,valid=>tv);

  membrane:entity work.grid_mesh_tdm
    generic map(NX=>NX,NY=>NY,FREE_BOUNDARY=>false)
    port map(clk=>clk,rst=>rst,strobe=>strobe,coeffs=>coeffs,
      free_mode=>free_mode,rim_ctrl=>rim,stiffness_ctrl=>(others=>'0'),exc_in=>exc,exc_en=>exc_en,
      pick_l=>ml,pick_r=>mr,valid=>mv);

  stim:process
    procedure tick is begin wait until rising_edge(clk); end;
    procedure reset_mesh is begin
      rst<='1'; strobe<='0'; exc_en<='0'; exc<=Q123_ZERO;
      tick;tick; rst<='0';tick;
    end;
    procedure fire(first:boolean) is begin
      strobe<='1';
      if first then exc<=to_q123(0.9);exc_en<='1';end if;
      tick;strobe<='0';exc_en<='0';exc<=Q123_ZERO;
      wait until rising_edge(clk) and tv='1';
    end;
    procedure fire_count(first:boolean; variable cycles:out natural) is begin
      strobe<='1';
      if first then exc<=to_q123(0.9);exc_en<='1';end if;
      tick;strobe<='0';exc_en<='0';exc<=Q123_ZERO;cycles:=0;
      loop
        tick;cycles:=cycles+1;
        exit when tv='1';
      end loop;
    end;
    variable changed:boolean:=false;
    variable b:acc_t; variable c:unsigned(7 downto 0);
    variable lim:q123_t;
    file ft:text; variable fs:file_open_status; variable ln:line;
    variable gl,gr:integer; variable cyc:natural;
  begin

    -- Production control encoding and shift/add stiffness multiply are exact.
    assert stiffness_mu2(x"00")=Q123_ZERO severity failure;
    assert stiffness_mu2(x"FF")=shift_left(to_signed(255,Q_BITS),11)
      report "stiffness_tb: mu2 encoding mismatch" severity failure;
    assert stiff_gamma2_max(to_q123(0.451),x"00")=to_q123(0.451)
      report "stiffness_tb: zero-stiffness clamp changed legacy ceiling" severity failure;
    assert stiff_gamma2_max(to_q123(0.451),x"80")=to_q123(0.25)
      report "stiffness_tb: combined CFL ceiling wrong at STIFFNESS=128" severity failure;

    b:=biharmonic_term(to_q123(0.12),to_q123(-0.04),to_q123(0.03),
       to_q123(0.08),to_q123(-0.02),to_q123(0.01),to_q123(-0.07),
       to_q123(0.05),to_q123(0.02),to_q123(-0.03),to_q123(0.06),
       to_q123(0.04),to_q123(-0.05));
    for k in 0 to 3 loop
      case k is
        when 0=>c:=x"01"; when 1=>c:=x"40";
        when 2=>c:=x"7F"; when others=>c:=x"FF";
      end case;
      assert stiffness_term(b,c)=mul_coeff(stiffness_mu2(c),b)
        report "stiffness_tb: shift/add stiffness multiply mismatch" severity failure;
    end loop;

    -- Moderate plate: spatial and TDM must remain bit-exact, while nonzero
    -- stiffness must audibly/numerically differ from the membrane path.

    coeffs <= (gamma2=>to_q123(0.08),a0=>to_q123(0.9995),
               sigk1=>to_q123(0.9995),alpha=>to_q123(0.10),
               gamma2_max=>to_q123(0.451));
    stiff<=x"60"; reset_mesh; changed:=false;
    file_open(fs,ft,"../src/tb/stiffness_trace.txt",read_mode);
    assert fs=open_ok report "stiffness_tb: cannot open stiffness_trace.txt" severity failure;
    readline(ft,ln); -- header
    for k in 0 to 59 loop
      if k=0 then
        fire_count(true,cyc);
        assert cyc=322 report "stiffness_tb: 8x8 stiff TDM step cycle budget changed, got "&integer'image(cyc) severity failure;
      else fire(false); end if;
      readline(ft,ln);read(ln,gl);read(ln,gr);
      assert to_integer(tl)=gl and to_integer(tr)=gr
        report "stiffness_tb: RTL/reference mismatch at step "&integer'image(k) severity failure;
      assert sl=tl and sr=tr
        report "stiffness_tb: spatial/TDM plate mismatch at step "&integer'image(k)
        severity failure;
      assert not is_x(std_logic_vector(tl&tr))
        report "stiffness_tb: X in plate response" severity failure;
      if tl/=ml or tr/=mr then changed:=true;end if;
    end loop;
    file_close(ft);
    assert changed
      report "stiffness_tb: nonzero STIFFNESS did not change the membrane response"
      severity failure;

    -- Near-pure-plate control at an intentionally unsafe requested wave speed.
    -- The runtime combined CFL clamp must reduce g2 so the state stays usable.
    coeffs <= (gamma2=>to_q123(0.45),a0=>to_q123(0.999),
               sigk1=>to_q123(0.999),alpha=>to_q123(0.40),
               gamma2_max=>to_q123(0.451));
    stiff<=x"E0"; reset_mesh;
    lim:=stiff_gamma2_max(to_q123(0.451),x"E0");
    assert lim<to_q123(0.07)
      report "stiffness_tb: high stiffness did not reserve CFL headroom" severity failure;

    for k in 0 to 119 loop
      fire(k=0);
      assert sl=tl and sr=tr
        report "stiffness_tb: high-stiffness backend mismatch at step "&integer'image(k)
        severity failure;
      if k>8 then
        assert tl/=Q123_MAX and tl/=Q123_MIN and tr/=Q123_MAX and tr/=Q123_MIN
          report "stiffness_tb: high-stiffness state pinned to saturation" severity failure;
      end if;
    end loop;

    -- The wider boundary sampler must also stay identical between backends
    -- for the existing compliant/free rim semantics.
    coeffs <= (gamma2=>to_q123(0.08),a0=>to_q123(0.999),
               sigk1=>to_q123(0.999),alpha=>Q123_ZERO,
               gamma2_max=>to_q123(0.451));
    stiff<=x"40";rim<=x"FF";free_mode<=true;reset_mesh;
    for k in 0 to 29 loop
      fire(k=0);
      assert sl=tl and sr=tr
        report "stiffness_tb: free/compliant plate backend mismatch at step "&integer'image(k)
        severity failure;
    end loop;
    free_mode<=false;rim<=(others=>'0');

    report "stiffness_tb: control encoding, golden trace, dispersion, CFL clamp and backend parity passed"
      severity note;
    done<=true;finish;wait;
  end process;
end architecture;
