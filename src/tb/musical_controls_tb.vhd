-- End-to-end differential acceptance: only one control differs between DUTs.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all; use work.fdtd_pkg.all;
entity musical_controls_tb is end;
architecture sim of musical_controls_tb is
 signal clk,mclk: std_logic:='0'; signal rst:std_logic:='1'; signal midi:std_logic:='1';
 signal we:std_logic:='0'; signal wa:unsigned(3 downto 0):=(others=>'0');
 signal wd:std_logic_vector(23 downto 0):=(others=>'0');
 signal ba,bb,sa,sb,da,db,va,vb:std_logic;
 signal la,ra,lb,rb:q123_t;
 signal measuring:boolean:=false;
 signal changed,sounded,clipped:boolean:=false;
begin
 clk<=not clk after 5 ns; mclk<=not mclk after 41 ns;
 a:entity work.synth_top generic map(NVOICES=>1,NX=>8,NY=>8,OS=>4,TIME_MUX=>true,CLK_HZ=>1_000_000)
 port map(sys_clk=>clk,sys_rst=>rst,mclk=>mclk,midi_rx=>midi,cfg_rd_data=>open,
 codec_mclk=>open,codec_bclk=>ba,codec_lrclk=>sa,sd_tx=>da,active=>open);
 b:entity work.synth_top generic map(NVOICES=>1,NX=>8,NY=>8,OS=>4,TIME_MUX=>true,CLK_HZ=>1_000_000)
 port map(sys_clk=>clk,sys_rst=>rst,mclk=>mclk,midi_rx=>midi,cfg_rd_data=>open,
 cfg_wr_en=>we,cfg_wr_addr=>wa,cfg_wr_data=>wd,
 codec_mclk=>open,codec_bclk=>bb,codec_lrclk=>sb,sd_tx=>db,active=>open);
 ca:entity work.i2s_transceiver port map(rst=>rst,bclk=>ba,lrclk=>sa,sd_rx=>da,sd_tx=>open,
 rx_l=>la,rx_r=>ra,rx_valid=>va,tx_l=>Q123_ZERO,tx_r=>Q123_ZERO);
 cb:entity work.i2s_transceiver port map(rst=>rst,bclk=>bb,lrclk=>sb,sd_rx=>db,sd_tx=>open,
 rx_l=>lb,rx_r=>rb,rx_valid=>vb,tx_l=>Q123_ZERO,tx_r=>Q123_ZERO);
 monitor:process begin
  wait until rising_edge(ba); wait for 1 ps; -- allow both loopback decoders to settle
  if rst='1' then changed<=false;sounded<=false;clipped<=false;
  elsif measuring and va='1' then
   assert vb='1' report "Differential I2S decoders lost frame alignment" severity failure;
   assert not is_x(std_logic_vector(la & ra & lb & rb)) severity failure;
   if la/=lb or ra/=rb then changed<=true; end if;
   if la/=0 and lb/=0 then sounded<=true; end if;
   if la=Q123_MIN or la=Q123_MAX or lb=Q123_MIN or lb=Q123_MAX then clipped<=true; end if;
  end if;
 end process;
 process
  procedure ticks(n:positive) is begin for k in 1 to n loop wait until falling_edge(clk);end loop;end;
  procedure wr(addr:natural;value:real) is begin
   wa<=to_unsigned(addr,4);wd<=std_logic_vector(to_q123(value));we<='1';ticks(2);we<='0';ticks(2);
  end;
  procedure send(v:natural) is begin
   midi<='0';ticks(32);
   for k in 0 to 7 loop
    if (v/2**k) mod 2=1 then midi<='1';else midi<='0';end if;ticks(32);
   end loop;
   midi<='1';ticks(64);
  end;
  procedure frames(n:positive) is begin
   for k in 1 to n loop wait until rising_edge(ba) and va='1';end loop;
  end;
 begin
  for test in 0 to 7 loop
   measuring<=false;rst<='1';we<='0';ticks(100);rst<='0';ticks(100);
   case test is
    when 1=>wr(0,0.5); -- tension, not just a disconnected register
    when 2=>wr(3,0.4); -- independently set CHAOS at identical note velocity
    when 3=>wa<=x"5";wd<=x"000000";we<='1';ticks(2);we<='0'; -- left pickup
    when 4=>wa<=x"9";wd<=x"000001";we<='1';ticks(2);we<='0'; -- boundary
    when 5=>wr(1,0.9998);wr(2,0.9998); -- decay
    when 6=>wa<=x"5";wd<=x"600002";we<='1';ticks(2);we<='0'; -- STIFFNESS=0x60, keep L pickup X=2
    when 7=>wa<=x"6";wd<=x"800004";we<='1';ticks(2);we<='0'; -- HARDNESS=0x80, physical mallet, keep L pickup Y=4
    when others=>null;
   end case;
   ticks(10);send(16#90#);send(57);send(96);
   frames(8); -- flush reset/CDC/I2S startup pipeline before strict measurement
   measuring<=true;frames(96);measuring<=false;ticks(10);
   assert sounded report "Control acceptance produced silence" severity failure;
   assert not clipped report "Control acceptance clipped output" severity failure;
   if test=0 then
    assert not changed report "Identical DUTs differ" severity failure;
   else
    assert changed report "Control did not reach audio: case "&integer'image(test) severity failure;
   end if;
   report "musical_controls_tb: control case "&integer'image(test)&" passed through I2S";
  end loop;
  finish;wait;
 end process;
 process begin wait for 100 ms;assert false report "musical_controls_tb watchdog" severity failure;wait;end process;
end;
