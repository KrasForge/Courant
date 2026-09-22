-------------------------------------------------------------------------------
-- physical_mallet.vhd - stateful bidirectional lumped contact exciter (#87)
--
-- Normalized hammer dynamics:
--   eta = hammer_x - surface_u
--   F   ~= hardness * [eta]_+^2
--   v'  = v - F/128
--   x'  = x + v'
--
-- physical_pkg implements the power-law approximation and hardness scaling
-- with shifts/adds only. No DSP multiplier is required. force_out is a
-- separately normalized surface-force unit conversion; the raw contact force
-- drives the hammer reaction.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;
use work.physical_pkg.all;

entity physical_mallet is
  generic (MAX_AGE : positive := 2047);
  port (
    clk, rst : in std_logic;
    enable   : in std_logic := '0';
    step     : in std_logic;
    trigger  : in std_logic := '0';
    strike_velocity : in q123_t := Q123_ZERO;
    hardness : in unsigned(7 downto 0) := (others=>'0');
    surface_u : in q123_t := Q123_ZERO;
    force_out : out q123_t;
    contact   : out std_logic;
    active    : out std_logic;
    hammer_x  : out q123_t;
    hammer_v  : out q123_t
  );
end entity;

architecture rtl of physical_mallet is
  constant GAP : q123_t := to_q123(0.008);
  signal hx : q123_t := Q123_ZERO;
  signal hv : q123_t := Q123_ZERO;
  signal running : std_logic := '0';
  signal touched : std_logic := '0';
  signal age : natural range 0 to MAX_AGE := 0;
  signal compression, raw_force : q123_t := Q123_ZERO;
begin
  compression <= sat_store(to_acc(hx)-to_acc(surface_u))
                 when running='1' else Q123_ZERO;
  raw_force <= mallet_contact_force(compression,hardness)
               when running='1' and enable='1' else Q123_ZERO;
  force_out <= sat_store(shift_left(to_acc(raw_force),4))
               when running='1' and enable='1' else Q123_ZERO;
  contact <= '1' when running='1' and raw_force>Q123_ZERO else '0';
  active<=running; hammer_x<=hx; hammer_v<=hv;

  process(clk)
    variable vnext,launch:q123_t;
  begin
    if rising_edge(clk) then
      if rst='1' or enable='0' then
        hx<=Q123_ZERO; hv<=Q123_ZERO; running<='0'; touched<='0'; age<=0;
      elsif step='1' then
        if trigger='1' then
          launch:=mallet_launch_velocity(strike_velocity);
          hx<=sat_store(to_acc(surface_u)-to_acc(GAP));
          hv<=launch; touched<='0'; age<=0;
          if launch=Q123_ZERO or hardness=0 then running<='0';
          else running<='1'; end if;
        elsif running='1' then
          vnext:=sat_store(to_acc(hv)-shift_right(to_acc(raw_force),7));
          hv<=vnext;
          hx<=sat_store(to_acc(hx)+to_acc(vnext));
          if raw_force>Q123_ZERO then
            touched<='1';
          elsif touched='1' then
            running<='0';
          end if;
          if age=MAX_AGE then
            running<='0';
          else
            age<=age+1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
