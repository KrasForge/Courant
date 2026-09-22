-------------------------------------------------------------------------------
-- panel_ctrl.vhd - six pots + encoder with PLAY/EDIT page selection.
--
-- edit_mode=0 PLAY: TENSION / DECAY / CHAOS / DRIVE / DELAY / REVERB.
-- edit_mode=1 EDIT: encoder selects an edit page. Page 0 is SURFACE:
--                   ANISO / RIM / STRIKE SIZE / STRIKE X / STRIKE Y / CHARACTER.
-- Additional edit pages are deliberately reserved for follow-up features.
--
-- Every pot uses read-back based soft takeover. After reset, preset recall,
-- PLAY/EDIT changes, or EDIT-page changes, a pot must cross the stored value
-- before it can write.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
library work;
use work.fdtd_pkg.all;

entity panel_ctrl is
  generic (
    FS_HZ : positive := 48_000; OS : positive := 4;
    POT_W : positive := 12; N_PRESETS : positive := 7;
    N_EDIT_PAGES : positive := 1;           -- 1..4; page 0 is SURFACE
    DEADBAND : natural := 4096; FX_DEADBAND : natural := 2;
    LONG_CYC : positive := 50_000_000;
    PITCH_LO : real := 0.0625; PITCH_HI : real := 1.0-2.0**(-23);
    DECAY_LO : real := exp(-20.0/real(FS_HZ*OS));
    DECAY_HI : real := exp(-0.8/real(FS_HZ*OS));
    TIMBRE_LO : real := 0.0; TIMBRE_HI : real := 0.40
  );
  port (
    clk, rst : in std_logic;
    edit_mode : in std_logic := '0';        -- 0=PLAY, 1=EDIT
    pot_pitch, pot_decay, pot_timbre : in unsigned(POT_W-1 downto 0);
    pot_drive, pot_delay, pot_reverb : in unsigned(POT_W-1 downto 0);
    enc_a, enc_b, enc_btn : in std_logic;
    cfg_wr_en : out std_logic; cfg_wr_addr : out unsigned(3 downto 0);
    cfg_wr_data : out std_logic_vector(23 downto 0);
    cfg_rd_addr : out unsigned(3 downto 0);
    cfg_rd_data : in std_logic_vector(23 downto 0);
    preset_index : out unsigned(3 downto 0);
    preset_recall, preset_save : out std_logic;
    edit_page : out unsigned(1 downto 0);
    edit_leds : out std_logic_vector(3 downto 0)
  );
end entity panel_ctrl;

architecture rtl of panel_ctrl is
  constant PITCH_LO_Q:q123_t:=to_q123(PITCH_LO);
  constant PITCH_SPAN:q123_t:=to_q123(PITCH_HI-PITCH_LO);
  constant DECAY_LO_Q:q123_t:=to_q123(DECAY_LO);
  constant DECAY_SPAN:q123_t:=to_q123(DECAY_HI-DECAY_LO);
  constant TIMBRE_LO_Q:q123_t:=to_q123(TIMBRE_LO);
  constant TIMBRE_SPAN:q123_t:=to_q123(TIMBRE_HI-TIMBRE_LO);

  type scan_state_t is (SCAN_REQ,SCAN_WAIT,SCAN_EVAL,WRITE_DECAY);
  signal scan_state:scan_state_t:=SCAN_REQ;
  signal scan_idx:integer range 0 to 5:=0;
  signal armed,side_valid,side_pos:std_logic_vector(5 downto 0):=(others=>'0');
  signal mode_d:std_logic:='0';
  signal holdoff:integer range 0 to 4:=0;
  signal decay_second:q123_t:=Q123_ZERO;

  signal a_s,b_s:std_logic_vector(1 downto 0):=(others=>'0');
  signal a_d:std_logic:='0'; signal btn_s:std_logic_vector(1 downto 0):=(others=>'0');
  signal idx:unsigned(3 downto 0):=(others=>'0');
  signal edit_idx:integer range 0 to 3:=0;
  signal held:integer range 0 to LONG_CYC:=0; signal saved:std_logic:='0';
  signal btn_blocked:std_logic:='0';

  function scale_pot(pot:unsigned;lo,span:q123_t) return q123_t is
    variable p:signed(span'length+POT_W downto 0);
  begin p:=span*signed('0'&pot); return sat_add(lo,resize(shift_right(p,POT_W),Q_BITS)); end;
  function byte_pot(pot:unsigned) return unsigned is
  begin return resize(pot(POT_W-1 downto POT_W-8),8); end;
  function pot_sel(i:integer; p0,p1,p2,p3,p4,p5:unsigned) return unsigned is
  begin
    case i is when 0=>return p0; when 1=>return p1; when 2=>return p2;
      when 3=>return p3; when 4=>return p4; when others=>return p5; end case;
  end;
  function perf_q(i:integer; p0,p1,p2:unsigned) return q123_t is
    variable pv:unsigned(POT_W-1 downto 0); variable lo,span:q123_t;
    variable prod:signed(Q_BITS+POT_W downto 0);
  begin
    case i is
      when 0=>pv:=p0;lo:=PITCH_LO_Q;span:=PITCH_SPAN;
      when 1=>pv:=p1;lo:=DECAY_LO_Q;span:=DECAY_SPAN;
      when others=>pv:=p2;lo:=TIMBRE_LO_Q;span:=TIMBRE_SPAN;
    end case;
    -- One shared multiplier after the scanner mux, instead of one multiplier
    -- per Performance macro branch.
    prod:=span*signed('0'&pv);
    return sat_add(lo,resize(shift_right(prod,POT_W),Q_BITS));
  end;
  function perf_addr(i:integer) return unsigned is
  begin case i is when 0=>return x"0"; when 1=>return x"2"; when 2=>return x"3";
    when 3=>return x"A"; when 4=>return x"C"; when others=>return x"E"; end case; end;
  function membrane_addr(i:integer) return unsigned is
  begin case i is when 0=>return x"9"; when 1=>return x"5"; when 2=>return x"6";
    when 3=>return x"7"; when 4=>return x"8"; when others=>return x"9"; end case; end;
  function aniso_pot(p:unsigned) return integer is
  begin return to_integer(p(POT_W-1 downto POT_W-4))-8; end;
  function char_pot(p:unsigned) return integer is variable v:integer;
  begin v:=to_integer(p(POT_W-1 downto POT_W-3)); if v>5 then v:=5; end if; return v; end;
begin
  assert POT_W>=8 report "panel_ctrl requires POT_W >= 8" severity failure;
  assert N_EDIT_PAGES<=4 report "panel_ctrl supports at most four EDIT pages" severity failure;
  preset_index<=idx;
  edit_page<=to_unsigned(edit_idx,edit_page'length);
  edit_leds<=std_logic_vector(shift_left(to_unsigned(1,4),edit_idx))
             when edit_mode='1' else (others=>'0');

  process(clk)
    variable potv:unsigned(POT_W-1 downto 0);
    variable qv:q123_t; variable bv:unsigned(7 downto 0);
    variable cand,cur,diff,thr:integer; variable crossing,write_now:boolean;
    variable w:std_logic_vector(23 downto 0);
  begin
    if rising_edge(clk) then
      cfg_wr_en<='0'; preset_recall<='0'; preset_save<='0';
      if rst='1' then
        cfg_wr_addr<=(others=>'0');cfg_wr_data<=(others=>'0');cfg_rd_addr<=(others=>'0');
        scan_state<=SCAN_REQ;scan_idx<=0;armed<=(others=>'0');side_valid<=(others=>'0');
        side_pos<=(others=>'0');mode_d<='0';holdoff<=2;decay_second<=Q123_ZERO;
        idx<=(others=>'0');edit_idx<=0;held<=0;saved<='0';btn_blocked<='0';
        a_s<="00";b_s<="00";a_d<='0';btn_s<="00";
      else
        a_s<=a_s(0)&enc_a;b_s<=b_s(0)&enc_b;a_d<=a_s(1);btn_s<=btn_s(0)&enc_btn;

        if edit_mode/=mode_d then
          mode_d<=edit_mode; armed<=(others=>'0'); side_valid<=(others=>'0');
          scan_idx<=0; scan_state<=SCAN_REQ; holdoff<=2;
          held<=0; saved<='0'; btn_blocked<='1';
        elsif holdoff>0 then
          holdoff<=holdoff-1; scan_state<=SCAN_REQ;
        else
          case scan_state is
            when SCAN_REQ =>
              if edit_mode='0' then
                cfg_rd_addr<=perf_addr(scan_idx); scan_state<=SCAN_WAIT;
              elsif edit_idx=0 then
                cfg_rd_addr<=membrane_addr(scan_idx); scan_state<=SCAN_WAIT;
              else
                -- Reserved EDIT pages are inert until their backing features
                -- land; selecting one must never alias the SURFACE registers.
                scan_idx<=0; scan_state<=SCAN_REQ;
              end if;
            when SCAN_WAIT =>
              if edit_mode='1' and edit_idx/=0 then scan_state<=SCAN_REQ;
              else scan_state<=SCAN_EVAL; end if;
            when SCAN_EVAL =>
              potv:=pot_sel(scan_idx,pot_pitch,pot_decay,pot_timbre,pot_drive,pot_delay,pot_reverb);
              thr:=0; cand:=0; cur:=0;
              if edit_mode='0' and scan_idx<=2 then
                qv:=perf_q(scan_idx,pot_pitch,pot_decay,pot_timbre);
                cand:=to_integer(qv);cur:=to_integer(signed(cfg_rd_data));
                if scan_idx=1 then thr:=1; else thr:=integer(DEADBAND); end if;
              elsif edit_mode='0' then
                bv:=byte_pot(potv);cand:=to_integer(bv);thr:=integer(FX_DEADBAND);
                case scan_idx is
                  when 3=>cur:=to_integer(unsigned(cfg_rd_data(17 downto 10)));
                  when others=>cur:=to_integer(unsigned(cfg_rd_data(7 downto 0)));
                end case;
              elsif scan_idx=0 then
                cand:=aniso_pot(potv);cur:=to_integer(signed(cfg_rd_data(10 downto 7)));thr:=0;
              elsif scan_idx=5 then
                cand:=char_pot(potv);cur:=to_integer(unsigned(cfg_rd_data(6 downto 4)));thr:=0;
              else
                bv:=byte_pot(potv);cand:=to_integer(bv);cur:=to_integer(unsigned(cfg_rd_data(15 downto 8)));
                thr:=integer(FX_DEADBAND);
              end if;
              diff:=cand-cur; write_now:=false; crossing:=false;
              if armed(scan_idx)='1' then
                if diff>thr or diff< -thr then write_now:=true; end if;
              elsif diff<=thr and diff>=-thr then armed(scan_idx)<='1';
              elsif side_valid(scan_idx)='0' then
                side_valid(scan_idx)<='1'; if diff>0 then side_pos(scan_idx)<='1'; else side_pos(scan_idx)<='0'; end if;
              else
                crossing:=(diff>0 and side_pos(scan_idx)='0') or (diff<0 and side_pos(scan_idx)='1');
                if crossing then armed(scan_idx)<='1'; write_now:=true; end if;
              end if;

              if write_now then
                if edit_mode='0' and scan_idx<=2 then
                  qv:=perf_q(scan_idx,pot_pitch,pot_decay,pot_timbre);
                  cfg_wr_en<='1';cfg_wr_addr<=perf_addr(scan_idx);cfg_wr_data<=std_logic_vector(qv);
                  if scan_idx=1 then decay_second<=qv;scan_state<=WRITE_DECAY;
                  else if scan_idx=5 then scan_idx<=0; else scan_idx<=scan_idx+1; end if;scan_state<=SCAN_REQ;end if;
                else
                  w:=cfg_rd_data;
                  if edit_mode='0' then
                    bv:=byte_pot(potv);
                    if scan_idx=3 then w(17 downto 10):=std_logic_vector(bv); else w(7 downto 0):=std_logic_vector(bv); end if;
                  elsif scan_idx=0 then
                    w(10 downto 7):=std_logic_vector(to_signed(aniso_pot(potv),4));
                  elsif scan_idx=5 then
                    w(6 downto 4):=std_logic_vector(to_unsigned(char_pot(potv),3));
                  else
                    w(15 downto 8):=std_logic_vector(byte_pot(potv));
                  end if;
                  cfg_wr_en<='1'; if edit_mode='0' then cfg_wr_addr<=perf_addr(scan_idx);else cfg_wr_addr<=membrane_addr(scan_idx);end if;
                  cfg_wr_data<=w;
                  if scan_idx=5 then scan_idx<=0;else scan_idx<=scan_idx+1;end if;scan_state<=SCAN_REQ;
                end if;
              else
                if scan_idx=5 then scan_idx<=0;else scan_idx<=scan_idx+1;end if;scan_state<=SCAN_REQ;
              end if;
            when WRITE_DECAY =>
              cfg_wr_en<='1';cfg_wr_addr<=x"1";cfg_wr_data<=std_logic_vector(decay_second);
              if scan_idx=5 then scan_idx<=0;else scan_idx<=scan_idx+1;end if;scan_state<=SCAN_REQ;
          end case;
        end if;

        -- Encoder is contextual: presets in PLAY, EDIT pages in EDIT.
        if a_s(1)='1' and a_d='0' then
          if edit_mode='0' then
            if b_s(1)='0' then if idx<N_PRESETS-1 then idx<=idx+1;end if;
            else if idx>0 then idx<=idx-1;end if;end if;
          elsif N_EDIT_PAGES>1 then
            if b_s(1)='0' then
              if edit_idx=N_EDIT_PAGES-1 then edit_idx<=0; else edit_idx<=edit_idx+1; end if;
            else
              if edit_idx=0 then edit_idx<=N_EDIT_PAGES-1; else edit_idx<=edit_idx-1; end if;
            end if;
            armed<=(others=>'0'); side_valid<=(others=>'0');
            scan_idx<=0; scan_state<=SCAN_REQ; holdoff<=2;
          end if;
        end if;

        -- Preset button gestures exist only in PLAY. Any press made in EDIT
        -- stays blocked until the physical button is released after returning
        -- to PLAY, preventing an EDIT gesture from becoming a recall/save.
        if edit_mode='1' then
          held<=0; saved<='0'; btn_blocked<='1';
        elsif btn_blocked='1' then
          held<=0; saved<='0';
          if btn_s(1)='0' then btn_blocked<='0'; end if;
        elsif btn_s(1)='1' then
          if held=LONG_CYC then if saved='0' then preset_save<='1';saved<='1';end if;
          else held<=held+1;end if;
        else
          if held>0 and saved='0' then
            preset_recall<='1'; armed<=(others=>'0');side_valid<=(others=>'0');holdoff<=3;scan_state<=SCAN_REQ;
          end if;
          held<=0;saved<='0';
        end if;
      end if;
    end if;
  end process;
end architecture rtl;
