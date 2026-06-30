-------------------------------------------------------------------------------
-- mesh_resonator.vhd  -  oversampled mesh with output decimation
--
-- Wraps grid_mesh with an oversampling sequencer and an anti-alias decimator
-- (README §2, "Aliasing ... oversampling"). The squaring non-linearity makes
-- harmonics above Nyquist; running the mesh at OS x the audio rate and
-- decimating on output pushes those images up and filters them, reducing the
-- aliasing that folds back into the audio band.
--
-- Per audio frame (one `frame` pulse):
--   * issue OS mesh strobes (each waits for the mesh's `valid`), advancing the
--     mesh OS time-steps at OS x f_s;
--   * inject the excitation `exc_in` on the first oversampled step;
--   * accumulate the stereo pickups across the OS steps, then output their
--     average (a boxcar / CIC-1 decimation low-pass) as one audio sample,
--     pulsing `out_valid`.
--
-- The averaging multiplies the OS-sample sum by the compile-time constant
-- 1/OS (to_q123), so no runtime divider is instantiated. OS is the documented
-- quality/area knob: higher OS reduces aliasing and costs OS x the mesh
-- step-cycles per frame (the decimator itself is a fixed 2 adders + 2 scales).
--
-- The coefficients on `coeffs` are expected to be precomputed for the
-- oversampled rate (gamma2 = (c*(k/OS)/h)^2, a0 = 1/(1+sigma*k/OS), etc.).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;

entity mesh_resonator is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    OS            : positive := 4;     -- oversampling factor (mesh steps / frame)
    FREE_BOUNDARY : boolean  := false
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    frame     : in  std_logic;         -- one pulse per audio sample
    coeffs    : in  coeffs_t;           -- precomputed for the OVERSAMPLED rate
    exc_in    : in  q123_t;             -- excitation sample (mallet)
    exc_en    : in  std_logic;          -- inject exc_in this frame
    out_l     : out q123_t;             -- decimated left  output
    out_r     : out q123_t;             -- decimated right output
    out_valid : out std_logic           -- pulses when out_l/out_r are updated
  );
end entity mesh_resonator;

architecture rtl of mesh_resonator is

  constant RECIP : q123_t := to_q123(1.0 / real(OS));   -- 1/OS, compile-time

  -- mesh interface
  signal m_strobe : std_logic := '0';
  signal m_exc_en : std_logic := '0';
  signal m_pick_l : q123_t;
  signal m_pick_r : q123_t;
  signal m_valid  : std_logic;

  type state_t is (IDLE, FIRE, WAITV, FINISH);
  signal state : state_t := IDLE;
  signal cnt   : integer range 0 to OS-1 := 0;
  signal suml  : acc_t := (others => '0');
  signal sumr  : acc_t := (others => '0');

begin

  mesh : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => FREE_BOUNDARY)
    port map (clk => clk, rst => rst, strobe => m_strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => m_exc_en,
              pick_l => m_pick_l, pick_r => m_pick_r, valid => m_valid);

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state     <= IDLE;
        cnt       <= 0;
        suml      <= (others => '0');
        sumr      <= (others => '0');
        m_strobe  <= '0';
        m_exc_en  <= '0';
        out_l     <= (others => '0');
        out_r     <= (others => '0');
        out_valid <= '0';
      else
        m_strobe  <= '0';     -- defaults (one-cycle pulses)
        m_exc_en  <= '0';
        out_valid <= '0';

        case state is
          when IDLE =>
            if frame = '1' then
              suml  <= (others => '0');
              sumr  <= (others => '0');
              cnt   <= 0;
              state <= FIRE;
            end if;

          when FIRE =>                       -- launch one oversampled mesh step
            m_strobe <= '1';
            if cnt = 0 then
              m_exc_en <= exc_en;            -- mallet on the first oversample step
            end if;
            state <= WAITV;

          when WAITV =>                       -- await the mesh commit, accumulate
            if m_valid = '1' then
              suml <= suml + to_acc(m_pick_l);
              sumr <= sumr + to_acc(m_pick_r);
              if cnt = OS-1 then
                state <= FINISH;
              else
                cnt   <= cnt + 1;
                state <= FIRE;
              end if;
            end if;

          when FINISH =>                      -- decimate: average the OS samples
            out_l     <= sat_store(mul_coeff(RECIP, suml));
            out_r     <= sat_store(mul_coeff(RECIP, sumr));
            out_valid <= '1';
            state     <= IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
