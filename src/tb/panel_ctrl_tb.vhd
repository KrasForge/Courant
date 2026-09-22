library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
library work;
use work.fdtd_pkg.all;

entity panel_ctrl_tb is end;
architecture sim of panel_ctrl_tb is
  constant T:time:=10 ns; constant POT_W:positive:=12;
  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal mode:std_logic:='0';
  signal p0,p1,p2,p3,p4,p5:unsigned(POT_W-1 downto 0):=(others=>'0');
  signal ea,eb,btn:std_logic:='0';
  signal we:std_logic; signal wa,ra:unsigned(3 downto 0);
  signal wd,rd:std_logic_vector(23 downto 0);
  signal pi:unsigned(3 downto 0);signal recall,save:std_logic;
  signal edit_page:unsigned(1 downto 0); signal edit_leds:std_logic_vector(3 downto 0);
  signal c:coeffs_t; signal phys,fx0,fx1,fx2,fx3,fx4,fx5:std_logic_vector(23 downto 0);
  signal rim,ss,sx,sy:unsigned(7 downto 0);
  signal done:boolean:=false; signal recalls,saves:integer:=0;
begin
  clock:process begin while not done loop clk<='0';wait for T/2;clk<='1';wait for T/2;end loop;wait;end process;
  watchdog:process begin wait for 4 ms;assert done report "panel_ctrl_tb timeout" severity failure;wait;end process;

  -- Three pages exercise the generic page selector. Only page 0 (SURFACE) is
  -- populated by issue #85; pages 1/2 must be inert until later features land.
  dut:entity work.panel_ctrl
    generic map(POT_W=>POT_W,N_PRESETS=>7,N_EDIT_PAGES=>3,DEADBAND=>4096,LONG_CYC=>200)
    port map(clk=>clk,rst=>rst,edit_mode=>mode,pot_pitch=>p0,pot_decay=>p1,pot_timbre=>p2,
      pot_drive=>p3,pot_delay=>p4,pot_reverb=>p5,enc_a=>ea,enc_b=>eb,enc_btn=>btn,
      cfg_wr_en=>we,cfg_wr_addr=>wa,cfg_wr_data=>wd,cfg_rd_addr=>ra,cfg_rd_data=>rd,
      preset_index=>pi,preset_recall=>recall,preset_save=>save,
      edit_page=>edit_page,edit_leds=>edit_leds);
  bank:entity work.preset_bank
    port map(clk=>clk,rst=>rst,wr_en=>we,wr_addr=>wa,wr_data=>wd,rd_addr=>ra,rd_data=>rd,
      preset_index=>pi,recall=>recall,save=>save,coeffs=>c,pick_lx=>open,pick_ly=>open,
      pick_rx=>open,pick_ry=>open,free_boundary=>open,physical_ctrl=>phys,
      rim_ctrl=>rim,strike_size=>ss,strike_x_ctrl=>sx,strike_y_ctrl=>sy,
      stiffness_ctrl=>open,hardness_ctrl=>open,
      fx_ctrl0=>fx0,fx_ctrl1=>fx1,fx_ctrl2=>fx2,fx_ctrl3=>fx3,fx_ctrl4=>fx4,fx_ctrl5=>fx5);
  mon:process(clk) begin if rising_edge(clk) then if recall='1' then recalls<=recalls+1;end if;
    if save='1' then saves<=saves+1;end if;end if;end process;

  stim:process
    procedure step is begin wait until rising_edge(clk);end;
    procedure settle is begin for i in 1 to 140 loop step;end loop;end;
    procedure enc(up:boolean) is begin eb<='0' when up else '1';step;ea<='1';for i in 1 to 6 loop step;end loop;
      ea<='0';for i in 1 to 6 loop step;end loop;end;
    procedure short_press is begin btn<='1';for i in 1 to 20 loop step;end loop;btn<='0';settle;end;
    procedure long_press is begin btn<='1';for i in 1 to 260 loop step;end loop;btn<='0';settle;end;
    variable g_hold:signed(23 downto 0); variable f_hold:std_logic_vector(23 downto 0);
    variable phys_hold:std_logic_vector(23 downto 0);
    variable rim_hold,ss_hold,sx_hold,sy_hold:unsigned(7 downto 0);
    variable pi_hold:unsigned(3 downto 0);
  begin
    rst<='1';for i in 1 to 10 loop step;end loop;rst<='0';settle;
    assert edit_page=0 and edit_leds="0000" report "panel_ctrl_tb: reset page/LED state failed" severity failure;
    assert c.gamma2=to_q123(0.09) report "panel_ctrl_tb: boot moved TENSION before pickup" severity failure;
    assert fx0=x"FC6200" and fx2=x"2EE040" and fx4=x"D26446"
      report "panel_ctrl_tb: boot moved FX before pickup" severity failure;

    -- PLAY: sweep across stored values to arm, then controls track.
    p0<=to_unsigned(4095,POT_W);settle;
    assert c.gamma2>to_q123(0.9) report "panel_ctrl_tb: TENSION soft takeover/write failed" severity failure;
    p1<=to_unsigned(4095,POT_W);settle;
    assert c.a0=c.sigk1 and c.sigk1>to_q123(0.9999) report "panel_ctrl_tb: DECAY failed" severity failure;
    p2<=to_unsigned(4095,POT_W);settle;
    assert c.alpha>to_q123(0.3) report "panel_ctrl_tb: CHAOS failed" severity failure;
    p3<=to_unsigned(4095,POT_W);p4<=to_unsigned(2048,POT_W);p5<=to_unsigned(4095,POT_W);settle;
    assert unsigned(fx0(17 downto 10))=255 and unsigned(fx2(7 downto 0))=128 and unsigned(fx4(7 downto 0))=255
      report "panel_ctrl_tb: PLAY FX layer failed" severity failure;

    -- Enter EDIT/SURFACE. Merely switching must not edit anything.
    p0<=to_unsigned(2048,POT_W);p1<=(others=>'0');p2<=(others=>'0');
    p3<=(others=>'0');p4<=(others=>'0');p5<=(others=>'0');settle;
    g_hold:=c.gamma2;f_hold:=fx0;mode<='1';settle;
    assert edit_page=0 and edit_leds="0001" report "panel_ctrl_tb: SURFACE page indication failed" severity failure;
    assert c.gamma2=g_hold and fx0=f_hold and phys(10 downto 4)="0000000" and rim=0 and ss=0 and sx=0 and sy=0
      report "panel_ctrl_tb: PLAY->EDIT switch caused parameter jump" severity failure;

    -- SURFACE page: ANISO/RIM/SIZE/X/Y/CHARACTER.
    p0<=to_unsigned(4095,POT_W);p1<=to_unsigned(4095,POT_W);p2<=to_unsigned(3072,POT_W);
    p3<=to_unsigned(1024,POT_W);p4<=to_unsigned(2048,POT_W);p5<=to_unsigned(1536,POT_W);settle;
    assert signed(phys(10 downto 7))=to_signed(7,4) report "panel_ctrl_tb: ANISO failed" severity failure;
    assert rim=255 and ss=192 and sx=64 and sy=128 report "panel_ctrl_tb: RIM/SIZE/STRIKE XY failed" severity failure;
    assert unsigned(phys(6 downto 4))=3 report "panel_ctrl_tb: CHARACTER failed" severity failure;

    -- In EDIT the encoder changes page, never preset. Reserved pages are inert.
    phys_hold:=phys;rim_hold:=rim;ss_hold:=ss;sx_hold:=sx;sy_hold:=sy;pi_hold:=pi;
    enc(true);
    assert edit_page=1 and edit_leds="0010" and pi=pi_hold
      report "panel_ctrl_tb: encoder did not select EDIT page 1 cleanly" severity failure;
    p0<=(others=>'0');p1<=(others=>'0');p2<=(others=>'0');p3<=to_unsigned(4095,POT_W);
    p4<=to_unsigned(4095,POT_W);p5<=to_unsigned(4095,POT_W);settle;
    assert phys=phys_hold and rim=rim_hold and ss=ss_hold and sx=sx_hold and sy=sy_hold
      report "panel_ctrl_tb: reserved EDIT page aliased SURFACE controls" severity failure;

    short_press; long_press;
    assert recalls=0 and saves=0 and pi=pi_hold
      report "panel_ctrl_tb: EDIT button gesture leaked into preset recall/save" severity failure;

    -- A press that begins in EDIT must not turn into a preset action if MODE is
    -- flipped to PLAY before the button is released.
    btn<='1';for i in 1 to 20 loop step;end loop;mode<='0';settle;
    btn<='0';settle;
    assert recalls=0 and saves=0 and pi=pi_hold
      report "panel_ctrl_tb: EDIT-held button leaked after return to PLAY" severity failure;
    mode<='1';settle;
    assert edit_page=1 and edit_leds="0010" report "panel_ctrl_tb: page memory lost across held-button transition" severity failure;

    enc(true);
    assert edit_page=2 and edit_leds="0100" and pi=pi_hold
      report "panel_ctrl_tb: encoder did not select EDIT page 2" severity failure;
    enc(true);
    assert edit_page=0 and edit_leds="0001" report "panel_ctrl_tb: forward page wrap failed" severity failure;
    settle;
    assert phys=phys_hold and rim=rim_hold and ss=ss_hold and sx=sx_hold and sy=sy_hold
      report "panel_ctrl_tb: page return bypassed soft takeover" severity failure;
    enc(false);
    assert edit_page=2 and edit_leds="0100" report "panel_ctrl_tb: reverse page wrap failed" severity failure;

    -- Page selection is remembered while PLAY hides the page LEDs.
    mode<='0';settle;
    assert edit_page=2 and edit_leds="0000" report "panel_ctrl_tb: PLAY did not retain/hide EDIT page" severity failure;
    assert c.gamma2=g_hold and fx0=f_hold report "panel_ctrl_tb: EDIT->PLAY switch jumped controls" severity failure;
    mode<='1';settle;
    assert edit_page=2 and edit_leds="0100" report "panel_ctrl_tb: EDIT page memory failed" severity failure;
    enc(true); -- page 2 -> page 0 for later checks
    assert edit_page=0 and edit_leds="0001" severity failure;

    -- Return to PLAY: encoder resumes preset navigation and button actions.
    mode<='0';settle;
    enc(true); assert pi=1 report "panel_ctrl_tb: PLAY encoder preset select failed" severity failure;
    short_press;
    assert recalls=1 and saves=0 and c.gamma2=to_q123(0.300)
      report "panel_ctrl_tb: PLAY short recall failed" severity failure;
    enc(true);enc(true);long_press;
    assert saves=1 report "panel_ctrl_tb: PLAY long save failed" severity failure;

    report "panel_ctrl_tb: PLAY/EDIT pages + soft takeover + contextual encoder checks passed" severity note;
    done<=true;finish;wait;
  end process;
end architecture;
