-------------------------------------------------------------------------------
-- fx_tone.vhd - low-cost stereo tilt tone control around a one-pole split.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;
use work.fx_pkg.all;

entity fx_tone is
  port (
    clk, rst, valid_in : in std_logic;
    enable             : in std_logic;
    tone               : in unsigned(7 downto 0); -- 128 = neutral
    in_l, in_r         : in q123_t;
    out_l, out_r       : out q123_t;
    valid_out          : out std_logic
  );
end entity;

architecture rtl of fx_tone is
  signal low_l, low_r : q123_t := Q123_ZERO;
begin
  process(clk)
    variable dl, dr, hl, hr, yl, yr : acc_t;
    variable nl, nr : q123_t;
    variable delta : integer;
    variable gain  : unsigned(7 downto 0);
  begin
    if rising_edge(clk) then
      valid_out <= '0';
      if rst='1' then
        low_l<=Q123_ZERO; low_r<=Q123_ZERO;
        out_l<=Q123_ZERO; out_r<=Q123_ZERO;
      elsif valid_in='1' then
        dl := to_acc(in_l)-to_acc(low_l);
        dr := to_acc(in_r)-to_acc(low_r);
        nl := sat_store(to_acc(low_l)+shift_right(dl,3));
        nr := sat_store(to_acc(low_r)+shift_right(dr,3));
        low_l <= nl; low_r <= nr;
        if enable='0' or tone=to_unsigned(128,8) then
          out_l <= in_l; out_r <= in_r;
        else
          hl := to_acc(in_l)-to_acc(nl);
          hr := to_acc(in_r)-to_acc(nr);
          delta := to_integer(tone)-128;
          if delta >= 0 then
            if delta*2 > 255 then gain := to_unsigned(255,8);
            else gain := to_unsigned(delta*2,8); end if;
            yl := to_acc(in_l)+shift_right(scale_acc_u8(hl,gain),1);
            yr := to_acc(in_r)+shift_right(scale_acc_u8(hr,gain),1);
          else
            delta := -delta;
            if delta*2 > 255 then gain := to_unsigned(255,8);
            else gain := to_unsigned(delta*2,8); end if;
            yl := to_acc(in_l)-scale_acc_u8(hl,gain);
            yr := to_acc(in_r)-scale_acc_u8(hr,gain);
          end if;
          out_l <= sat_store(yl); out_r <= sat_store(yr);
        end if;
        valid_out <= '1';
      end if;
    end if;
  end process;
end architecture;
