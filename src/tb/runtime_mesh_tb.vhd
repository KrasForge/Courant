library ieee;use ieee.std_logic_1164.all;use ieee.numeric_std.all;
use std.env.all;use work.fdtd_pkg.all;
entity runtime_mesh_tb is end;
architecture sim of runtime_mesh_tb is
 signal clk:std_logic:='0'; signal rst:std_logic:='1';signal go,exc:std_logic:='0';
 signal free:boolean:=false;signal lx,ly,rx,ry:natural range 0 to 7:=2;
 signal al,ar,bl,br:q123_t;signal av,bv:std_logic;
 constant c:coeffs_t:=(to_q123(0.02),to_q123(0.9999),to_q123(0.9999),Q123_ZERO,to_q123(0.451));
begin
 clk<=not clk after 5 ns;
 a:entity work.mesh generic map(NX=>8,NY=>8,TIME_MUX=>false,EXC_X=>2,EXC_Y=>2,BALANCED_FREE_STRIKE=>true)
 port map(clk=>clk,rst=>rst,strobe=>go,coeffs=>c,exc_in=>to_q123(0.002),exc_en=>exc,
 free_mode=>free,tap_lx=>lx,tap_ly=>ly,tap_rx=>rx,tap_ry=>ry,pick_l=>al,pick_r=>ar,valid=>av);
 b:entity work.mesh generic map(NX=>8,NY=>8,TIME_MUX=>true,EXC_X=>2,EXC_Y=>2,BALANCED_FREE_STRIKE=>true)
 port map(clk=>clk,rst=>rst,strobe=>go,coeffs=>c,exc_in=>to_q123(0.002),exc_en=>exc,
 free_mode=>free,tap_lx=>lx,tap_ly=>ly,tap_rx=>rx,tap_ry=>ry,pick_l=>bl,pick_r=>br,valid=>bv);
 process
  variable seen_a,seen_b:boolean;variable va_l,va_r,vb_l,vb_r:q123_t;
 begin
  for mode in boolean loop
   rst<='1';wait for 100 ns;wait until falling_edge(clk);rst<='0';free<=mode;
   for step in 0 to 95 loop
    lx<=step mod 8;ly<=(step/8) mod 8;rx<=7-step mod 8;ry<=3;
    if step=0 then exc<='1';else exc<='0';end if;
    wait until falling_edge(clk);go<='1';wait until falling_edge(clk);go<='0';
    seen_a:=false;seen_b:=false;
    for k in 0 to 100 loop
     wait until rising_edge(clk);
     if av='1' then seen_a:=true;va_l:=al;va_r:=ar;end if;
     if bv='1' then seen_b:=true;vb_l:=bl;vb_r:=br;end if;
     exit when seen_a and seen_b;
    end loop;
    assert seen_a and seen_b report "Mesh handshake timeout" severity failure;
    assert va_l=vb_l and va_r=vb_r report "Runtime boundary/pickup backends differ" severity failure;
    wait until falling_edge(clk);
   end loop;
  end loop;
  report "runtime_mesh_tb: 192 dynamic-pickup steps, fixed and balanced-free, bit-exact across backends";
  finish;wait;
 end process;
 process begin wait for 1 ms;assert false report "watchdog" severity failure;wait;end process;
end;
