# synth_top: end-to-end playable synth (issue #68)

`synth_top` ties the M8 building blocks into one instrument: a MIDI stream in,
polyphonic mesh voices, and stereo I2S audio out, with the FPGA as the I2S
master. It is the design a board would flash. RTL:
[`src/rtl/synth_top.vhd`](../src/rtl/synth_top.vhd).

## Datapath

```
 midi_rx --2FF sync--> midi_frontend --> note events + per-note coeffs + exc
                                    \                       |
     preset_index/recall --> preset_bank --> base coeffs (a0/sigk1/gamma2_max)
                                                            |
                              merge (note pitch/timbre + preset body)  = coeffs
                                                            v
              poly_voices  (NVOICES independent meshes + averaging mix) --> L/R
                                                            v
                     pickup cdc_word (system -> audio clock)  --> tx_l/tx_r
                                                            v
                              i2s_transceiver TX  -->  sd_tx  -->  codec DAC
```

- **midi_frontend** (#28) parses the serial MIDI and maps note -> `gamma2`
  (pitch), velocity -> `alpha` (timbre) + strike amplitude, and emits the
  note-on/off events plus a one-frame excitation.
- **preset_bank** (#30) supplies the instrument "body": `a0`/`sigk1` (decay) and
  `gamma2_max` (CFL clamp), recalled/saved via `preset_index`/`recall`/`save`
  and editable through the `cfg_*` register port.
- **coefficient merge**: the voice coefficients take pitch (`gamma2`) and timbre
  (`alpha`) from the note and the body (`a0`, `sigk1`, `gamma2_max`) from the
  preset. So a preset picks the instrument and notes play it.
- **poly_voices** (#29) allocates voices, latches each note's coefficients +
  excitation into its voice, runs `NVOICES` independent meshes, and averages
  their stereo pickups. `TIME_MUX` (#24) is forwarded so voices can fold onto a
  shared PE for area (the only way polyphony fits a small device).
- **i2s_transceiver** streams the mixed stereo to the DAC.

Output-only voice: the codec ADC input is unused (`sd_rx` tied off).

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

Generics: `NVOICES`, `NX`/`NY`/`OS`/`FREE_BOUNDARY`/`TIME_MUX` (the mesh/voice
config, forwarded to `poly_voices`), `CLK_HZ`/`BAUD` (MIDI UART), and
`MCLK_TO_BCLK`/`BCLK_TO_LRCK` (I2S clock division). For a real board build set
`TIME_MUX = true` so `NVOICES` voices fit (see `docs/polyphony.md`).

## Verification

[`src/tb/synth_top_tb.vhd`](../src/tb/synth_top_tb.vhd) drives a real serial
MIDI stream in and decodes the I2S output with a loopback codec (a second
`i2s_transceiver` sampling `sd_tx` off the generated clocks). It recalls the
gong preset, then plays notes and checks: a note allocates a voice (`active`
fills), the codec recovers non-zero stereo audio (the voice sounds), a second
held note adds a second voice, and the output never leaves Q1.23 (no
divergence). Passes under GHDL:

```
synth_top_tb: voice sounded, peak |out| = 191121
synth_top_tb: all checks passed (MIDI -> 3-voice polyphony -> I2S audio;
              voices allocate, sound, bounded)
```
