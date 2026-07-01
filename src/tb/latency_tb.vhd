-------------------------------------------------------------------------------
-- latency_tb.vhd  -  measures the deterministic, sub-sample latency (issue #27)
--
-- README §3 claims the engine's latency is deterministic and dominated by the
-- codec framing + PE pipeline (nanoseconds to microseconds), NOT by block
-- buffering (milliseconds). This bench measures that, on the parts a simulation
-- can measure, and prints the numbers so they can be logged in
-- docs/deviations.md alongside the (hardware-pending) on-board capture.
--
-- Two measurements:
--
--   A. Compute latency (mesh_resonator, system-clock domain). Cycles from a
--      `frame` strobe to the matching `out_valid`. This is the OS oversampled
--      mesh steps through the 4-stage PE pipeline plus the decimator: the
--      "sub-sample" number. It is compared against the per-sample cycle budget
--      (100 MHz / 48 kHz ~= 2083 cycles) and must be a tiny fraction of it.
--
--   B. End-to-end latency (top_resonator over a real I2S link, a second
--      i2s_transceiver acting as the codec). Audio frames from a one-frame
--      input strike to the first responding output frame. This adds only the
--      fixed I2S framing each way (one input frame + one output frame) and the
--      CDC handshake on top of the compute latency: a small constant number of
--      frames, with NO buffering term (a block-buffered design would add its
--      whole block length, tens to hundreds of frames).
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity latency_tb is
end entity latency_tb;

architecture sim of latency_tb is

  constant SYS_HALF  : time     := 5 ns;    -- 100 MHz system clock
  constant BCLK_HALF : time     := 30 ns;   -- I2S bit clock
  constant SLOT      : positive := 32;      -- BCLK per channel slot
  constant OS        : positive := 4;
  constant SAMPLE_BUDGET : positive := 2083; -- 100e6 / 48e3 cycles per frame

  -- shared system clock
  signal sys_clk : std_logic := '0';
  signal sys_rst : std_logic := '1';

  -- free-running system-cycle counter for measurement A
  signal syscyc : integer := 0;

  -- measurement A: mesh_resonator
  signal a_frame   : std_logic := '0';
  signal a_coeffs  : coeffs_t;
  signal a_exc     : q123_t := (others => '0');
  signal a_exc_en  : std_logic := '0';
  signal a_out_l   : q123_t;
  signal a_out_r   : q123_t;
  signal a_ovalid  : std_logic;

  -- measurement B: top_resonator + codec over I2S
  signal bclk    : std_logic := '0';
  signal lrclk   : std_logic := '0';
  signal sd_d2c, sd_c2d : std_logic;
  signal cfg_wr_en   : std_logic := '0';
  signal cfg_wr_addr : unsigned(3 downto 0) := (others => '0');
  signal cfg_wr_data : std_logic_vector(23 downto 0) := (others => '0');
  signal cfg_rd_data : std_logic_vector(23 downto 0);
  signal cod_tx_l, cod_tx_r : q123_t := (others => '0');
  signal cod_rx_l, cod_rx_r : q123_t;
  signal cod_rx_valid       : std_logic;

  signal done : boolean := false;

begin

  --------------------------------------------------------------------------
  -- clocks
  --------------------------------------------------------------------------
  sys_gen : process begin
    while not done loop sys_clk <= '0'; wait for SYS_HALF; sys_clk <= '1'; wait for SYS_HALF; end loop; wait;
  end process;
  bclk_gen : process begin
    while not done loop bclk <= '0'; wait for BCLK_HALF; bclk <= '1'; wait for BCLK_HALF; end loop; wait;
  end process;
  lr_gen : process (bclk)
    variable c : integer := 0;
  begin
    if rising_edge(bclk) then
      c := c + 1; if c = SLOT then lrclk <= not lrclk; c := 0; end if;
    end if;
  end process;

  syscyc_proc : process (sys_clk) begin
    if rising_edge(sys_clk) then syscyc <= syscyc + 1; end if;
  end process;

  watchdog : process begin
    wait for 30 ms;
    assert done report "latency_tb: timeout" severity failure;
    wait;
  end process;

  --------------------------------------------------------------------------
  -- DUTs
  --------------------------------------------------------------------------
  meas_a : entity work.mesh_resonator
    generic map (NX => 8, NY => 8, OS => OS, FREE_BOUNDARY => false)
    port map (clk => sys_clk, rst => sys_rst, frame => a_frame, coeffs => a_coeffs,
              exc_in => a_exc, exc_en => a_exc_en,
              out_l => a_out_l, out_r => a_out_r, out_valid => a_ovalid);

  dut : entity work.top_resonator
    generic map (NX => 8, NY => 8, OS => OS, FREE_BOUNDARY => false)
    port map (sys_clk => sys_clk, sys_rst => sys_rst, bclk => bclk, lrclk => lrclk,
              sd_rx => sd_c2d, sd_tx => sd_d2c,
              cfg_wr_en => cfg_wr_en, cfg_wr_addr => cfg_wr_addr,
              cfg_wr_data => cfg_wr_data, cfg_rd_addr => (others => '0'),
              cfg_rd_data => cfg_rd_data);

  codec : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (rst => sys_rst, bclk => bclk, lrclk => lrclk,
              sd_rx => sd_d2c, sd_tx => sd_c2d,
              rx_l => cod_rx_l, rx_r => cod_rx_r, rx_valid => cod_rx_valid,
              tx_l => cod_tx_l, tx_r => cod_tx_r);

  --------------------------------------------------------------------------
  -- stimulus + measurement
  --------------------------------------------------------------------------
  stim : process
    -- reference coefficients (linear: alpha = 0)
    constant REF : coeffs_t := (gamma2 => to_q123(0.09), a0 => to_q123(0.99996875),
                                sigk1  => to_q123(0.99996875), alpha => to_q123(0.0),
                                gamma2_max => to_q123(0.5));
    procedure cfg(a : natural; d : real) is
    begin
      wait until rising_edge(sys_clk);
      cfg_wr_en <= '1'; cfg_wr_addr <= to_unsigned(a, 4);
      cfg_wr_data <= std_logic_vector(to_q123(d));
      wait until rising_edge(sys_clk);
      cfg_wr_en <= '0';
    end procedure;
    procedure frame_tick is begin
      wait until rising_edge(bclk) and cod_rx_valid = '1';
    end procedure;

    variable t_start, t_out : integer;
    variable a_cycles       : integer;
    variable strike_f, resp_f : integer;
    variable fcount         : integer;
    variable responded      : boolean;
  begin
    a_coeffs <= REF;
    sys_rst  <= '1';
    wait for 300 ns;
    wait until rising_edge(sys_clk);
    sys_rst  <= '0';
    wait until rising_edge(sys_clk);

    ------------------------------------------------------------------------
    -- A. mesh_resonator compute latency: frame strobe -> out_valid
    ------------------------------------------------------------------------
    wait until rising_edge(sys_clk);
    a_exc    <= to_q123(0.5);
    a_exc_en <= '1';
    a_frame  <= '1';
    t_start  := syscyc;
    wait until rising_edge(sys_clk);
    a_frame  <= '0';
    a_exc_en <= '0';
    wait until rising_edge(sys_clk) and a_ovalid = '1';
    t_out    := syscyc;
    a_cycles := t_out - t_start;

    report "latency_tb [A] compute latency (mesh_resonator OS=" &
           integer'image(OS) & "): " & integer'image(a_cycles) &
           " system cycles = " &
           integer'image(a_cycles * 10) & " ns at 100 MHz (" &
           integer'image((a_cycles * 100) / SAMPLE_BUDGET) &
           "% of the " & integer'image(SAMPLE_BUDGET) & "-cycle sample budget)"
      severity note;

    assert a_cycles > 0 and a_cycles < SAMPLE_BUDGET
      report "latency_tb [A]: compute latency not sub-sample (" &
             integer'image(a_cycles) & " >= " & integer'image(SAMPLE_BUDGET) & ")"
      severity failure;

    ------------------------------------------------------------------------
    -- B. end-to-end latency: I2S input strike -> first responding output frame
    ------------------------------------------------------------------------
    cfg(0, 0.09); cfg(1, 0.99996875); cfg(2, 0.99996875); cfg(3, 0.0); cfg(4, 0.5);

    cod_tx_l <= (others => '0');
    -- settle: let the (zero) input flush through so the output baseline is rest
    for i in 0 to 7 loop frame_tick; end loop;

    -- strike exactly one input frame, timestamp it in audio frames
    frame_tick;
    strike_f := 0; fcount := 0; responded := false;
    cod_tx_l <= to_q123(0.5);
    frame_tick;                       -- this frame carries the strike sample
    cod_tx_l <= (others => '0');

    -- count output frames until the output first responds (leaves rest)
    for f in 1 to 200 loop
      frame_tick;
      fcount := f;
      if (to_integer(cod_rx_l) /= 0 or to_integer(cod_rx_r) /= 0) and not responded then
        resp_f    := f;
        responded := true;
      end if;
    end loop;

    assert responded
      report "latency_tb [B]: no output response to the strike" severity failure;

    report "latency_tb [B] end-to-end latency (top_resonator over I2S): " &
           integer'image(resp_f) & " audio frames from input strike to first " &
           "output response (I2S in 1 frame + compute + I2S out 1 frame + CDC; " &
           "no block buffering)" severity note;

    -- a block-buffered design would add its whole block (>= 32 frames); assert
    -- the engine's transport latency stays within a few frames.
    assert resp_f <= 8
      report "latency_tb [B]: end-to-end latency too large (" &
             integer'image(resp_f) & " frames) - looks buffered, not streamed"
      severity failure;

    report "latency_tb: all checks passed (compute latency " &
           integer'image(a_cycles) & " cycles sub-sample; end-to-end " &
           integer'image(resp_f) & " frames, no buffering)" severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
