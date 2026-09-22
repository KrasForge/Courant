-------------------------------------------------------------------------------
-- fx_delay.vhd - stereo/ping-pong feedback delay using one single-port BRAM.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;
use work.fx_pkg.all;

entity fx_delay is
  generic (MAX_DELAY_SAMPLES : positive := 24000);
  port (
    clk, rst, valid_in : in std_logic;
    enable             : in std_logic;
    time_samples       : in unsigned(15 downto 0);
    feedback, damping  : in unsigned(7 downto 0);
    pingpong           : in std_logic;
    mix                : in unsigned(7 downto 0);
    in_l, in_r         : in q123_t;
    out_l, out_r       : out q123_t;
    valid_out          : out std_logic
  );
end entity;

architecture rtl of fx_delay is
  type ram_t is array (0 to MAX_DELAY_SAMPLES-1) of std_logic_vector(31 downto 0);
  signal ram : ram_t := (others => (others=>'0'));
  signal ram_q, ram_wdata : std_logic_vector(31 downto 0) := (others=>'0');
  signal mem_addr : integer range 0 to MAX_DELAY_SAMPLES-1 := 0;
  signal mem_we : std_logic := '0';
  signal wr_ptr : integer range 0 to MAX_DELAY_SAMPLES-1 := 0;
  type state_t is (IDLE, WAIT1, WAIT2, WRITE_BACK);
  signal state : state_t := IDLE;
  signal dry_l, dry_r, wet_l, wet_r : q123_t := Q123_ZERO;
  signal lp_l, lp_r : q123_t := Q123_ZERO;
  signal fb_q, damp_q, mix_q : unsigned(7 downto 0) := (others=>'0');
  signal ping_q, en_q : std_logic := '0';

  function sub_wrap(p, d : integer) return integer is
    variable x : integer;
  begin
    x:=p-d;
    if x<0 then x:=x+MAX_DELAY_SAMPLES; end if;
    return x;
  end function;
begin
  mem : process(clk)
  begin
    if rising_edge(clk) then
      ram_q<=ram(mem_addr);
      if mem_we='1' then ram(mem_addr)<=ram_wdata; end if;
    end if;
  end process;

  control : process(clk)
    variable d : integer;
    variable del_l,del_r,dlpf_l,dlpf_r,feed_l,feed_r,write_l,write_r:q123_t;
    variable lpacc_l,lpacc_r:acc_t;
    variable smooth:unsigned(7 downto 0);
  begin
    if rising_edge(clk) then
      valid_out<='0';
      if rst='1' then
        state<=IDLE; mem_we<='0'; mem_addr<=0; wr_ptr<=0;
        dry_l<=Q123_ZERO; dry_r<=Q123_ZERO; wet_l<=Q123_ZERO; wet_r<=Q123_ZERO;
        lp_l<=Q123_ZERO; lp_r<=Q123_ZERO; out_l<=Q123_ZERO; out_r<=Q123_ZERO;
      else
        case state is
          when IDLE =>
            mem_we<='0';
            if valid_in='1' then
              dry_l<=in_l; dry_r<=in_r; fb_q<=feedback; damp_q<=damping;
              mix_q<=mix; ping_q<=pingpong; en_q<=enable;
              d:=to_integer(time_samples);
              if d<1 then d:=1; end if;
              if d>MAX_DELAY_SAMPLES-1 then d:=MAX_DELAY_SAMPLES-1; end if;
              mem_addr<=sub_wrap(wr_ptr,d);
              state<=WAIT1;
            end if;
          when WAIT1 => state<=WAIT2;
          when WAIT2 =>
            del_l:=from_q15(signed(ram_q(31 downto 16)));
            del_r:=from_q15(signed(ram_q(15 downto 0)));
            wet_l<=del_l; wet_r<=del_r;
            smooth:=to_unsigned(255-to_integer(damp_q),8);
            lpacc_l:=to_acc(lp_l)+scale_acc_u8(to_acc(del_l)-to_acc(lp_l),smooth);
            lpacc_r:=to_acc(lp_r)+scale_acc_u8(to_acc(del_r)-to_acc(lp_r),smooth);
            dlpf_l:=sat_store(lpacc_l); dlpf_r:=sat_store(lpacc_r);
            if en_q='1' then
              lp_l<=dlpf_l; lp_r<=dlpf_r;
              if ping_q='1' then
                feed_l:=scale_u8(dlpf_r,fb_q); feed_r:=scale_u8(dlpf_l,fb_q);
              else
                feed_l:=scale_u8(dlpf_l,fb_q); feed_r:=scale_u8(dlpf_r,fb_q);
              end if;
              write_l:=sat_store(to_acc(dry_l)+to_acc(feed_l));
              write_r:=sat_store(to_acc(dry_r)+to_acc(feed_r));
            else
              write_l:=dry_l; write_r:=dry_r;
            end if;
            ram_wdata<=std_logic_vector(to_q15(write_l)) & std_logic_vector(to_q15(write_r));
            mem_addr<=wr_ptr; mem_we<='1'; state<=WRITE_BACK;
          when WRITE_BACK =>
            mem_we<='0';
            if en_q='1' then
              out_l<=mix_u8(dry_l,wet_l,mix_q); out_r<=mix_u8(dry_r,wet_r,mix_q);
            else out_l<=dry_l; out_r<=dry_r; end if;
            if wr_ptr=MAX_DELAY_SAMPLES-1 then wr_ptr<=0; else wr_ptr<=wr_ptr+1; end if;
            valid_out<='1'; state<=IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
