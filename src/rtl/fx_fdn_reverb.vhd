-------------------------------------------------------------------------------
-- fx_fdn_reverb.vhd - eight-line damped FDN with one shared control multiplier.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;
use work.fx_pkg.all;

entity fx_fdn_reverb is
  port (
    clk, rst, valid_in : in std_logic;
    enable             : in std_logic;
    decay, damping     : in unsigned(7 downto 0);
    size, diffusion    : in unsigned(7 downto 0);
    mix                : in unsigned(7 downto 0);
    in_l, in_r         : in q123_t;
    out_l, out_r       : out q123_t;
    valid_out          : out std_logic
  );
end entity;

architecture rtl of fx_fdn_reverb is
  constant L0 : positive := 421;  constant L1 : positive := 547;
  constant L2 : positive := 631;  constant L3 : positive := 733;
  constant L4 : positive := 887;  constant L5 : positive := 953;
  constant L6 : positive := 1061; constant L7 : positive := 1153;
  type r0_t is array(0 to L0-1) of q15_t; type r1_t is array(0 to L1-1) of q15_t;
  type r2_t is array(0 to L2-1) of q15_t; type r3_t is array(0 to L3-1) of q15_t;
  type r4_t is array(0 to L4-1) of q15_t; type r5_t is array(0 to L5-1) of q15_t;
  type r6_t is array(0 to L6-1) of q15_t; type r7_t is array(0 to L7-1) of q15_t;
  signal m0:r0_t := (others=>(others=>'0')); signal m1:r1_t := (others=>(others=>'0'));
  signal m2:r2_t := (others=>(others=>'0')); signal m3:r3_t := (others=>(others=>'0'));
  signal m4:r4_t := (others=>(others=>'0')); signal m5:r5_t := (others=>(others=>'0'));
  signal m6:r6_t := (others=>(others=>'0')); signal m7:r7_t := (others=>(others=>'0'));
  signal p0:integer range 0 to L0-1:=0; signal p1:integer range 0 to L1-1:=0;
  signal p2:integer range 0 to L2-1:=0; signal p3:integer range 0 to L3-1:=0;
  signal p4:integer range 0 to L4-1:=0; signal p5:integer range 0 to L5-1:=0;
  signal p6:integer range 0 to L6-1:=0; signal p7:integer range 0 to L7-1:=0;
  signal mod_phase : unsigned(15 downto 0) := (others=>'0');

  type qvec_t is array(0 to 7) of q123_t;
  signal q, lp, damped, matrix, mixed : qvec_t := (others=>Q123_ZERO);
  signal dry_l,dry_r,mono_q,wet_l_q,wet_r_q : q123_t := Q123_ZERO;
  signal decay_q,damp_q,size_q,diff_q,mix_q : unsigned(7 downto 0):=(others=>'0');
  signal en_q : std_logic := '0';
  signal idx : integer range 0 to 7 := 0;
  signal ram_we : std_logic := '0';
  signal ram_wline : integer range 0 to 7 := 0;
  signal ram_waddr : integer range 0 to L7-1 := 0;
  signal ram_wdata : q15_t := (others=>'0');
  type state_t is (IDLE,DAMP,MATRIX_STEP,DIFFUSE,DECAY_STEP,OUT_LEFT,OUT_RIGHT);
  signal state : state_t := IDLE;

  -- One 24x9 multiplier is time-shared across damping, diffusion, decay and mix.
  signal mul_a : q123_t := Q123_ZERO;
  signal mul_g : unsigned(7 downto 0) := (others=>'0');
  signal mul_p : signed(32 downto 0) := (others=>'0');
  signal mul_scaled : q123_t := Q123_ZERO;

  function mod_offset(p : unsigned(15 downto 0); line : natural;
                      depth : unsigned(7 downto 0)) return integer is
    variable o : integer;
  begin
    if depth < to_unsigned(64,8) then return 0; end if;
    o := ((to_integer(p(15 downto 13)) + integer(line)*3) mod 8) - 4;
    if depth < to_unsigned(160,8) then o:=o/2; end if;
    return o;
  end function;

  function effective_len(base : positive; s : unsigned(7 downto 0);
                         mo : integer) return positive is
    variable e : integer;
  begin
    case s(7 downto 6) is
      when "00" => e:=base/2;
      when "01" => e:=(base*5)/8;
      when "10" => e:=(base*3)/4;
      when others => e:=base;
    end case;
    e:=e+mo;
    if e<2 then e:=2; end if;
    if e>base then e:=base; end if;
    return positive(e);
  end function;
begin
  mul_p <= mul_a * signed('0' & std_logic_vector(mul_g));
  mul_scaled <= sat_store(resize(shift_right(resize(mul_p,ACC_BITS) +
                                  to_signed(128,ACC_BITS),8),ACC_BITS));

  -- One process per line keeps the intended single-port RAM template obvious
  -- to GHDL/Vivado while a shared write selector services the time-mux FDN.
  mem0:process(clk) begin if rising_edge(clk) then q(0)<=from_q15(m0(p0)); if ram_we='1' and ram_wline=0 then m0(ram_waddr)<=ram_wdata; end if; end if; end process;
  mem1:process(clk) begin if rising_edge(clk) then q(1)<=from_q15(m1(p1)); if ram_we='1' and ram_wline=1 then m1(ram_waddr)<=ram_wdata; end if; end if; end process;
  mem2:process(clk) begin if rising_edge(clk) then q(2)<=from_q15(m2(p2)); if ram_we='1' and ram_wline=2 then m2(ram_waddr)<=ram_wdata; end if; end if; end process;
  mem3:process(clk) begin if rising_edge(clk) then q(3)<=from_q15(m3(p3)); if ram_we='1' and ram_wline=3 then m3(ram_waddr)<=ram_wdata; end if; end if; end process;
  mem4:process(clk) begin if rising_edge(clk) then q(4)<=from_q15(m4(p4)); if ram_we='1' and ram_wline=4 then m4(ram_waddr)<=ram_wdata; end if; end if; end process;
  mem5:process(clk) begin if rising_edge(clk) then q(5)<=from_q15(m5(p5)); if ram_we='1' and ram_wline=5 then m5(ram_waddr)<=ram_wdata; end if; end if; end process;
  mem6:process(clk) begin if rising_edge(clk) then q(6)<=from_q15(m6(p6)); if ram_we='1' and ram_wline=6 then m6(ram_waddr)<=ram_wdata; end if; end if; end process;
  mem7:process(clk) begin if rising_edge(clk) then q(7)<=from_q15(m7(p7)); if ram_we='1' and ram_wline=7 then m7(ram_waddr)<=ram_wdata; end if; end if; end process;

  -- Select the shared multiplier operands from the current micro-operation.
  mul_select : process(all)
    variable delta : acc_t;
  begin
    mul_a <= Q123_ZERO; mul_g <= (others=>'0');
    case state is
      when DAMP =>
        delta:=to_acc(q(idx))-to_acc(lp(idx));
        mul_a<=sat_store(delta); mul_g<=to_unsigned(255-to_integer(damp_q),8);
      when DIFFUSE =>
        delta:=to_acc(matrix(idx))-to_acc(damped(idx));
        mul_a<=sat_store(delta); mul_g<=diff_q;
      when DECAY_STEP => mul_a<=mixed(idx); mul_g<=decay_q;
      when OUT_LEFT =>
        delta:=to_acc(wet_l_q)-to_acc(dry_l);
        mul_a<=sat_store(delta); mul_g<=mix_q;
      when OUT_RIGHT =>
        delta:=to_acc(wet_r_q)-to_acc(dry_r);
        mul_a<=sat_store(delta); mul_g<=mix_q;
      when others => null;
    end case;
  end process;
  control : process(clk)
    variable h0,h1,h2,h3,h4,h5,h6,h7 : acc_t;
    variable newv : q123_t;
    variable fb, inj, wr, wetacc : acc_t;
    variable e : positive;
  begin
    if rising_edge(clk) then
      valid_out <= '0';
      ram_we <= '0';
      if rst='1' then
        state<=IDLE; idx<=0; en_q<='0';
        p0<=0;p1<=0;p2<=0;p3<=0;p4<=0;p5<=0;p6<=0;p7<=0;
        mod_phase<=(others=>'0');
        lp<=(others=>Q123_ZERO); damped<=(others=>Q123_ZERO);
        matrix<=(others=>Q123_ZERO); mixed<=(others=>Q123_ZERO);
        dry_l<=Q123_ZERO; dry_r<=Q123_ZERO; mono_q<=Q123_ZERO;
        wet_l_q<=Q123_ZERO; wet_r_q<=Q123_ZERO;
        out_l<=Q123_ZERO; out_r<=Q123_ZERO;
      else
        case state is
          when IDLE =>
            if valid_in='1' then
              dry_l<=in_l; dry_r<=in_r;
              mono_q<=sat_store(shift_right(to_acc(in_l)+to_acc(in_r),1));
              decay_q<=decay; damp_q<=damping; size_q<=size;
              diff_q<=diffusion; mix_q<=mix; en_q<=enable;
              -- ~0.73 Hz base modulation at 48 kHz; per-line phase offsets
              -- decorrelate the FDN without another delay RAM or multiplier.
              mod_phase<=mod_phase+1;
              idx<=0; state<=DAMP;
            end if;
          when DAMP =>
            newv:=sat_store(to_acc(lp(idx))+to_acc(mul_scaled));
            damped(idx)<=newv; lp(idx)<=newv;
            if idx=7 then idx<=0; state<=MATRIX_STEP; else idx<=idx+1; end if;

          when MATRIX_STEP =>
            h0:=to_acc(damped(0))+to_acc(damped(1))+to_acc(damped(2))+to_acc(damped(3))+
                to_acc(damped(4))+to_acc(damped(5))+to_acc(damped(6))+to_acc(damped(7));
            h1:=to_acc(damped(0))-to_acc(damped(1))+to_acc(damped(2))-to_acc(damped(3))+
                to_acc(damped(4))-to_acc(damped(5))+to_acc(damped(6))-to_acc(damped(7));
            h2:=to_acc(damped(0))+to_acc(damped(1))-to_acc(damped(2))-to_acc(damped(3))+
                to_acc(damped(4))+to_acc(damped(5))-to_acc(damped(6))-to_acc(damped(7));
            h3:=to_acc(damped(0))-to_acc(damped(1))-to_acc(damped(2))+to_acc(damped(3))+
                to_acc(damped(4))-to_acc(damped(5))-to_acc(damped(6))+to_acc(damped(7));
            h4:=to_acc(damped(0))+to_acc(damped(1))+to_acc(damped(2))+to_acc(damped(3))-
                to_acc(damped(4))-to_acc(damped(5))-to_acc(damped(6))-to_acc(damped(7));
            h5:=to_acc(damped(0))-to_acc(damped(1))+to_acc(damped(2))-to_acc(damped(3))-
                to_acc(damped(4))+to_acc(damped(5))-to_acc(damped(6))+to_acc(damped(7));
            h6:=to_acc(damped(0))+to_acc(damped(1))-to_acc(damped(2))-to_acc(damped(3))-
                to_acc(damped(4))-to_acc(damped(5))+to_acc(damped(6))+to_acc(damped(7));
            h7:=to_acc(damped(0))-to_acc(damped(1))-to_acc(damped(2))+to_acc(damped(3))-
                to_acc(damped(4))+to_acc(damped(5))+to_acc(damped(6))-to_acc(damped(7));
            matrix(0)<=sat_store(shift_right(h0,3)); matrix(1)<=sat_store(shift_right(h1,3));
            matrix(2)<=sat_store(shift_right(h2,3)); matrix(3)<=sat_store(shift_right(h3,3));
            matrix(4)<=sat_store(shift_right(h4,3)); matrix(5)<=sat_store(shift_right(h5,3));
            matrix(6)<=sat_store(shift_right(h6,3)); matrix(7)<=sat_store(shift_right(h7,3));
            wetacc:=to_acc(damped(0))+to_acc(damped(2))+to_acc(damped(5))+to_acc(damped(7));
            wet_l_q<=sat_store(shift_right(wetacc,2));
            wetacc:=to_acc(damped(1))+to_acc(damped(3))+to_acc(damped(4))+to_acc(damped(6));
            wet_r_q<=sat_store(shift_right(wetacc,2));
            idx<=0; state<=DIFFUSE;

          when DIFFUSE =>
            newv:=sat_store(to_acc(damped(idx))+to_acc(mul_scaled));
            mixed(idx)<=newv;
            if idx=7 then idx<=0; state<=DECAY_STEP; else idx<=idx+1; end if;

          when DECAY_STEP =>
            fb:=shift_right(to_acc(mixed(idx))+to_acc(mul_scaled),1);
            if en_q='1' then inj:=shift_right(to_acc(mono_q),1); else inj:=(others=>'0'); end if;
            if (idx mod 2)=0 then wr:=fb+inj; else wr:=fb-inj; end if;
            ram_wline<=idx; ram_wdata<=to_q15(sat_store(wr)); ram_we<='1';
            case idx is
              when 0 => ram_waddr<=p0; e:=effective_len(L0,size_q,mod_offset(mod_phase,0,diff_q));
                        if p0>=e-1 then p0<=0; else p0<=p0+1; end if;
              when 1 => ram_waddr<=p1; e:=effective_len(L1,size_q,mod_offset(mod_phase,1,diff_q));
                        if p1>=e-1 then p1<=0; else p1<=p1+1; end if;
              when 2 => ram_waddr<=p2; e:=effective_len(L2,size_q,mod_offset(mod_phase,2,diff_q));
                        if p2>=e-1 then p2<=0; else p2<=p2+1; end if;
              when 3 => ram_waddr<=p3; e:=effective_len(L3,size_q,mod_offset(mod_phase,3,diff_q));
                        if p3>=e-1 then p3<=0; else p3<=p3+1; end if;
              when 4 => ram_waddr<=p4; e:=effective_len(L4,size_q,mod_offset(mod_phase,4,diff_q));
                        if p4>=e-1 then p4<=0; else p4<=p4+1; end if;
              when 5 => ram_waddr<=p5; e:=effective_len(L5,size_q,mod_offset(mod_phase,5,diff_q));
                        if p5>=e-1 then p5<=0; else p5<=p5+1; end if;
              when 6 => ram_waddr<=p6; e:=effective_len(L6,size_q,mod_offset(mod_phase,6,diff_q));
                        if p6>=e-1 then p6<=0; else p6<=p6+1; end if;
              when others => ram_waddr<=p7; e:=effective_len(L7,size_q,mod_offset(mod_phase,7,diff_q));
                        if p7>=e-1 then p7<=0; else p7<=p7+1; end if;
            end case;
            if idx=7 then state<=OUT_LEFT; else idx<=idx+1; end if;

          when OUT_LEFT =>
            if en_q='1' then out_l<=sat_store(to_acc(dry_l)+to_acc(mul_scaled));
            else out_l<=dry_l; end if;
            state<=OUT_RIGHT;
          when OUT_RIGHT =>
            if en_q='1' then out_r<=sat_store(to_acc(dry_r)+to_acc(mul_scaled));
            else out_r<=dry_r; end if;
            valid_out<='1'; state<=IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
