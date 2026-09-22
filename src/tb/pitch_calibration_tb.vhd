library ieee;
use ieee.std_logic_1164.all; use ieee.numeric_std.all; use ieee.math_real.all;
use std.env.all; use work.fdtd_pkg.all; use work.musical_pkg.all;
entity pitch_calibration_tb is end;
architecture sim of pitch_calibration_tb is begin
 process
  variable g,lambda,hz,measured,cents: real;
  variable side,overs,rate: positive;
  variable q: q123_t; variable tests: natural:=0;
 begin
  for mesh_size in 0 to 1 loop
   side:=8+mesh_size*8;
   for o in 0 to 2 loop
    overs:=2**o;
    for r in 1 to 2 loop
     rate:=48000*r;
     for free in boolean loop
      if free then lambda:=2.0-2.0*cos(MATH_PI/real(side-1));
      else lambda:=4.0-4.0*cos(MATH_PI/real(side+1)); end if;
      for octave in 0 to 3 loop
       hz:=110.0*2.0**octave;
       q:=note_gamma2(45+12*octave,side,side,overs,rate,free);
       g:=real(to_integer(q))/real(2**23);
       measured:=real(rate*overs)/MATH_PI*arcsin(sqrt(g*lambda)/2.0);
       cents:=1200.0*log(measured/hz)/log(2.0);
       assert abs(cents)<5.0 report "Pitch error "&real'image(cents)&" cents" severity failure;
       assert tension_scale(q,to_q123(0.25))=q report "Unity tension lost coefficient precision" severity failure;
       tests:=tests+1;
      end loop;
     end loop;
    end loop;
   end loop;
  end loop;
  assert note_gamma2(38,8,8,4,48000,false)/=note_gamma2(40,8,8,4,48000,false)
    report "Old low-note pitch-floor plateau returned" severity failure;
  assert coordinate(to_unsigned(255,8),8)=7 severity failure;
  report "pitch_calibration_tb: "&integer'image(tests)&" grid/rate/OS/boundary pitch cases passed";
  finish; wait;
 end process;
end;
