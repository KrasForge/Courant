-------------------------------------------------------------------------------
-- fx_drive.vhd - sample-rate stereo pre-drive + soft saturation.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.fdtd_pkg.all;
use work.fx_pkg.all;

entity fx_drive is
  port (
    clk, rst, valid_in : in std_logic;
    enable             : in std_logic;
    amount             : in unsigned(7 downto 0);
    in_l, in_r         : in q123_t;
    out_l, out_r       : out q123_t;
    valid_out          : out std_logic
  );
end entity;

architecture rtl of fx_drive is
begin
  process(clk)
    variable pre_l, pre_r : acc_t;
    variable wet_l, wet_r : q123_t;
  begin
    if rising_edge(clk) then
      valid_out <= '0';
      if rst='1' then
        out_l <= Q123_ZERO; out_r <= Q123_ZERO;
      elsif valid_in='1' then
        if enable='1' and amount /= 0 then
          -- Pre-gain ranges from 1x to just under 3x.
          pre_l := to_acc(in_l) + shift_left(scale_acc_u8(to_acc(in_l), amount), 1);
          pre_r := to_acc(in_r) + shift_left(scale_acc_u8(to_acc(in_r), amount), 1);
          wet_l := soft_clip_acc(pre_l);
          wet_r := soft_clip_acc(pre_r);
          out_l <= mix_u8(in_l, wet_l, amount);
          out_r <= mix_u8(in_r, wet_r, amount);
        else
          out_l <= in_l; out_r <= in_r;
        end if;
        valid_out <= '1';
      end if;
    end if;
  end process;
end architecture;
