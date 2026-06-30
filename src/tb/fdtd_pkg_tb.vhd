-------------------------------------------------------------------------------
-- fdtd_pkg_tb.vhd  -  unit test for fdtd_pkg Q1.23 math helpers
--
-- Self-checking testbench. Golden values were produced with the same integer
-- arithmetic as the M0 fixed-point model (model/QMesh2D.m): round-half-up
-- >>23 and saturation to the Q1.23 range. Any mismatch aborts with severity
-- failure so `make -C sim` (and CI) fails on a bit-level regression.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity fdtd_pkg_tb is
end entity fdtd_pkg_tb;

architecture sim of fdtd_pkg_tb is

  -- Compare a result against an expected integer (Q.23 scaled).
  procedure check (name : in string; got : in signed; expect : in integer) is
  begin
    assert to_integer(got) = expect
      report name & ": got " & integer'image(to_integer(got))
           & ", expected " & integer'image(expect)
      severity failure;
  end procedure;

begin

  stimulus : process
    -- Q.23 scale constants reused below
    constant ONE_Q : integer := 2**FRAC;           -- 8388608 (== 1.0)
  begin
    --------------------------------------------------------------------------
    -- 1. to_q123 : real -> Q1.23 (round, saturate)
    --------------------------------------------------------------------------
    check("to_q123(0.5)",         to_q123(0.5),          4194304);
    check("to_q123(-1.0)",        to_q123(-1.0),        -8388608);
    check("to_q123(1.0) sat",     to_q123(1.0),          8388607);  -- +1.0 not representable
    check("to_q123(2.0) sat",     to_q123(2.0),          8388607);
    check("to_q123(-2.0) sat",    to_q123(-2.0),        -8388608);
    -- sigk1 = 1 - sigma*k at sigma=1.5, fs=48k  (ties to the M0 study)
    check("to_q123(0.99996875)",  to_q123(0.99996875),   8388346);
    check("to_q123(0.09)",        to_q123(0.09),          754975);

    --------------------------------------------------------------------------
    -- 2. q_mul : saturating Q1.23 x Q1.23
    --------------------------------------------------------------------------
    check("q_mul(0.5,0.5)=0.25",  q_mul(to_q123(0.5),  to_q123(0.5)),   2097152);
    check("q_mul(-1,-1) sat",     q_mul(to_q123(-1.0), to_q123(-1.0)),  8388607); -- +1.0 saturates
    check("q_mul(0.25,-0.5)",     q_mul(to_q123(0.25), to_q123(-0.5)), -1048576);
    check("q_mul(0,x)=0",         q_mul(Q123_ZERO,     to_q123(0.73)),        0);

    --------------------------------------------------------------------------
    -- 3. sat_add : saturating add
    --------------------------------------------------------------------------
    check("sat_add(0.5,0.25)",    sat_add(to_q123(0.5),  to_q123(0.25)),  6291456);
    check("sat_add(0.75,0.75)",   sat_add(to_q123(0.75), to_q123(0.75)),  8388607); -- +1.5 -> sat
    check("sat_add(-0.75,-0.75)", sat_add(to_q123(-0.75),to_q123(-0.75)),-8388608); -- -1.5 -> sat

    --------------------------------------------------------------------------
    -- 4. mul_coeff : coeff x wide accumuland, round >>23, kept wide
    --------------------------------------------------------------------------
    -- gamma^2(0.09) * lap(4.0 at Q.23)  -> 0.36-ish, no saturation (wide)
    check("mul_coeff(0.09, 4.0)",
          mul_coeff(to_q123(0.09), to_signed(4*ONE_Q, ACC_BITS)),  3019900);
    -- a0(0.99996875) * acc(0.8)
    check("mul_coeff(a0, 0.8)",
          mul_coeff(to_q123(0.99996875), to_signed(integer(0.8*real(ONE_Q)), ACC_BITS)),
          6710676);
    -- mul_coeff must agree with q_mul when the result is in range
    check("mul_coeff == q_mul (in range)",
          mul_coeff(to_q123(0.25), to_acc(to_q123(-0.5))), -1048576);

    --------------------------------------------------------------------------
    -- 5. sat_store : 48-bit guard accumulator -> Q1.23
    --------------------------------------------------------------------------
    check("sat_store(1.5) sat",   sat_store(to_signed(  12582912, ACC_BITS)),  8388607);
    check("sat_store(-2.0) sat",  sat_store(to_signed( -16777216, ACC_BITS)), -8388608);
    check("sat_store(0.3) ok",    sat_store(to_signed(   2516582, ACC_BITS)),  2516582);

    --------------------------------------------------------------------------
    -- 6. clamp
    --------------------------------------------------------------------------
    check("clamp(0.9 ->0.5)",  clamp(to_q123(0.9),  to_q123(-0.5), to_q123(0.5)),  4194304);
    check("clamp(-0.9->-0.5)", clamp(to_q123(-0.9), to_q123(-0.5), to_q123(0.5)), -4194304);
    check("clamp(0.1 in)",     clamp(to_q123(0.1),  to_q123(-0.5), to_q123(0.5)),   838861);

    report "fdtd_pkg_tb: all checks passed" severity note;
    finish;
  end process;

end architecture sim;
