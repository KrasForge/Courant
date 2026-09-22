# synth_top: end-to-end playable synth (issue #68)

`synth_top` ties the M8 building blocks into one instrument: a MIDI stream in,
polyphonic mesh voices, and stereo I2S audio out, with the FPGA as the I2S
master. It is the design a board would flash. RTL:
[`src/rtl/synth_top.vhd`](../src/rtl/synth_top.vhd).

## Datapath

```
 midi_rx --2FF sync--> midi_frontend --> calibrated note gamma2 + strike
                                    \                       |
     preset_index/recall --> preset_bank --> TENSION/DECAY/CHAOS + taps/boundary
                                                            |
                              merge + musical scaling  = voice coeffs
                                                            v
              poly_voices  (NVOICES independent meshes + averaging mix) --> L/R
                                                            v
                    DC/gain -> drive -> tone -> chorus -> delay -> 8-line FDN
                              -> POLISH EQ/width/compressor/limiter
                                                            v
                     pickup cdc_word (system -> audio clock)  --> tx_l/tx_r
                                                            v
                              i2s_transceiver TX  -->  sd_tx  -->  codec DAC
```

- **midi_frontend** (#28) parses serial MIDI, maps notes through the discrete-mesh pitch table, and maps velocity to strike amplitude. MIDI velocity no longer changes CHAOS by default.
- **cv_frontend** (#70) runs in parallel and produces the same note-mapping interface from control voltage (1V/oct pitch, gate, mod CV). MIDI/CV selection is normally automatic: the newest MIDI note-on or CV gate rising edge claims the source. Register 9 can force MIDI or CV for a preset/debug setup; the legacy `cv_sel` input remains a force-CV compatibility override rather than a panel control.
- **preset_bank** (#30/#86/#87) supplies TENSION, DECAY, CHAOS, `gamma2_max`, STIFFNESS, physical-mallet HARDNESS, stereo pickup geometry, MATERIAL/ANISO/CHARACTER, RIM compliance, STRIKE SIZE/X/Y, source override, runtime boundary mode, and the six stored FX words; recall/save/edit still use the same 4-bit/24-bit register interface.
- **musical merge**: calibrated note pitch is multiplied by normalized TENSION (0.25 = unity); CHAOS is independent of MIDI velocity and scaled with tuned pitch; DECAY and the base CFL ceiling come from the preset. STIFFNESS maps to `mu2=control/4096`, adds the 13-point biharmonic plate term, and automatically tightens the effective wave-speed ceiling with `(g2x+g2y)+16*mu2<=1`. HARDNESS independently controls the stateful physical-mallet contact law while MIDI/CV velocity initializes hammer momentum. MATERIAL can further bias CHAOS/nonlinearity and default CHARACTER. Pickup positions, fractional offsets, boundary mode, anisotropy, material, exciter type, stiffness and hardness are latched into each newly struck voice.
- **poly_voices** (#29) allocates independent resonators and averages their stereo pickups. Musical voices latch the complete surface/exciter state on a strike: STIFFNESS, HARDNESS, RIM, STRIKE SIZE/X/Y, MATERIAL, CHARACTER, ANISO and pickup geometry. Strike position is full-grid plus quarter-cell resolution; STRIKE SIZE expands from a point/sub-grid contact through compact 3x3 and wide 13-node footprints. RIM continuously changes boundary compliance. These refinements are implemented identically in spatial and TDM backends. `TIME_MUX` remains the area-saving implementation.
- **output conditioning + FX** removes DC with a 20 Hz one-pole high-pass and restores level, then `fx_chain` applies drive, tilt tone, BRAM chorus, stereo/ping-pong delay and an eight-line damped FDN reverb. Numeric FX controls slew at audio rate, effect enables fade toward neutral, and the global master crossfades to/from a latched dry sample. Delay keeps legacy sample timing but can alternatively decode BPM + musical division from register 12. The FDN slowly modulates each line by a few samples to break up static metallic modes without another RAM. `fx_master_bus` then adds the `POLISH` macro: ~30 Hz subsonic cleanup, a production-style low-shelf/low-mid/presence curve, low-frequency stereo centering with upper-band widening, a dual-timescale linked compressor with continuous gain law/program-dependent release, and soft limiting. `POLISH=0` is an exact mastering-stage bypass. **i2s_transceiver** then streams the post-FX stereo to the DAC.

Output-only voice: the codec ADC input is unused (`sd_rx` tied off).


## Onboard FX chain

The effects run in the 100 MHz system domain on the 48 kHz sample-valid pulse;
there is no extra audio clock domain. Chorus and delay use explicit single-port
RAM read/wait/write schedules, and their wet memories are Q1.15 to save BRAM
while the dry path stays Q1.23. The FDN likewise stores Q1.15 state in eight
prime-ish delay lines and uses a shift-normalized Hadamard feedback matrix. A
slow per-line ±few-sample modulation is derived from a shared phase accumulator
and diffusion setting, reducing static comb/metallic character with no extra
wet RAM. `src/tb/fx_chain_tb.vhd` checks exact settled master bypass, gradual
parameter slew, master crossfade, raw and tempo-grid delay timing, drive shaping,
a non-zero FDN tail, and POLISH makeup/reshaping.

## Clocking

Two clock domains:

| Domain | Clock | Contents |
| --- | --- | --- |
| System | `sys_clk` (e.g. 100 MHz) | midi_frontend, preset_bank, poly_voices (the mesh) |
| Audio | I2S `bclk` (from `mclk`) | i2s_transceiver |

`i2s_clkgen` (#26) is the **I2S master**: from the audio master clock `mclk`
(e.g. 12.288 MHz from an MMCM) it generates MCLK/BCLK/LRCLK for the codec.
`sample_strobe` crosses LRCLK back into `sys_clk` as the per-audio-frame `frame`
pulse that advances the mesh one step per audio sample.

### Clock-domain crossings

Only two, both already-verified primitives:

1. **MIDI input**: `midi_rx` is asynchronous serial; a two-flop synchroniser
   brings it into `sys_clk` before `midi_frontend` (its UART assumes a
   synchronised input).
2. **Pickup word**: the stereo mix crosses `sys_clk -> bclk` through `cdc_word`
   (the MCP handshake), 48 bits (L&R) per transfer.

`frame` from `sample_strobe` is the LRCLK->system strobe crossing. A single
global reset is used for both domains (fine for simulation; synchronise reset
per-domain for a real build). The XDC in `syn/vivado/arty_a7.xdc` already
constrains these crossings (async clock group + bus skew).

## Configuration

Generics: `NVOICES`, `NX`/`NY`/`OS`/`FREE_BOUNDARY`/`TIME_MUX`, `FS_HZ` (used by pitch/damping calibration), `OUTPUT_GAIN_SHIFT`, `CLK_HZ`/`BAUD`, and `MCLK_TO_BCLK`/`BCLK_TO_LRCK`. For a real board build set
`TIME_MUX = true` so `NVOICES` voices fit (see `docs/polyphony.md`).

## Verification

[`src/tb/synth_top_tb.vhd`](../src/tb/synth_top_tb.vhd) drives a real serial
MIDI stream in and decodes the I2S output with a loopback codec (a second
`i2s_transceiver` sampling `sd_tx` off the generated clocks). It recalls the gong preset, then checks MIDI allocation/audio, automatic CV claiming from a gate edge with the legacy `cv_sel` override left inactive, a later MIDI note reclaiming AUTO source, polyphony, and bounded I2S output. Current GHDL run:

```
synth_top_tb: voice sounded, peak |out| = 1451476
synth_top_tb: AUTO CV claim sounded, peak |out| = 254016
synth_top_tb: all checks passed (MIDI and CV -> 3-voice polyphony -> I2S audio;
              voices allocate, sound, bounded)
```

## Board top (arty_synth): panel controls

On the board, [`syn/vivado/arty_synth.vhd`](../syn/vivado/arty_synth.vhd) wraps
`synth_top` with the MMCM clocking (see `syn/README.md`) and adds the front
panel: [`panel_ctrl`](../src/rtl/panel_ctrl.vhd) (#78/#85) drives `synth_top`'s
`cfg_*` / `preset_*` control ports from the pots and rotary encoder (see
[`panel.md`](panel.md)). `sw0` is now PLAY/EDIT: in PLAY the encoder navigates
presets and the LEDs show active voices; in EDIT the encoder selects an edit
page, the LEDs show that page one-hot, and the six pots edit that page with soft
takeover. Page 0 is SURFACE; the selector is generic/extensible without a PCB
change. MIDI/CV source claiming remains automatic in `synth_top`. The pot/CV
analog samples come from an XADC / external ADC (that ADC block is out of scope;
the sample ports are left for it).
