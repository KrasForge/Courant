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
use work.physical_pkg.all;

entity mesh_resonator is
  generic (
    NX            : positive := 8;
    NY            : positive := 8;
    EXC_X : natural := NX / 2; EXC_Y : natural := NY / 2;
    PICK_LX : natural := NX/4; PICK_LY : natural := NY/2;
    PICK_RX : natural := 3*NX/4; PICK_RY : natural := NY/2;
    OS            : positive := 4;     -- oversampling factor (mesh steps / frame)
    FREE_BOUNDARY : boolean  := false;
    BALANCED_FREE_STRIKE : boolean := false;
    HF_DAMPING : boolean := false;
    STRIKE_SHAPING : boolean := false;
    TIME_MUX      : boolean  := false  -- false: spatial mesh; true: time-multiplexed
  );
  port (
    free_mode : in boolean := FREE_BOUNDARY;
    tap_lx : in natural range 0 to NX-1 := PICK_LX;
    tap_ly : in natural range 0 to NY-1 := PICK_LY;
    tap_rx : in natural range 0 to NX-1 := PICK_RX;
    tap_ry : in natural range 0 to NY-1 := PICK_RY;
    tap_lfx,tap_lfy,tap_rfx,tap_rfy : in frac2_t := (others=>'0');
    material : in material_t := (others=>'0');
    exciter_mode : in exciter_t := (others=>'0');
    anisotropy : in aniso_t := (others=>'0');
    stiffness_ctrl : in unsigned(7 downto 0) := (others=>'0');
    hardness_ctrl : in unsigned(7 downto 0) := (others=>'0');
    rim_ctrl,strike_size : in unsigned(7 downto 0) := (others=>'0');
    strike_x : in natural range 0 to NX-1 := EXC_X;
    strike_y : in natural range 0 to NY-1 := EXC_Y;
    strike_fx,strike_fy : in frac2_t := (others=>'0');
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
  signal m_exc_in : q123_t := Q123_ZERO;
  signal m_mallet_enable : std_logic := '0';
  signal m_sfx,m_sfy : frac2_t := (others=>'0');
  signal m_pick_l : q123_t;
  signal m_pick_r : q123_t;
  signal m_valid  : std_logic;

  type state_t is (IDLE, FIRE, WAITV, FINISH);
  signal state : state_t := IDLE;
  signal cnt   : integer range 0 to OS-1 := 0;
  signal suml  : acc_t := (others => '0');
  signal sumr  : acc_t := (others => '0');

  function shaped_strike(x:q123_t; phase:natural; mode:exciter_t) return q123_t is
    variable mag:integer; variable a:acc_t;
  begin
    case to_integer(mode) is
      when 1 => if phase=0 then return x; else return Q123_ZERO; end if;
      when 2 => if phase<=1 then return sat_store(shift_right(to_acc(x),1)); else return Q123_ZERO; end if;
      when 3 => if phase=0 then return x; elsif phase=1 then return sat_store(-shift_right(to_acc(x),1)); else return Q123_ZERO; end if;
      when 4 => if phase=0 then return x; elsif phase=1 then return sat_store(-shift_right(to_acc(x),2)); else return Q123_ZERO; end if;
      when 5 =>
        case phase is
          when 0 => return sat_store(shift_right(to_acc(x),1));
          when 1 => return sat_store(-shift_right(to_acc(x),2));
          when 2 => return sat_store(shift_right(to_acc(x),2));
          when 3 => return sat_store(-shift_right(to_acc(x),3));
          when others => return Q123_ZERO;
        end case;
      when others => null;
    end case;
    mag:=to_integer(x); if mag<0 then mag:=-mag; end if;
    if phase>1 then return Q123_ZERO; end if;
    if mag<2**21 then return sat_store(shift_right(to_acc(x),1));
    elsif mag<2**22 then
      if phase=0 then a:=to_acc(x)-shift_right(to_acc(x),2); return sat_store(a);
      else return sat_store(shift_right(to_acc(x),2)); end if;
    else
      if phase=0 then return x; else return sat_store(-shift_right(to_acc(x),2)); end if;
    end if;
  end function;

begin

  -- HARDNESS=0 is an exact legacy bypass. With nonzero HARDNESS, AUTO or the
  -- explicit soft/mallet character selects the stateful physical contact;
  -- point/pluck/rim/scrape modes keep their existing shaped envelopes.
  m_mallet_enable <= '1' when STRIKE_SHAPING and hardness_ctrl/=0 and
                     (exciter_mode=to_unsigned(0,3) or exciter_mode=to_unsigned(2,3))
                     else '0';

  mesh : entity work.mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => FREE_BOUNDARY, BALANCED_FREE_STRIKE => BALANCED_FREE_STRIKE,
                 HF_DAMPING=>HF_DAMPING, TIME_MUX => TIME_MUX, EXC_X => EXC_X, EXC_Y => EXC_Y)
    port map (free_mode => free_mode, tap_lx => tap_lx, tap_ly => tap_ly,
              tap_rx => tap_rx, tap_ry => tap_ry,
              tap_lfx=>tap_lfx,tap_lfy=>tap_lfy,tap_rfx=>tap_rfx,tap_rfy=>tap_rfy,
              material=>material,anisotropy=>anisotropy,stiffness_ctrl=>stiffness_ctrl,
              hardness_ctrl=>hardness_ctrl,mallet_enable=>m_mallet_enable,
              rim_ctrl=>rim_ctrl,strike_size=>strike_size,
              strike_x=>strike_x,strike_y=>strike_y,strike_fx=>m_sfx,strike_fy=>m_sfy,
              clk => clk, rst => rst, strobe => m_strobe, coeffs => coeffs,
              exc_in => m_exc_in, exc_en => m_exc_en,
              pick_l => m_pick_l, pick_r => m_pick_r, valid => m_valid);

  process (clk)
    variable mode_eff:exciter_t;
    variable fxv,fyv:frac2_t;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state     <= IDLE;
        cnt       <= 0;
        suml      <= (others => '0');
        sumr      <= (others => '0');
        m_strobe  <= '0';
        m_exc_en  <= '0';
        m_exc_in  <= Q123_ZERO; m_sfx<=(others=>'0'); m_sfy<=(others=>'0');
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
            mode_eff:=effective_exciter(exciter_mode,material);
            fxv:=strike_fx; fyv:=strike_fy;
            if EXC_X>=NX-1 then fxv:=(others=>'0'); end if;
            if EXC_Y>=NY-1 then fyv:=(others=>'0'); end if;
            if mode_eff=to_unsigned(1,3) then fxv:=(others=>'0'); fyv:=(others=>'0');
            elsif m_mallet_enable='0' and mode_eff=to_unsigned(2,3) and strike_fx=0 and strike_fy=0 then
              fxv:=to_unsigned(2,2); fyv:=to_unsigned(2,2);
            end if;
            m_sfx<=fxv; m_sfy<=fyv;
            if m_mallet_enable='1' then
              -- Trigger the hammer once; force then persists from its own state
              -- across later oversample steps and audio frames.
              m_exc_in<=exc_in;
              if cnt=0 and exc_en='1' then m_exc_en<='1'; else m_exc_en<='0'; end if;
            elsif STRIKE_SHAPING and exc_en='1' then
              m_exc_in<=shaped_strike(exc_in,cnt,mode_eff);
              if shaped_strike(exc_in,cnt,mode_eff)/=Q123_ZERO then m_exc_en<='1'; else m_exc_en<='0'; end if;
            elsif cnt=0 then
              m_exc_en<=exc_en; m_exc_in<=exc_in;
            else
              m_exc_en<='0'; m_exc_in<=Q123_ZERO;
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
