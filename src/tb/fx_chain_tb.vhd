-------------------------------------------------------------------------------
-- fx_chain_tb.vhd - smoke/integration tests for the onboard stereo FX chain.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
library work;
use work.fdtd_pkg.all;

entity fx_chain_tb is end entity;

architecture sim of fx_chain_tb is
  constant T : time := 10 ns;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal vin : std_logic := '0';
  signal il,ir,ol,orx : q123_t := Q123_ZERO;
  signal vout : std_logic;
  signal c0,c1,c2,c3,c4,c5 : std_logic_vector(23 downto 0) := (others=>'0');
  signal done : boolean := false;
begin
  clock : process begin
    while not done loop clk<='0'; wait for T/2; clk<='1'; wait for T/2; end loop; wait;
  end process;

  dut : entity work.fx_chain
    port map(clk=>clk,rst=>rst,valid_in=>vin,in_l=>il,in_r=>ir,
             ctrl0=>c0,ctrl1=>c1,ctrl2=>c2,ctrl3=>c3,ctrl4=>c4,ctrl5=>c5,
             out_l=>ol,out_r=>orx,valid_out=>vout);

  watchdog : process begin
    wait for 20 ms; assert done report "fx_chain_tb timeout" severity failure; wait;
  end process;

  stim : process
    procedure step is begin wait until rising_edge(clk); end procedure;
    procedure push(lv,rv : integer; variable lo,ro : out integer) is
      variable guard : integer := 0;
    begin
      il<=to_signed(lv,24); ir<=to_signed(rv,24); vin<='1'; step; vin<='0';
      loop
        step; guard:=guard+1;
        exit when vout='1';
        assert guard<100 report "fx_chain_tb: pipeline failed to return valid" severity failure;
      end loop;
      lo:=to_integer(ol); ro:=to_integer(orx);
    end procedure;
    procedure settle_master is
      variable a,b : integer;
    begin
      for i in 1 to 132 loop push(0,0,a,b); end loop;
    end procedure;
    variable l,r,first_l,fade_l : integer;
    variable polish_changed : boolean := false;
    variable chorus_seen, echo_seen, sync_seen, triplet_seen, tail_seen : boolean := false;
  begin
    rst<='1'; step; step; rst<='0'; step;

    -- Master bypass must be bit-exact even though samples traverse the pipeline.
    push(1000000,-500000,l,r);
    assert l=1000000 and r=-500000
      report "fx_chain_tb: master bypass is not bit exact" severity failure;

    -- Master may be on while POLISH remains zero; the new bus block itself
    -- must then be bit-exact when all other effects are disabled.
    c0<=x"800000"; c3<=(others=>'0'); c5<=x"0000FF";
    push(900000,-450000,l,r);
    assert l=900000 and r=-450000
      report "fx_chain_tb: POLISH=0 is not bit exact" severity failure;

    -- Drive only: verify that a moderate positive sample is audibly reshaped.
    c0<=x"C20000"; -- master + drive, amount 128
    c5<=x"0000FF"; -- unity output trim
    -- Parameter edits slew at 2 LSB/sample: the first changed sample must be
    -- gentler than the settled drive value rather than a one-sample jump.
    push(2500000,2500000,l,r); first_l:=l;
    for i in 0 to 70 loop push(2500000,2500000,l,r); end loop;
    assert l>first_l and l>2500000 and r>2500000
      report "fx_chain_tb: smoothed drive did not settle progressively" severity failure;

    -- Global master-off crossfades, then reaches an exact dry bypass.
    c0<=x"400000"; -- drive bit left set, master cleared
    push(2500000,2500000,l,r); fade_l:=l;
    assert fade_l/=2500000 report "fx_chain_tb: master bypass hard-jumped instead of fading" severity failure;
    for i in 0 to 140 loop push(2500000,2500000,l,r); end loop;
    assert l=2500000 and r=2500000
      report "fx_chain_tb: master fade did not converge to bit-exact dry" severity failure;

    -- Tone only: a bright setting must alter a fresh broadband-ish sample.
    rst<='1'; step; step; rst<='0'; step;
    c0<=x"A003FC"; c1<=(others=>'0'); c5<=x"0000FF";
    settle_master;
    push(1000000,1000000,l,r);
    assert l/=1000000 and r/=1000000
      report "fx_chain_tb: tone control did not alter signal" severity failure;

    -- Chorus only: fixed 240-sample pure-wet short delay must return the impulse.
    rst<='1'; step; step; rst<='0'; step;
    c0<=x"900000"; c1<=x"0000FF"; c2<=(others=>'0'); c3<=(others=>'0');
    c4<=(others=>'0'); c5<=x"0000FF";
    settle_master;
    push(1600000,0,l,r);
    for i in 1 to 245 loop
      push(0,0,l,r);
      if abs(l)>100000 or abs(r)>100000 then chorus_seen:=true; end if;
    end loop;
    assert chorus_seen report "fx_chain_tb: chorus delay produced no wet return" severity failure;

    -- Reset state, then exercise a four-sample pure-wet delay.
    rst<='1'; step; step; rst<='0'; step;
    c0<=x"880000"; c2<=x"0004FF"; c3<=x"000000"; c5<=x"0000FF";
    settle_master;
    push(1600000,0,l,r);
    for i in 1 to 4 loop
      push(0,0,l,r);
      if abs(l)>100000 or abs(r)>100000 then echo_seen:=true; end if;
    end loop;
    assert echo_seen report "fx_chain_tb: short delay produced no echo" severity failure;

    -- Tempo-grid mode: 180 BPM, 1/16 = 4000 samples at 48 kHz. The high bit
    -- selects sync mode; raw-sample presets keep bit 23 clear and are unchanged.
    rst<='1'; step; step; rst<='0'; step;
    c0<=x"880000"; c2<=x"F800FF"; c3<=x"000000"; c5<=x"0000FF";
    settle_master;
    push(1600000,0,l,r);
    for i in 1 to 4004 loop
      push(0,0,l,r);
      if i>=3996 and abs(l)>100000 then sync_seen:=true; end if;
    end loop;
    assert sync_seen report "fx_chain_tb: tempo-synced 1/16 delay did not land near 4000 samples" severity failure;

    -- Same 180 BPM clock, 1/8-triplet code 6 -> floor(16000/3)=5333 samples.
    rst<='1'; step; step; rst<='0'; step;
    c0<=x"880000"; c2<=x"F8C0FF"; c3<=x"000000"; c5<=x"0000FF";
    settle_master;
    push(1600000,0,l,r);
    for i in 1 to 5337 loop
      push(0,0,l,r);
      if i>=5329 and abs(l)>100000 then triplet_seen:=true; end if;
    end loop;
    assert triplet_seen report "fx_chain_tb: tempo-synced triplet delay did not land near 5333 samples" severity failure;

    -- Reverb: smallest room must produce a delayed FDN tail after an impulse.
    rst<='1'; step; step; rst<='0'; step;
    c0<=x"840000"; c2<=(others=>'0'); c3<=(others=>'0');
    c4<=x"C040FF"; c5<=x"0080FF";
    settle_master;
    push(1600000,1600000,l,r);
    for i in 1 to 260 loop
      push(0,0,l,r);
      if abs(l)>1000 or abs(r)>1000 then tail_seen:=true; end if;
    end loop;
    assert tail_seen report "fx_chain_tb: FDN produced no reverberant tail" severity failure;

    -- POLISH uses the formerly-unused low seven bits of ctrl3.  With the
    -- ordinary effects bypassed it must still reshape/make up a small AC tone.
    rst<='1'; step; step; rst<='0'; step;
    c0<=x"800000"; c1<=(others=>'0'); c2<=(others=>'0');
    c3<=x"000040"; c4<=(others=>'0'); c5<=x"0000FF";
    settle_master;
    for i in 0 to 95 loop
      if (i mod 2)=0 then push(120000,-120000,l,r);
      else push(-120000,120000,l,r); end if;
      if abs(l)>130000 or abs(r)>130000 then polish_changed:=true; end if;
    end loop;
    assert polish_changed report "fx_chain_tb: POLISH bus stage did not reshape/make up signal" severity failure;

    report "fx_chain_tb: bypass, drive, tone, chorus, delay, FDN and POLISH checks passed" severity note;
    done<=true; finish;
  end process;
end architecture;
