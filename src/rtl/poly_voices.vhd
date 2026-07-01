-------------------------------------------------------------------------------
-- poly_voices.vhd  -  polyphonic voice pool: allocate, run, mix (issue #29)
--
-- A configurable pool of NVOICES independent resonator voices (milestone M8).
-- Each voice is a full mesh_resonator with its own state and coefficients, so
-- voices are genuinely independent (different pitch/timbre, overlapping decays).
-- The input is the note-mapping interface shared by the MIDI and CV front-ends
-- (note-on/off events plus the current note's coeffs and strike amplitude), so
-- this pool is independent of the control source.
--
--   note event ---> voice_allocator ---> pick/steal a voice, strike it
--                                    \--> latch that note's coeffs + excitation
--                                         into the chosen voice
--   NVOICES x mesh_resonator (each fires its own strike, decays independently)
--   mixer: average the voices' stereo pickups into one stereo output
--
-- Voice count is a synthesis-time knob traded against DSP/LUT and the per-sample
-- cycle budget: fully-spatial voices cost NVOICES x the mesh area, while
-- TIME_MUX voices fold each mesh through one PE pool (issue #24) so the whole
-- pool fits a small device at the cost of cycles. See docs/polyphony.md.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity poly_voices is
  generic (
    NVOICES       : positive := 4;
    NX            : positive := 8;
    NY            : positive := 8;
    OS            : positive := 4;
    FREE_BOUNDARY : boolean  := false;
    TIME_MUX      : boolean  := false
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    frame     : in  std_logic;                     -- per-audio-frame tick
    -- note-mapping interface (from midi_frontend / a CV mapper)
    note_on   : in  std_logic;
    note_off  : in  std_logic;
    note      : in  std_logic_vector(6 downto 0);
    coeffs_in : in  coeffs_t;                       -- current note's coefficients
    exc_in    : in  q123_t;                         -- current note's strike level
    -- mixed stereo output
    out_l     : out q123_t;
    out_r     : out q123_t;
    out_valid : out std_logic;
    -- observability: which voices are allocated
    active    : out std_logic_vector(NVOICES-1 downto 0)
  );
end entity poly_voices;

architecture rtl of poly_voices is

  constant RECIP  : q123_t  := to_q123(1.0 / real(NVOICES));   -- mix gain 1/NV
  constant REST_C : coeffs_t := (others => (others => '0'));

  type coeffs_arr is array (0 to NVOICES-1) of coeffs_t;
  type q123_arr   is array (0 to NVOICES-1) of q123_t;

  signal vcoeffs : coeffs_arr := (others => REST_C);
  signal vexc    : q123_arr   := (others => (others => '0'));
  signal vexc_en : std_logic_vector(NVOICES-1 downto 0) := (others => '0');
  signal vpend   : std_logic_vector(NVOICES-1 downto 0) := (others => '0');
  signal vout_l  : q123_arr;
  signal vout_r  : q123_arr;
  signal vout_v  : std_logic_vector(NVOICES-1 downto 0);

  signal strike_voice : integer range 0 to NVOICES-1;
  signal strike       : std_logic;

begin

  ----------------------------------------------------------------------------
  -- voice allocation / stealing
  ----------------------------------------------------------------------------
  alloc : entity work.voice_allocator
    generic map (NVOICES => NVOICES)
    port map (clk => clk, rst => rst, note_on => note_on, note_off => note_off,
              note => note, strike_voice => strike_voice, strike => strike,
              active => active);

  ----------------------------------------------------------------------------
  -- per-voice coefficient/excitation capture + one-frame strike delivery
  ----------------------------------------------------------------------------
  capture : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        vcoeffs <= (others => REST_C);
        vexc    <= (others => (others => '0'));
        vexc_en <= (others => '0');
        vpend   <= (others => '0');
      else
        if strike = '1' then                       -- latch this note into its voice
          vcoeffs(strike_voice) <= coeffs_in;
          vexc(strike_voice)    <= exc_in;
          vpend(strike_voice)   <= '1';
        end if;

        -- deliver each pending strike as one frame of exc_en
        if frame = '1' then
          for v in 0 to NVOICES-1 loop
            if vpend(v) = '1' then
              vexc_en(v) <= '1';
              vpend(v)   <= '0';
            else
              vexc_en(v) <= '0';
            end if;
          end loop;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- the voices: NVOICES independent resonators
  ----------------------------------------------------------------------------
  voices : for v in 0 to NVOICES-1 generate
    u_voice : entity work.mesh_resonator
      generic map (NX => NX, NY => NY, OS => OS,
                   FREE_BOUNDARY => FREE_BOUNDARY, TIME_MUX => TIME_MUX)
      port map (clk => clk, rst => rst, frame => frame, coeffs => vcoeffs(v),
                exc_in => vexc(v), exc_en => vexc_en(v),
                out_l => vout_l(v), out_r => vout_r(v), out_valid => vout_v(v));
  end generate;

  ----------------------------------------------------------------------------
  -- mixer: average the voices' pickups (all share `frame`, so vout_v aligns)
  ----------------------------------------------------------------------------
  mixer : process (clk)
    variable al, ar : acc_t;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        out_l     <= (others => '0');
        out_r     <= (others => '0');
        out_valid <= '0';
      else
        out_valid <= vout_v(0);
        if vout_v(0) = '1' then
          al := (others => '0');
          ar := (others => '0');
          for v in 0 to NVOICES-1 loop
            al := al + to_acc(vout_l(v));
            ar := ar + to_acc(vout_r(v));
          end loop;
          out_l <= sat_store(mul_coeff(RECIP, al));
          out_r <= sat_store(mul_coeff(RECIP, ar));
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
