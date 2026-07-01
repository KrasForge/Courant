-------------------------------------------------------------------------------
-- cv_frontend.vhd  -  control-voltage input front-end (issue #70)
--
-- The Eurorack-native counterpart to midi_frontend (#28): drives the same
-- note-mapping interface (note events + per-note coeffs + excitation) that
-- poly_voices / synth_top consume, but from control voltage instead of MIDI:
--
--   * pitch CV (1V/oct) -> note -> gamma0^2 (coeffs.gamma2), pitch;
--   * gate rising edge  -> a note-on strike (the mallet); gate falling edge
--     -> note-off (natural decay);
--   * mod CV            -> chaos coupling alpha (timbre), amplitude stiffening.
--
-- The analog CVs are assumed already digitised by an external ADC and presented
-- synchronous to `clk` as signed samples; the gate is a logic level (from a
-- comparator) and is brought in through a two-flop synchroniser here.
--
-- Pitch calibration is by generics: note offset = (pitch_cv - CV_OFFSET) *
-- CV_SCALE >> CV_SHIFT, added to NOTE_REF and quantised to a semitone. The
-- defaults assume 4096 ADC counts per volt (per octave): CV_SCALE/2^CV_SHIFT ~
-- 1/341.3 counts-per-semitone. Trim CV_OFFSET for the 0 V note and CV_SCALE for
-- 1V/oct tracking. The note -> gamma2 map and the velocity scaling reuse the
-- same maths as midi_frontend (README §2); see docs/cv.md.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.fdtd_pkg.all;

entity cv_frontend is
  generic (
    CV_W        : positive := 16;        -- ADC sample width (signed)
    -- pitch CV calibration: note = NOTE_REF + (pitch_cv-CV_OFFSET)*CV_SCALE>>CV_SHIFT
    CV_OFFSET   : integer  := 0;
    CV_SCALE    : positive := 192;
    CV_SHIFT    : natural  := 16;
    -- pitch mapping (note -> gamma2), same as midi_frontend
    NOTE_REF    : natural  := 69;
    GAMMA2_REF  : real     := 0.09;
    GAMMA2_MIN  : real     := 0.002;
    GAMMA2_CLAMP: real     := 0.45;
    -- fixed coefficient fields
    A0          : real     := 0.99996875;
    SIGK1       : real     := 0.99996875;
    GAMMA2_MAX  : real     := 0.451;
    -- strike / timbre
    STRIKE_GAIN : real     := 0.9;       -- gate strike amplitude
    VEL_STRIKE  : natural  := 100;       -- fixed strike velocity (gate is on/off)
    ALPHA_MIN   : real     := 0.0;       -- alpha at mod CV = 0
    ALPHA_MAX   : real     := 0.3        -- alpha at mod CV = full scale
  );
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    frame    : in  std_logic;                    -- per-audio-frame tick
    pitch_cv : in  signed(CV_W-1 downto 0);      -- 1V/oct pitch (ADC)
    gate     : in  std_logic;                    -- gate / trigger (comparator)
    mod_cv   : in  signed(CV_W-1 downto 0);      -- modulation CV (ADC)
    -- note-mapping interface (to poly_voices / synth_top)
    coeffs   : out coeffs_t;
    exc_in   : out q123_t;
    exc_en   : out std_logic;
    note_on  : out std_logic;
    note_off : out std_logic;
    note     : out std_logic_vector(6 downto 0);
    velocity : out std_logic_vector(6 downto 0)
  );
end entity cv_frontend;

architecture rtl of cv_frontend is

  -- note -> gamma2 table (identical to midi_frontend), CFL-clamped
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
  function vscale(fs : q123_t; vel : natural) return q123_t is
    variable p : signed(fs'length + 8 - 1 downto 0);
  begin
    p := fs * to_signed(vel, 8);
    return resize(shift_right(p, 7), Q_BITS);
  end function;

  -- gate synchroniser + edge detect
  signal g_meta, g_sync, g_d : std_logic := '0';
  -- registered quantised note and mod-derived alpha
  signal note_q  : integer range 0 to 127 := NOTE_REF;
  signal alpha_q : q123_t := AMIN_Q;
  signal strike_pending : std_logic := '0';

begin

  process (clk)
    variable idx  : integer;
    variable prod : signed(CV_W + 20 downto 0);
    variable modf : q123_t;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        g_meta <= '0'; g_sync <= '0'; g_d <= '0';
        note_q  <= NOTE_REF;
        alpha_q <= AMIN_Q;
        strike_pending <= '0';
        coeffs  <= (gamma2 => to_q123(GAMMA2_REF), a0 => to_q123(A0),
                    sigk1 => to_q123(SIGK1), alpha => AMIN_Q,
                    gamma2_max => to_q123(GAMMA2_MAX));
        exc_in  <= (others => '0');
        exc_en  <= '0';
        note_on <= '0'; note_off <= '0';
        note    <= (others => '0'); velocity <= (others => '0');
      else
        g_meta <= gate;  g_sync <= g_meta;  g_d <= g_sync;   -- 2FF sync + delay
        note_on  <= '0';
        note_off <= '0';

        -- continuously quantise pitch CV to a note (1V/oct)
        prod := (resize(pitch_cv, CV_W+1) - to_signed(CV_OFFSET, CV_W+1))
                * to_signed(CV_SCALE, 20);
        idx  := NOTE_REF + to_integer(shift_right(prod, CV_SHIFT));
        if    idx < 0   then idx := 0;
        elsif idx > 127 then idx := 127; end if;
        note_q <= idx;

        -- mod CV (clamped to [0, full]) -> alpha in [ALPHA_MIN, ALPHA_MAX]
        if mod_cv <= 0 then
          modf := (others => '0');
        else
          -- scale mod CV so its positive full-scale (2^(CV_W-1)) maps to ~1.0
          -- in Q1.23 (2^FRAC): shift left by FRAC-(CV_W-1)
          modf := sat_q123(shift_left(resize(mod_cv, Q_BITS + 4), FRAC - (CV_W-1)));
        end if;
        alpha_q <= sat_add(AMIN_Q, q_mul(modf, ARANGE_Q));

        -- deliver a pending strike as one frame of exc_en
        if frame = '1' and strike_pending = '1' then
          exc_en <= '1'; strike_pending <= '0';
        elsif frame = '1' then
          exc_en <= '0';
        end if;

        -- gate edges: rising = strike, falling = release (natural decay)
        if g_sync = '1' and g_d = '0' then
          coeffs.gamma2     <= G2_TABLE(note_q);
          coeffs.alpha      <= alpha_q;
          coeffs.a0         <= to_q123(A0);
          coeffs.sigk1      <= to_q123(SIGK1);
          coeffs.gamma2_max <= to_q123(GAMMA2_MAX);
          exc_in            <= vscale(STRIKE_Q, VEL_STRIKE);
          note              <= std_logic_vector(to_unsigned(note_q, 7));
          velocity          <= std_logic_vector(to_unsigned(VEL_STRIKE, 7));
          strike_pending    <= '1';
          note_on           <= '1';
        elsif g_sync = '0' and g_d = '1' then
          note_off <= '1';
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
