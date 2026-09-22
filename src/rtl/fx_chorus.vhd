-------------------------------------------------------------------------------
-- fx_chorus.vhd - stereo modulated short delay using single-port BRAMs.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;
use work.fx_pkg.all;

entity fx_chorus is
  generic (MEM_LEN : positive := 2048);
  port (
    clk, rst, valid_in : in std_logic;
    enable             : in std_logic;
    rate, depth, mix   : in unsigned(7 downto 0);
    in_l, in_r         : in q123_t;
    out_l, out_r       : out q123_t;
    valid_out          : out std_logic
  );
end entity;

architecture rtl of fx_chorus is
  type ram_t is array (0 to MEM_LEN-1) of q15_t;
  signal ram_l, ram_r : ram_t := (others => (others=>'0'));
  signal ram_q_l, ram_q_r, ram_w_l, ram_w_r : q15_t := (others=>'0');
  signal mem_addr_l, mem_addr_r : integer range 0 to MEM_LEN-1 := 0;
  signal mem_we : std_logic := '0';
  signal wr_ptr : integer range 0 to MEM_LEN-1 := 0;
  signal phase : unsigned(23 downto 0) := (others=>'0');
  type state_t is (IDLE, WAIT1, WAIT2, WRITE_BACK);
  signal state : state_t := IDLE;
  signal dry_l, dry_r, wet_l, wet_r : q123_t := Q123_ZERO;
  signal mix_q : unsigned(7 downto 0) := (others=>'0');
  signal en_q : std_logic := '0';

  function tri8(p : unsigned(23 downto 0)) return unsigned is
    variable v : unsigned(7 downto 0);
  begin
    if p(23)='0' then v:=p(22 downto 15); else v:=not p(22 downto 15); end if;
    return v;
  end function;

  function mul_u8_shiftadd(a,b : unsigned(7 downto 0)) return unsigned is
    variable sum : unsigned(15 downto 0) := (others=>'0');
    variable aw  : unsigned(15 downto 0) := resize(a,16);
  begin
    for i in 0 to 7 loop
      if b(i)='1' then sum:=sum+shift_left(aw,i); end if;
    end loop;
    return sum;
  end function;

  function sub_wrap(p, d : integer) return integer is
    variable x : integer;
  begin
    x := p-d;
    if x < 0 then x := x+MEM_LEN; end if;
    return x;
  end function;
begin
  mem : process(clk)
  begin
    if rising_edge(clk) then
      ram_q_l <= ram_l(mem_addr_l); ram_q_r <= ram_r(mem_addr_r);
      if mem_we='1' then
        ram_l(mem_addr_l) <= ram_w_l; ram_r(mem_addr_r) <= ram_w_r;
      end if;
    end if;
  end process;
  control : process(clk)
    variable ph_r : unsigned(23 downto 0);
    variable prod_l, prod_r, delay_l, delay_r, step : integer;
    variable mul_l, mul_r : unsigned(15 downto 0);
  begin
    if rising_edge(clk) then
      valid_out<='0';
      if rst='1' then
        state<=IDLE; mem_we<='0'; wr_ptr<=0; phase<=(others=>'0');
        mem_addr_l<=0; mem_addr_r<=0; dry_l<=Q123_ZERO; dry_r<=Q123_ZERO;
        wet_l<=Q123_ZERO; wet_r<=Q123_ZERO; out_l<=Q123_ZERO; out_r<=Q123_ZERO;
      else
        case state is
          when IDLE =>
            mem_we<='0';
            if valid_in='1' then
              dry_l<=in_l; dry_r<=in_r; mix_q<=mix; en_q<=enable;
              ph_r:=phase+to_unsigned(2**22,24);
              mul_l:=mul_u8_shiftadd(depth,tri8(phase));
              mul_r:=mul_u8_shiftadd(depth,tri8(ph_r));
              prod_l:=to_integer(mul_l)+to_integer(mul_l)+to_integer(mul_l);
              prod_r:=to_integer(mul_r)+to_integer(mul_r)+to_integer(mul_r);
              delay_l:=240+prod_l/256; delay_r:=240+prod_r/256;
              if delay_l>MEM_LEN-1 then delay_l:=MEM_LEN-1; end if;
              if delay_r>MEM_LEN-1 then delay_r:=MEM_LEN-1; end if;
              mem_addr_l<=sub_wrap(wr_ptr,delay_l);
              mem_addr_r<=sub_wrap(wr_ptr,delay_r);
              step:=64+8*to_integer(rate);
              phase<=phase+to_unsigned(step,24);
              state<=WAIT1;
            end if;
          when WAIT1 => state<=WAIT2;
          when WAIT2 =>
            wet_l<=from_q15(ram_q_l); wet_r<=from_q15(ram_q_r);
            mem_addr_l<=wr_ptr; mem_addr_r<=wr_ptr;
            ram_w_l<=to_q15(dry_l); ram_w_r<=to_q15(dry_r); mem_we<='1';
            state<=WRITE_BACK;
          when WRITE_BACK =>
            mem_we<='0';
            if en_q='1' then
              out_l<=mix_u8(dry_l,wet_l,mix_q); out_r<=mix_u8(dry_r,wet_r,mix_q);
            else
              out_l<=dry_l; out_r<=dry_r;
            end if;
            if wr_ptr=MEM_LEN-1 then wr_ptr<=0; else wr_ptr<=wr_ptr+1; end if;
            valid_out<='1'; state<=IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
