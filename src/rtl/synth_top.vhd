-------------------------------------------------------------------------------
-- synth_top.vhd  -  end-to-end playable synth (MIDI -> polyphony -> codec) (#68)
--
-- Ties the M8 building blocks into one top-level instrument:
--
--   MIDI in --> [sync] --> midi_frontend --> note events + per-note coeffs/exc
--                                    \                 |
--            preset_bank --> base coeffs (a0/sigk1/gamma2_max, decay/CFL)
--                                          |
--                          merge (note pitch/timbre + preset body) --> coeffs
--                                          v
--                    poly_voices (NVOICES independent meshes + mix) --> L/R
--                                          v
--                    pickup CDC (system -> audio clock) --> i2s_transceiver TX
--                                          v
--                                       sd_tx --> codec DAC
--
--   i2s_clkgen (I2S MASTER): from the audio master clock `mclk` it generates
--   MCLK/BCLK/LRCLK for the codec; sample_strobe crosses LRCLK back into the
--   system clock as the per-audio-frame `frame` that advances the mesh.
--
-- Two clock domains: the system clock (mesh, MIDI, presets) and the audio I2S
-- clock (transceiver). The only crossings are the pickup word (cdc_word) and the
-- LRCLK->frame strobe (sample_strobe); a single global reset is used for both
-- (sufficient for simulation, synchronise per-domain for a real build).
--
-- Musical merge: the calibrated note supplies base pitch and strike; normalized
-- preset TENSION retunes it, while DECAY / independent CHAOS / pickup positions /
-- boundary mode come from the live preset. A 20 Hz DC blocker conditions the
-- mixed pickup, then the preset-controlled stereo FX chain runs before I2S CDC.
--
-- Output-only (a synth voice): the codec ADC input is unused (sd_rx tied off).
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fdtd_pkg.all;
use work.musical_pkg.all;
use work.physical_pkg.all;
use ieee.math_real.all;

entity synth_top is
  generic (
    FS_HZ : positive := 48_000;
    OUTPUT_GAIN_SHIFT : natural := 5;
    -- voices / mesh
    NVOICES       : positive := 4;
    NX            : positive := 8;
    NY            : positive := 8;
    OS            : positive := 4;
    FREE_BOUNDARY : boolean  := false;
    TIME_MUX      : boolean  := false;
    -- MIDI UART (system-clock rate / MIDI baud)
    CLK_HZ        : positive := 100_000_000;
    BAUD          : positive := 31_250;
    -- I2S clock division from the audio master clock
    MCLK_TO_BCLK  : positive := 4;
    BCLK_TO_LRCK  : positive := 64;
    -- control-voltage ADC width
    CV_W          : positive := 16
  );
  port (
    -- system (mesh / control) domain
    sys_clk      : in  std_logic;
    sys_rst      : in  std_logic;
    -- audio master clock (e.g. 12.288 MHz from an MMCM)
    mclk         : in  std_logic;
    -- serial MIDI in
    midi_rx      : in  std_logic;
    -- CV input; cv_sel='1' is a legacy/debug force-CV override. Normal board
    -- operation leaves it low and AUTO arbitration follows note/gate activity.
    cv_sel       : in  std_logic := '0';
    pitch_cv     : in  signed(CV_W-1 downto 0) := (others => '0');
    gate         : in  std_logic := '0';
    mod_cv       : in  signed(CV_W-1 downto 0) := (others => '0');
    -- preset control (system domain)
    preset_index : in  unsigned(3 downto 0) := (others => '0');
    preset_recall: in  std_logic := '0';
    preset_save  : in  std_logic := '0';
    -- register edit / read-back (system domain)
    cfg_wr_en    : in  std_logic := '0';
    cfg_wr_addr  : in  unsigned(3 downto 0) := (others => '0');
    cfg_wr_data  : in  std_logic_vector(23 downto 0) := (others => '0');
    cfg_rd_addr  : in  unsigned(3 downto 0) := (others => '0');
    cfg_rd_data  : out std_logic_vector(23 downto 0);
    -- codec pins (audio domain)
    codec_mclk   : out std_logic;
    codec_bclk   : out std_logic;
    codec_lrclk  : out std_logic;
    sd_tx        : out std_logic;         -- audio to the DAC
    -- observability
    active       : out std_logic_vector(NVOICES-1 downto 0)
  );
end entity synth_top;

architecture rtl of synth_top is

  signal p_lx, p_ly, p_rx, p_ry : unsigned(7 downto 0) := (others=>'0');
  signal p_free : std_logic := '0';
  signal p_phys : std_logic_vector(23 downto 0) := (others=>'0');
  signal p_material : material_t := (others=>'0');
  signal p_exciter : exciter_t := (others=>'0');
  signal p_aniso : aniso_t := (others=>'0');
  signal p_stiffness,p_hardness,p_rim,p_strike_size,p_strike_xc,p_strike_yc : unsigned(7 downto 0):=(others=>'0');
  signal p_strike_fx,p_strike_fy : frac2_t := (others=>'0');
  signal p_strike_x : natural range 0 to NX-1 := NX/3;
  signal p_strike_y : natural range 0 to NY-1 := NY/3;
  signal p_source_mode : unsigned(1 downto 0):=(others=>'0');
  signal auto_cv,source_cv : std_logic:='0';
  signal p_lfx,p_lfy,p_rfx,p_rfy : frac2_t := (others=>'0');
  signal free_selected : boolean;
  signal dc_xl, dc_xr : q123_t := Q123_ZERO;
  signal dc_yl, dc_yr : acc_t := (others=>'0');
  signal audio_l, audio_r : q123_t := Q123_ZERO;
  signal audio_valid : std_logic := '0';
  signal fx_l, fx_r : q123_t := Q123_ZERO;
  signal fx_valid : std_logic := '0';
  signal fx_ctrl0, fx_ctrl1, fx_ctrl2 : std_logic_vector(23 downto 0);
  signal fx_ctrl3, fx_ctrl4, fx_ctrl5 : std_logic_vector(23 downto 0);
  constant DC_R : q123_t := to_q123(exp(-2.0*MATH_PI*20.0/real(FS_HZ)));
  -- generated I2S clocks (audio domain)
  signal bclk_i, lrclk_i : std_logic;

  -- per-audio-frame strobe (system domain)
  signal frame : std_logic;

  -- MIDI input synchroniser (into system clock)
  signal rx_meta, rx_sync : std_logic := '1';

  -- midi_frontend outputs (note mapping)
  signal m_coeffs   : coeffs_t;
  signal m_exc_in   : q123_t;
  signal m_exc_en   : std_logic;
  signal m_note_on  : std_logic;
  signal m_note_off : std_logic;
  signal m_note     : std_logic_vector(6 downto 0);
  signal m_vel      : std_logic_vector(6 downto 0);

  -- cv_frontend outputs (note mapping)
  signal c_coeffs   : coeffs_t;
  signal c_exc_in   : q123_t;
  signal c_note_on  : std_logic;
  signal c_note_off : std_logic;
  signal c_note     : std_logic_vector(6 downto 0);

  -- selected source (MIDI or CV) feeding the voices
  signal s_coeffs   : coeffs_t;
  signal s_exc_in   : q123_t;
  signal s_note_on  : std_logic;
  signal s_note_off : std_logic;
  signal s_note     : std_logic_vector(6 downto 0);

  -- preset_bank base coefficients
  signal p_coeffs : coeffs_t;

  -- merged voice coefficients (note pitch/timbre + preset body)
  signal v_coeffs : coeffs_t;
  signal tuned_gamma2, chaos_ctl : q123_t := Q123_ZERO;

  -- polyphonic mix (system domain)
  signal mix_l, mix_r : q123_t;
  signal mix_valid    : std_logic;

  -- pickup CDC (system -> audio)
  signal pick_src : std_logic_vector(47 downto 0);
  signal pick_dst : std_logic_vector(47 downto 0);
  signal tx_l, tx_r : q123_t;

  function strike_qcode(c:unsigned(7 downto 0); lim:positive) return natural is
    variable q,m:natural;
  begin
    m:=(lim-1)*4;
    if is_x(std_logic_vector(c)) then q:=4*(lim/3);
    elsif lim=8 then q:=to_integer(c(7 downto 3));
    else q:=(to_integer(c)*m+127)/255; end if;
    if q>m then q:=m; end if; return q;
  end;
  function strike_base(c:unsigned(7 downto 0); lim:positive) return natural is
  begin return strike_qcode(c,lim)/4; end;
  function strike_frac(c:unsigned(7 downto 0); lim:positive) return frac2_t is
  begin return to_unsigned(strike_qcode(c,lim) mod 4,2); end;

begin
  assert NX >= 4 and NY >= 4 report "Musical synth requires NX/NY >= 4" severity failure;
  assert OUTPUT_GAIN_SHIFT <= 8 report "Excessive output gain" severity failure;
  free_selected <= p_free = '1';
  p_material<=unsigned(p_phys(3 downto 1));
  p_exciter<=unsigned(p_phys(6 downto 4));
  p_aniso<=signed(p_phys(10 downto 7));
  p_source_mode<=unsigned(p_phys(12 downto 11)) when not is_x(p_phys(12 downto 11)) else "00";
  p_strike_x<=strike_base(p_strike_xc,NX); p_strike_y<=strike_base(p_strike_yc,NY);
  p_strike_fx<=strike_frac(p_strike_xc,NX); p_strike_fy<=strike_frac(p_strike_yc,NY);
  p_lfx<=unsigned(p_phys(16 downto 15)); p_lfy<=unsigned(p_phys(18 downto 17));
  p_rfx<=unsigned(p_phys(20 downto 19)); p_rfy<=unsigned(p_phys(22 downto 21));

  ----------------------------------------------------------------------------
  -- I2S master clock generation + codec clock pins
  ----------------------------------------------------------------------------
  clkgen : entity work.i2s_clkgen
    generic map (MCLK_TO_BCLK => MCLK_TO_BCLK, BCLK_TO_LRCK => BCLK_TO_LRCK)
    port map (mclk => mclk, rst => sys_rst,
              mclk_o => codec_mclk, bclk => bclk_i, lrclk => lrclk_i);
  codec_bclk  <= bclk_i;
  codec_lrclk <= lrclk_i;

  ----------------------------------------------------------------------------
  -- per-audio-frame strobe: LRCLK -> system-clock `frame`
  ----------------------------------------------------------------------------
  strobe : entity work.sample_strobe
    port map (sys_clk => sys_clk, rst => sys_rst, lrclk => lrclk_i, frame => frame);

  ----------------------------------------------------------------------------
  -- MIDI input two-flop synchroniser (async serial -> system clock)
  ----------------------------------------------------------------------------
  sync_proc : process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      if sys_rst = '1' then
        rx_meta <= '1'; rx_sync <= '1';
      else
        rx_meta <= midi_rx;
        rx_sync <= rx_meta;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- MIDI front-end: note -> pitch / strike / timbre
  ----------------------------------------------------------------------------
  midi : entity work.midi_frontend
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD, NX=>NX, NY=>NY, OS=>OS, FS_HZ=>FS_HZ)
    port map (free_mode=>free_selected, clk => sys_clk, rst => sys_rst, rx => rx_sync, frame => frame,
              coeffs => m_coeffs, exc_in => m_exc_in, exc_en => m_exc_en,
              note_on => m_note_on, note_off => m_note_off,
              note => m_note, velocity => m_vel);

  ----------------------------------------------------------------------------
  -- CV front-end: pitch/gate/mod -> note mapping (same interface as MIDI)
  ----------------------------------------------------------------------------
  cv : entity work.cv_frontend
    generic map (CV_W => CV_W, NX=>NX, NY=>NY, OS=>OS, FS_HZ=>FS_HZ)
    port map (free_mode=>free_selected, clk => sys_clk, rst => sys_rst, frame => frame,
              pitch_cv => pitch_cv, gate => gate, mod_cv => mod_cv,
              coeffs => c_coeffs, exc_in => c_exc_in, exc_en => open,
              note_on => c_note_on, note_off => c_note_off,
              note => c_note, velocity => open);

  -- AUTO source arbitration: the newest note-on/gate edge claims the source.
  -- Register-9 source mode: 00/11=AUTO, 01=force MIDI, 10=force CV.
  source_claim : process(sys_clk)
  begin
    if rising_edge(sys_clk) then
      if sys_rst='1' then auto_cv<='0';
      elsif m_note_on='1' then auto_cv<='0';
      elsif c_note_on='1' then auto_cv<='1'; end if;
    end if;
  end process;
  source_cv <= '1' when cv_sel='1' or p_source_mode="10" else
               '0' when p_source_mode="01" else
               '1' when c_note_on='1' and m_note_on='0' else
               '0' when m_note_on='1' else auto_cv;
  s_coeffs   <= c_coeffs   when source_cv='1' else m_coeffs;
  s_exc_in   <= c_exc_in   when source_cv='1' else m_exc_in;
  s_note_on  <= c_note_on  when source_cv='1' else m_note_on;
  -- Releases from the inactive source still free their allocated voice.
  s_note_off <= c_note_off or m_note_off;
  s_note <= c_note when c_note_on='1' or (c_note_off='1' and m_note_on='0' and m_note_off='0') else
            m_note when m_note_on='1' or m_note_off='1' else
            c_note when source_cv='1' else m_note;

  ----------------------------------------------------------------------------
  -- Preset bank: base "body" coefficients + register edit/read-back
  ----------------------------------------------------------------------------
  presets : entity work.preset_bank
    generic map (MUSICAL_MODE=>true,NX=>NX,NY=>NY,OS=>OS,FS_HZ=>FS_HZ,COORD_W=>8,RESET_FREE=>FREE_BOUNDARY)
    port map (clk => sys_clk, rst => sys_rst,
              wr_en => cfg_wr_en, wr_addr => cfg_wr_addr, wr_data => cfg_wr_data,
              rd_addr => cfg_rd_addr, rd_data => cfg_rd_data,
              preset_index => preset_index, recall => preset_recall, save => preset_save,
              coeffs => p_coeffs,
              pick_lx => p_lx, pick_ly => p_ly, pick_rx => p_rx, pick_ry => p_ry,
              free_boundary => p_free, physical_ctrl=>p_phys,
              rim_ctrl=>p_rim,strike_size=>p_strike_size,
              strike_x_ctrl=>p_strike_xc,strike_y_ctrl=>p_strike_yc,
              stiffness_ctrl=>p_stiffness,hardness_ctrl=>p_hardness,
              fx_ctrl0 => fx_ctrl0, fx_ctrl1 => fx_ctrl1, fx_ctrl2 => fx_ctrl2,
              fx_ctrl3 => fx_ctrl3, fx_ctrl4 => fx_ctrl4, fx_ctrl5 => fx_ctrl5);

  -- merge: the selected source sets pitch (gamma2) + timbre (alpha); the preset
  -- sets the body (decay a0/sigk1, CFL clamp gamma2_max)
  tuned_gamma2 <= clamp(tension_scale(s_coeffs.gamma2,p_coeffs.gamma2),
                         to_q123(2.0**(-23)),to_q123(0.45)) when sys_rst='0' else Q123_ZERO;
  chaos_ctl <= clamp(sat_add(p_coeffs.alpha,s_coeffs.alpha),Q123_ZERO,to_q123(0.4))
               when sys_rst='0' else Q123_ZERO;
  v_coeffs.gamma2 <= tuned_gamma2;
  -- CHAOS is independent of MIDI velocity; scale its physical effect with pitch.
  v_coeffs.alpha <= material_alpha(
      sat_store(shift_left(mul_coeff(chaos_ctl,to_acc(tuned_gamma2)),4)),p_material);
  v_coeffs.a0         <= p_coeffs.a0 when sys_rst='0' else Q123_ZERO;
  v_coeffs.sigk1      <= p_coeffs.sigk1 when sys_rst='0' else Q123_ZERO;
  v_coeffs.gamma2_max <= p_coeffs.gamma2_max when sys_rst='0' else Q123_ZERO;

  ----------------------------------------------------------------------------
  -- Polyphonic voice pool (system domain)
  ----------------------------------------------------------------------------
  voices : entity work.poly_voices
    generic map (NVOICES => NVOICES, NX => NX, NY => NY, OS => OS,
                 FREE_BOUNDARY => FREE_BOUNDARY, TIME_MUX => TIME_MUX, MUSICAL_VOICES=>true)
    port map (free_mode=>free_selected, tap_lx=>coordinate(p_lx,NX),tap_ly=>coordinate(p_ly,NY),
              tap_rx=>coordinate(p_rx,NX),tap_ry=>coordinate(p_ry,NY),
              tap_lfx=>p_lfx,tap_lfy=>p_lfy,tap_rfx=>p_rfx,tap_rfy=>p_rfy,
              material=>p_material,exciter_mode=>p_exciter,anisotropy=>p_aniso,
              stiffness_ctrl=>p_stiffness,hardness_ctrl=>p_hardness,
              rim_ctrl=>p_rim,strike_size=>p_strike_size,
              strike_x=>p_strike_x,strike_y=>p_strike_y,
              strike_fx=>p_strike_fx,strike_fy=>p_strike_fy,
              clk => sys_clk, rst => sys_rst, frame => frame,
              note_on => s_note_on, note_off => s_note_off, note => s_note,
              coeffs_in => v_coeffs, exc_in => s_exc_in,
              out_l => mix_l, out_r => mix_r, out_valid => mix_valid,
              active => active);

  ----------------------------------------------------------------------------
  -- Pickup CDC: stereo mix crosses into the I2S (audio) domain
  ----------------------------------------------------------------------------
  -- Remove DC in the RTL, then restore listening level without overdriving cells.
  condition_audio : process(sys_clk)
    variable yl, yr: acc_t;
  begin
    if rising_edge(sys_clk) then
      audio_valid <= '0';
      if sys_rst='1' then
        dc_xl<=Q123_ZERO; dc_xr<=Q123_ZERO;
        dc_yl<=(others=>'0'); dc_yr<=(others=>'0');
        audio_l<=Q123_ZERO; audio_r<=Q123_ZERO;
      elsif mix_valid='1' then
        yl:=to_acc(mix_l)-to_acc(dc_xl)+mul_coeff(DC_R,dc_yl);
        yr:=to_acc(mix_r)-to_acc(dc_xr)+mul_coeff(DC_R,dc_yr);
        dc_xl<=mix_l; dc_xr<=mix_r; dc_yl<=yl; dc_yr<=yr;
        audio_l<=sat_store(shift_left(yl,OUTPUT_GAIN_SHIFT));
        audio_r<=sat_store(shift_left(yr,OUTPUT_GAIN_SHIFT));
        audio_valid<='1';
      end if;
    end if;
  end process;
  fx : entity work.fx_chain
    generic map (FS_HZ=>FS_HZ)
    port map (clk=>sys_clk, rst=>sys_rst, valid_in=>audio_valid,
              in_l=>audio_l, in_r=>audio_r,
              ctrl0=>fx_ctrl0, ctrl1=>fx_ctrl1, ctrl2=>fx_ctrl2,
              ctrl3=>fx_ctrl3, ctrl4=>fx_ctrl4, ctrl5=>fx_ctrl5,
              out_l=>fx_l, out_r=>fx_r, valid_out=>fx_valid);

  pick_src <= std_logic_vector(fx_l) & std_logic_vector(fx_r);

  cdc_pick : entity work.cdc_word
    generic map (WIDTH => 48)
    port map (src_clk => sys_clk, src_rst => sys_rst,
              src_data => pick_src, src_valid => fx_valid,
              dst_clk => bclk_i,   dst_rst => sys_rst,
              dst_data => pick_dst, dst_valid => open);

  tx_l <= signed(pick_dst(47 downto 24));
  tx_r <= signed(pick_dst(23 downto 0));

  ----------------------------------------------------------------------------
  -- I2S transceiver (audio domain): stream the stereo pickups to the DAC
  ----------------------------------------------------------------------------
  i2s : entity work.i2s_transceiver
    generic map (DATA_BITS => 24)
    port map (rst => sys_rst, bclk => bclk_i, lrclk => lrclk_i,
              sd_rx => '0', sd_tx => sd_tx,
              rx_l => open, rx_r => open, rx_valid => open,
              tx_l => tx_l, tx_r => tx_r);

end architecture rtl;
