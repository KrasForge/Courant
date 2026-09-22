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
use work.physical_pkg.all;

entity poly_voices is
  generic (
    MUSICAL_VOICES : boolean := false;
    NVOICES       : positive := 4;
    NX            : positive := 8;
    NY            : positive := 8;
    OS            : positive := 4;
    FREE_BOUNDARY : boolean  := false;
    TIME_MUX      : boolean  := false
  );
  port (
    free_mode : in boolean := FREE_BOUNDARY;
    tap_lx : in natural range 0 to NX-1 := NX/4;
    tap_ly : in natural range 0 to NY-1 := NY/2;
    tap_rx : in natural range 0 to NX-1 := 3*NX/4;
    tap_ry : in natural range 0 to NY-1 := NY/2;
    tap_lfx,tap_lfy,tap_rfx,tap_rfy : in frac2_t := (others=>'0');
    material : in material_t := (others=>'0');
    exciter_mode : in exciter_t := (others=>'0');
    anisotropy : in aniso_t := (others=>'0');
    stiffness_ctrl : in unsigned(7 downto 0) := (others=>'0');
    hardness_ctrl : in unsigned(7 downto 0) := (others=>'0');
    rim_ctrl,strike_size : in unsigned(7 downto 0) := (others=>'0');
    strike_x : in natural range 0 to NX-1 := NX/3;
    strike_y : in natural range 0 to NY-1 := NY/3;
    strike_fx,strike_fy : in frac2_t := (others=>'0');
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

  type bool_arr is array (0 to NVOICES-1) of boolean;
  type x_arr is array (0 to NVOICES-1) of natural range 0 to NX-1;
  type y_arr is array (0 to NVOICES-1) of natural range 0 to NY-1;
  type fade_arr is array (0 to NVOICES-1) of natural range 0 to 32;
  type frac_arr is array (0 to NVOICES-1) of frac2_t;
  type material_arr is array (0 to NVOICES-1) of material_t;
  type exciter_arr is array (0 to NVOICES-1) of exciter_t;
  type aniso_arr is array (0 to NVOICES-1) of aniso_t;
  type byte_arr2 is array (0 to NVOICES-1) of unsigned(7 downto 0);
  signal vf : bool_arr := (others=>FREE_BOUNDARY);
  signal vlx : x_arr := (others=>NX/4); signal vrx : x_arr := (others=>3*NX/4);
  signal vly, vry : y_arr := (others=>NY/2);
  signal vlfx,vlfy,vrfx,vrfy,vsfx,vsfy : frac_arr := (others=>(others=>'0'));
  signal vmat : material_arr := (others=>(others=>'0'));
  signal vexmode : exciter_arr := (others=>(others=>'0'));
  signal vaniso : aniso_arr := (others=>(others=>'0'));
  signal vstiff,vhard,vrim,vsize : byte_arr2 := (others=>(others=>'0'));
  signal vsx : x_arr := (others=>NX/3); signal vsy : y_arr := (others=>NY/3);
  signal fade : fade_arr := (others=>32);
  signal carry_l, carry_r : q123_arr := (others=>Q123_ZERO);
  signal voice_reset, reset_pulse : std_logic_vector(NVOICES-1 downto 0) := (others=>'0');
  signal strike_voice : integer range 0 to NVOICES-1;
  signal strike       : std_logic;
  signal human_lfsr : unsigned(15 downto 0) := x"ACE1";

  function jitter_coord(base:natural; lim:positive; code:unsigned(1 downto 0)) return natural is
    variable b:integer:=integer(base); variable d:integer:=0;
  begin
    case to_integer(code) is when 0=>d:=-1; when 2=>d:=1; when others=>d:=0; end case;
    b:=b+d; if b<0 then b:=0; end if; if b>=lim then b:=lim-1; end if;
    return natural(b);
  end function;
  function vary_strike(x:q123_t; up:boolean) return q123_t is
    variable a:acc_t:=to_acc(x); variable d:acc_t;
  begin
    d:=shift_right(a,5); -- +/-3.125%, deterministic pseudo-human variation
    if up then return sat_store(a+d); else return sat_store(a-d); end if;
  end function;

  type mix_state_t is (MIX_IDLE,MIX_LEFT,MIX_RIGHT,MIX_OUT);
  signal mix_state : mix_state_t := MIX_IDLE;
  signal mix_idx : integer range 0 to NVOICES-1 := 0;
  signal mix_al,mix_ar : acc_t := (others=>'0');
  signal fade_diff : signed(24 downto 0) := (others=>'0');
  signal fade_gain : signed(6 downto 0) := (others=>'0');
  signal fade_product : signed(31 downto 0);

begin
  -- One shared 25x7 multiply services every fading voice/channel over a few
  -- spare system clocks after the aligned mesh outputs. A DSP48 handles this
  -- efficiently; normal (fully faded-in) voices bypass it entirely.
  fade_product <= fade_diff * fade_gain;

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
        reset_pulse<=(others=>'0'); fade<=(others=>32);
        carry_l<=(others=>Q123_ZERO);carry_r<=(others=>Q123_ZERO);
        vf<=(others=>FREE_BOUNDARY); human_lfsr<=x"ACE1";
        vlfx<=(others=>(others=>'0')); vlfy<=(others=>(others=>'0'));
        vrfx<=(others=>(others=>'0')); vrfy<=(others=>(others=>'0'));
        vsfx<=(others=>(others=>'0')); vsfy<=(others=>(others=>'0'));
        vmat<=(others=>(others=>'0')); vexmode<=(others=>(others=>'0')); vaniso<=(others=>(others=>'0'));
        vstiff<=(others=>(others=>'0'));vhard<=(others=>(others=>'0'));
        vrim<=(others=>(others=>'0'));vsize<=(others=>(others=>'0'));
        vsx<=(others=>NX/3);vsy<=(others=>NY/3);
      else
        reset_pulse<=(others=>'0');
        -- deliver each pending strike as one frame of exc_en
        if frame = '1' then
          for v in 0 to NVOICES-1 loop
            if fade(v)<32 then fade(v)<=fade(v)+1; end if;
            if vpend(v) = '1' then
              vexc_en(v) <= '1';
              vpend(v)   <= '0';
            else
              vexc_en(v) <= '0';
            end if;
          end loop;
        end if;
        -- An arriving event wins over pending-strike consumption on this clock.
        if strike = '1' then                       -- latch this note into its voice
          vcoeffs(strike_voice) <= coeffs_in;
          if MUSICAL_VOICES then
            vexc(strike_voice)<=vary_strike(exc_in,human_lfsr(0)='1');
          else vexc(strike_voice)<=exc_in; end if;
          vpend(strike_voice)   <= '1';
        end if;

        if strike='1' then
          vf(strike_voice)<=free_mode;
          vlfx(strike_voice)<=tap_lfx; vlfy(strike_voice)<=tap_lfy;
          vrfx(strike_voice)<=tap_rfx; vrfy(strike_voice)<=tap_rfy;
          vsfx(strike_voice)<=strike_fx; vsfy(strike_voice)<=strike_fy;
          vmat(strike_voice)<=material; vexmode(strike_voice)<=exciter_mode;
          vaniso(strike_voice)<=anisotropy; vstiff(strike_voice)<=stiffness_ctrl;
          vhard(strike_voice)<=hardness_ctrl;
          vrim(strike_voice)<=rim_ctrl; vsize(strike_voice)<=strike_size;
          vsx(strike_voice)<=strike_x; vsy(strike_voice)<=strike_y;
          if MUSICAL_VOICES then
            -- Tiny deterministic pickup motion prevents repeated strikes from
            -- producing an identical modal/stereo fingerprint.
            vlx(strike_voice)<=jitter_coord(tap_lx,NX,human_lfsr(2 downto 1));
            vly(strike_voice)<=jitter_coord(tap_ly,NY,human_lfsr(4 downto 3));
            vrx(strike_voice)<=jitter_coord(tap_rx,NX,human_lfsr(6 downto 5));
            vry(strike_voice)<=jitter_coord(tap_ry,NY,human_lfsr(8 downto 7));
            human_lfsr<=human_lfsr(14 downto 0) &
                        (human_lfsr(15) xor human_lfsr(13) xor human_lfsr(12) xor human_lfsr(10));
          else
            vlx(strike_voice)<=tap_lx; vly(strike_voice)<=tap_ly;
            vrx(strike_voice)<=tap_rx; vry(strike_voice)<=tap_ry;
          end if;
          if MUSICAL_VOICES then
            reset_pulse(strike_voice)<='1'; fade(strike_voice)<=0;
            carry_l(strike_voice)<=vout_l(strike_voice);
            carry_r(strike_voice)<=vout_r(strike_voice);
            vexc_en(strike_voice)<='0';
          end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- the voices: NVOICES independent resonators
  ----------------------------------------------------------------------------
  voices : for v in 0 to NVOICES-1 generate
    voice_reset(v)<=rst or reset_pulse(v);
    u_voice : entity work.mesh_resonator
      generic map (NX => NX, NY => NY, OS => OS,
                   FREE_BOUNDARY => FREE_BOUNDARY, TIME_MUX => TIME_MUX,
                   HF_DAMPING=>MUSICAL_VOICES, STRIKE_SHAPING=>MUSICAL_VOICES,
                   EXC_X=>NX/3,EXC_Y=>NY/3,BALANCED_FREE_STRIKE=>MUSICAL_VOICES)
      port map (free_mode=>vf(v), tap_lx=>vlx(v),tap_ly=>vly(v),tap_rx=>vrx(v),tap_ry=>vry(v),
                tap_lfx=>vlfx(v),tap_lfy=>vlfy(v),tap_rfx=>vrfx(v),tap_rfy=>vrfy(v),
                material=>vmat(v),exciter_mode=>vexmode(v),anisotropy=>vaniso(v),
                stiffness_ctrl=>vstiff(v),hardness_ctrl=>vhard(v),
                rim_ctrl=>vrim(v),strike_size=>vsize(v),
                strike_x=>vsx(v),strike_y=>vsy(v),
                strike_fx=>vsfx(v),strike_fy=>vsfy(v),
                clk => clk, rst => voice_reset(v), frame => frame, coeffs => vcoeffs(v),
                exc_in => vexc(v), exc_en => vexc_en(v),
                out_l => vout_l(v), out_r => vout_r(v), out_valid => vout_v(v));
  end generate;

  ----------------------------------------------------------------------------
  -- mixer: average the voices' pickups (all share `frame`, so vout_v aligns)
  ----------------------------------------------------------------------------
  fade_select : process(all)
    variable d : signed(24 downto 0);
  begin
    fade_diff <= (others=>'0'); fade_gain <= (others=>'0');
    d := (others=>'0');
    if MUSICAL_VOICES and fade(mix_idx)<32 then
      if mix_state=MIX_LEFT then
        d:=resize(vout_l(mix_idx),25)-resize(carry_l(mix_idx),25);
      elsif mix_state=MIX_RIGHT then
        d:=resize(vout_r(mix_idx),25)-resize(carry_r(mix_idx),25);
      end if;
      fade_diff<=d;
      fade_gain<=signed('0' & std_logic_vector(to_unsigned(fade(mix_idx),6)));
    end if;
  end process;

  mixer : process(clk)
    variable interp : acc_t;
  begin
    if rising_edge(clk) then
      out_valid<='0';
      if rst='1' then
        out_l<=Q123_ZERO; out_r<=Q123_ZERO;
        mix_state<=MIX_IDLE; mix_idx<=0;
        mix_al<=(others=>'0'); mix_ar<=(others=>'0');
      else
        case mix_state is
          when MIX_IDLE =>
            if vout_v(0)='1' then
              mix_al<=(others=>'0'); mix_ar<=(others=>'0'); mix_idx<=0;
              mix_state<=MIX_LEFT;
            end if;
          when MIX_LEFT =>
            if MUSICAL_VOICES and fade(mix_idx)<32 then
              interp:=to_acc(carry_l(mix_idx))+resize(shift_right(fade_product,5),ACC_BITS);
              mix_al<=mix_al+interp;
            else mix_al<=mix_al+to_acc(vout_l(mix_idx)); end if;
            mix_state<=MIX_RIGHT;
          when MIX_RIGHT =>
            if MUSICAL_VOICES and fade(mix_idx)<32 then
              interp:=to_acc(carry_r(mix_idx))+resize(shift_right(fade_product,5),ACC_BITS);
              mix_ar<=mix_ar+interp;
            else mix_ar<=mix_ar+to_acc(vout_r(mix_idx)); end if;
            if mix_idx=NVOICES-1 then mix_state<=MIX_OUT;
            else mix_idx<=mix_idx+1; mix_state<=MIX_LEFT; end if;
          when MIX_OUT =>
            out_l<=sat_store(mul_coeff(RECIP,mix_al));
            out_r<=sat_store(mul_coeff(RECIP,mix_ar));
            out_valid<='1'; mix_state<=MIX_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
