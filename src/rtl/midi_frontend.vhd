-------------------------------------------------------------------------------
-- midi_frontend.vhd  -  MIDI note/velocity -> mesh pitch, strike, and timbre
--
-- Turns the engine from a physics demo into an instrument (milestone M8). A
-- serial MIDI stream drives:
--   * pitch      : note number  -> gamma0^2 (coeffs.gamma2), README §2. Higher
--                  note -> stiffer/faster mesh -> higher pitch. A mesh mode's
--                  frequency scales with the wave speed c, and gamma2 = (c*k/h)^2
--                  scales with c^2, so one octave (x2 frequency) needs gamma2 x4:
--                  gamma2(n) = GAMMA2_REF * 2^((n-NOTE_REF)/6), clamped CFL-safe.
--   * strike     : note-on      -> a one-frame excitation impulse (the mallet)
--                  whose amplitude scales with velocity.
--   * timbre     : velocity     -> chaos coupling alpha (harder hits ring more
--                  non-linearly), between ALPHA_MIN and ALPHA_MAX.
--   * note-off (or note-on velocity 0) -> no strike; the mesh decays naturally
--                  through its damping (sigk1), exactly like a struck instrument.
--
-- The pitch table, reference note, gains, damping and CFL clamp are all
-- generics, so the mapping is documented and configurable (see docs/midi.md).
-- The block emits a full coeffs_t plus the excitation, ready to drive
-- mesh_resonator / top_resonator in place of the control-bus + I2S excitation.
--
-- `frame` is the per-audio-frame tick: a pending note-on is delivered as one
-- frame of exc_en so the mesh injects exactly one mallet impulse per note.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.fdtd_pkg.all;

entity midi_frontend is
  generic (
    CLK_HZ      : positive := 100_000_000;
    BAUD        : positive := 31_250;
    -- pitch mapping (note -> gamma2)
    NOTE_REF    : natural  := 69;        -- A4 maps to GAMMA2_REF
    GAMMA2_REF  : real     := 0.09;      -- base gamma0^2 at NOTE_REF
    GAMMA2_MIN  : real     := 0.002;     -- floor (lowest notes)
    GAMMA2_CLAMP: real     := 0.45;      -- CFL-safe ceiling (< 0.5)
    -- fixed coefficient fields
    A0          : real     := 0.99996875;
    SIGK1       : real     := 0.99996875;
    GAMMA2_MAX  : real     := 0.451;
    -- velocity mapping
    STRIKE_GAIN : real     := 0.9;       -- excitation amplitude at max velocity
    ALPHA_MIN   : real     := 0.0;       -- chaos coupling at min velocity
    ALPHA_MAX   : real     := 0.3        -- chaos coupling at max velocity
  );
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    rx       : in  std_logic;            -- serial MIDI input
    frame    : in  std_logic;            -- per-audio-frame tick
    -- to the mesh
    coeffs   : out coeffs_t;
    exc_in   : out q123_t;
    exc_en   : out std_logic;
    -- observability
    note_on  : out std_logic;            -- 1-cycle pulse: a note started
    note_off : out std_logic;            -- 1-cycle pulse: a note released
    note     : out std_logic_vector(6 downto 0);
    velocity : out std_logic_vector(6 downto 0)
  );
end entity midi_frontend;

architecture rtl of midi_frontend is

  -- precomputed pitch table: note number -> gamma2 (Q1.23), CFL-clamped
  type g2_table_t is array (0 to 127) of q123_t;
  function build_g2_table return g2_table_t is
    variable t : g2_table_t;
    variable g : real;
  begin
    for n in 0 to 127 loop
      g := GAMMA2_REF * 2.0 ** (real(n - NOTE_REF) / 6.0);
      if g > GAMMA2_CLAMP then g := GAMMA2_CLAMP; end if;
      if g < GAMMA2_MIN   then g := GAMMA2_MIN;   end if;
      t(n) := to_q123(g);
    end loop;
    return t;
  end function;
  constant G2_TABLE : g2_table_t := build_g2_table;

  constant STRIKE_Q : q123_t := to_q123(STRIKE_GAIN);
  constant AMIN_Q   : q123_t := to_q123(ALPHA_MIN);
  constant ARANGE_Q : q123_t := to_q123(ALPHA_MAX - ALPHA_MIN);

  -- scale a Q1.23 full-scale value by velocity/128 (vel in 0..127)
  function vscale(fs : q123_t; vel : unsigned) return q123_t is
    variable p : signed(fs'length + 8 - 1 downto 0);
  begin
    p := fs * signed('0' & vel);            -- non-negative product
    return resize(shift_right(p, 7), Q_BITS);
  end function;

  -- UART byte interface
  signal b_data  : std_logic_vector(7 downto 0);
  signal b_valid : std_logic;

  -- parser
  type pstate_t is (WAIT_STATUS, WAIT_D1, WAIT_D2);
  signal pstate  : pstate_t := WAIT_STATUS;
  signal is_note : std_logic := '0';       -- current status is note on/off
  signal is_on   : std_logic := '0';       -- 0x9n (on) vs 0x8n (off)
  signal d1      : unsigned(6 downto 0) := (others => '0');   -- note number

  -- excitation delivery
  signal strike_pending : std_logic := '0';

begin

  uart : entity work.midi_uart_rx
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (clk => clk, rst => rst, rx => rx, dout => b_data, dvalid => b_valid);

  process (clk)
    variable vel : unsigned(6 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pstate   <= WAIT_STATUS;
        is_note  <= '0'; is_on <= '0'; d1 <= (others => '0');
        strike_pending <= '0';
        coeffs   <= (gamma2 => to_q123(GAMMA2_REF), a0 => to_q123(A0),
                     sigk1 => to_q123(SIGK1), alpha => AMIN_Q,
                     gamma2_max => to_q123(GAMMA2_MAX));
        exc_in   <= (others => '0');
        exc_en   <= '0';
        note_on  <= '0'; note_off <= '0';
        note     <= (others => '0'); velocity <= (others => '0');
      else
        note_on  <= '0';
        note_off <= '0';

        -- deliver a pending strike as exactly one frame of exc_en
        if frame = '1' and strike_pending = '1' then
          exc_en         <= '1';
          strike_pending <= '0';
        elsif frame = '1' then
          exc_en <= '0';
        end if;

        if b_valid = '1' then
          if b_data(7) = '1' then                 -- status byte
            if b_data(7 downto 4) = "1001" then    -- 0x9n note on
              is_note <= '1'; is_on <= '1'; pstate <= WAIT_D1;
            elsif b_data(7 downto 4) = "1000" then -- 0x8n note off
              is_note <= '1'; is_on <= '0'; pstate <= WAIT_D1;
            elsif b_data(7 downto 4) = "1111" then -- system/real-time: ignore,
              null;                                --   do not disturb running status
            else                                   -- other channel message: skip
              is_note <= '0'; pstate <= WAIT_D1;
            end if;
          else                                     -- data byte (running status ok)
            case pstate is
              when WAIT_STATUS =>                   -- running status: this is D1
                d1     <= unsigned(b_data(6 downto 0));
                pstate <= WAIT_D2;
              when WAIT_D1 =>
                d1     <= unsigned(b_data(6 downto 0));
                pstate <= WAIT_D2;
              when WAIT_D2 =>
                vel := unsigned(b_data(6 downto 0));
                pstate <= WAIT_STATUS;             -- ready for running status
                if is_note = '1' then
                  note     <= std_logic_vector(d1);
                  velocity <= std_logic_vector(vel);
                  if is_on = '1' and vel /= 0 then         -- NOTE ON (strike)
                    coeffs.gamma2 <= G2_TABLE(to_integer(d1));
                    coeffs.alpha  <= sat_add(AMIN_Q, vscale(ARANGE_Q, vel));
                    exc_in        <= vscale(STRIKE_Q, vel);
                    strike_pending <= '1';
                    note_on       <= '1';
                  else                                     -- NOTE OFF (decay)
                    note_off <= '1';                       -- natural decay, no strike
                  end if;
                end if;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
