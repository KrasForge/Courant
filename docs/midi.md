# MIDI / CV input front-end

Turning the engine from a physics demo into a playable instrument (milestone
M8). A serial MIDI stream drives pitch, strike energy, and timbre. The front-end
is [`src/rtl/midi_frontend.vhd`](../src/rtl/midi_frontend.vhd) (parser + mapping)
on top of [`src/rtl/midi_uart_rx.vhd`](../src/rtl/midi_uart_rx.vhd) (the serial
receiver). It emits a full `coeffs_t` plus the excitation, ready to drive
`mesh_resonator` / `top_resonator` in place of the control-bus + I2S excitation.

## Signal chain

```
MIDI in --> midi_uart_rx --> parser --> note/velocity mapping --> coeffs + exc
 (31250     (8N1 byte)      (note-on/   (pitch / strike / timbre)  to the mesh
  baud)                      note-off)
```

- **midi_uart_rx**: standard oversampling UART at 31250 baud, 8 data bits
  LSB-first, no parity, one stop bit. The bit period is `CLK_HZ / BAUD` system
  clocks (3200 at 100 MHz). Synchronise the raw MIDI pin with a two-flop
  synchroniser before this block on hardware.
- **parser**: recognises Note On (`0x9n`) and Note Off (`0x8n`), including
  running status (a data byte with no preceding status reuses the last one) and
  the Note On velocity-0 convention (treated as Note Off). Other channel and
  system/real-time bytes are skipped without disturbing running status.

## Mapping (all generics, so it is configurable)

### Pitch: note number -> `gamma0^2` (`coeffs.gamma2`)

A mesh mode's frequency scales with the wave speed `c`, and
`gamma2 = (c*k/h)^2` scales with `c^2`. So doubling the frequency (one octave)
needs `gamma2` to quadruple. The note-to-gamma2 map is therefore exponential
with a slope of 6 semitones per gamma2 doubling:

```
gamma2(note) = GAMMA2_REF * 2^((note - NOTE_REF) / 6)
```

clamped to `[GAMMA2_MIN, GAMMA2_CLAMP]` with `GAMMA2_CLAMP < 0.5` to stay inside
the CFL stability limit. The table is precomputed at elaboration into a 128-entry
ROM (note -> Q1.23), so there is no runtime `pow`. Defaults: `NOTE_REF = 69`
(A4), `GAMMA2_REF = 0.09`, `GAMMA2_CLAMP = 0.45`.

Because the grid is fixed, the playable pitch range is bounded: high notes
saturate at `GAMMA2_CLAMP` (a fixed mesh has a finite pitch range; retuning the
physical size/`h` would extend it). This is honest, documented behaviour.

| Note | Offset from A4 | `gamma2` | Notes |
| --- | --- | --- | --- |
| A3 (57) | -12 | 0.0225 | one octave down (÷4) |
| A4 (69) | 0 | 0.090 | reference |
| A5 (81) | +12 | 0.360 | one octave up (×4) |
| high | large | 0.45 (clamped) | CFL ceiling |

### Strike: Note On -> excitation impulse (the mallet)

A Note On delivers one frame of excitation into the mesh (`exc_en` asserted for
the next audio frame). The impulse amplitude scales with velocity:

```
exc_in = STRIKE_GAIN * velocity / 128      (Q1.23)
```

Default `STRIKE_GAIN = 0.9`, so velocity 127 is a near-full-scale strike and
velocity 1 is a gentle tap. A Note Off (or Note On with velocity 0) does **not**
strike: the mesh decays naturally through its damping (`sigk1`), exactly like a
struck instrument releasing.

### Timbre: velocity -> chaos coupling `alpha`

Harder hits also ring more non-linearly. Velocity maps to `coeffs.alpha`
(README §2, amplitude-dependent stiffening) between `ALPHA_MIN` and `ALPHA_MAX`:

```
alpha = ALPHA_MIN + (ALPHA_MAX - ALPHA_MIN) * velocity / 128
```

Defaults `ALPHA_MIN = 0.0`, `ALPHA_MAX = 0.3`. Set `ALPHA_MAX = 0` for a purely
linear instrument (velocity then affects loudness only). The CFL clamp
(`gamma2_max`, default 0.451) keeps the non-linear term stable at any velocity.

### Fixed coefficients

`a0`, `sigk1` (damping) and `gamma2_max` (CFL clamp) are held at generic
defaults (`0.99996875`, `0.99996875`, `0.451`); only `gamma2` and `alpha` move
with the note. Adjust the generics for a different decay time or stability
margin.

## CV alternative

The same mapping applies to control voltage: replace `midi_uart_rx` with an ADC
reading a pitch CV (-> note index) and a gate/velocity CV (-> strike), feeding
the identical note/velocity mapping. The parser stage is MIDI-specific; the
mapping stage is not.

## Verification

[`src/tb/midi_frontend_tb.vhd`](../src/tb/midi_frontend_tb.vhd) sends a real
MIDI byte stream (start / 8 data LSB-first / stop) into the front-end, feeds its
coeffs + excitation into a live `mesh_resonator`, and checks: a Note On is parsed
(note + velocity recovered); an octave up quadruples `gamma2`; a Note On delivers
a strike; a harder hit raises both the strike amplitude and `alpha`; the mesh
produces output in response; and a Note Off does not strike (natural decay). All
pass under GHDL.
