# CV (control-voltage) input front-end

The Eurorack-native counterpart to the MIDI front-end (#28). `cv_frontend`
([`src/rtl/cv_frontend.vhd`](../src/rtl/cv_frontend.vhd)) drives the **same
note-mapping interface** that `poly_voices` / `synth_top` consume (note events +
per-note `coeffs` + excitation), but from control voltage instead of MIDI, so
the engine plays from a modular system. It is a drop-in alternative to
`midi_frontend`: identical outputs, so it can feed the polyphonic pool or the
board top unchanged.

## Inputs

| Signal | Type | Meaning |
| --- | --- | --- |
| `pitch_cv` | `signed(CV_W-1:0)` | 1V/oct pitch, digitised by an external ADC |
| `gate` | `std_logic` | gate/trigger (a comparator on the gate jack) |
| `mod_cv` | `signed(CV_W-1:0)` | modulation CV, digitised by an ADC |

The analog CVs are assumed already digitised and presented synchronous to `clk`;
the `gate` is brought in through a two-flop synchroniser inside the block.

## Mapping

- **Pitch: 1V/oct → note → `gamma2`.** The pitch CV is quantised to a semitone
  and looked up in the same note→`gamma2` table as `midi_frontend` (one octave =
  `gamma2` x4, CFL-clamped). Calibration is by generics:

  ```
  note = NOTE_REF + (pitch_cv - CV_OFFSET) * CV_SCALE >> CV_SHIFT   (semitone)
  ```

  Defaults assume **4096 ADC counts per volt (per octave)**, so
  `CV_SCALE/2^CV_SHIFT ~ 1/341.3` counts-per-semitone (`CV_SCALE=192`,
  `CV_SHIFT=16`). `CV_OFFSET` trims the 0 V note; `CV_SCALE` trims 1V/oct
  tracking. (A calibration routine would sweep two known octaves and solve for
  offset/scale.)

- **Gate → strike / release.** A gate **rising** edge fires a note-on: it sets
  the note's `gamma2`, latches a one-frame excitation (the mallet) at a fixed
  strike level `VEL_STRIKE`, and pulses `note_on`. A gate **falling** edge pulses
  `note_off`; nothing is re-struck, the voice decays naturally through its
  damping (just like MIDI note-off).

- **Mod CV → `alpha` (timbre).** The mod CV (clamped to its positive range) maps
  to the chaos-coupling `alpha` between `ALPHA_MIN` and `ALPHA_MAX` (README §2,
  amplitude stiffening): more mod = brighter, more non-linear. Unpatched
  (`mod_cv = 0`) gives `ALPHA_MIN`.

The fixed body fields (`a0`, `sigk1`, `gamma2_max`) come from generics, as in
`midi_frontend`; in a wired top they would instead come from `preset_bank`
(#30, #69), the same merge `synth_top` (#68) does.

## Using it

`cv_frontend` has the exact output port list of `midi_frontend`, so it drops into
`poly_voices` or `synth_top` in place of the MIDI stage (or alongside it, with a
mux) to make a CV-controlled voice. A velocity/accent CV could additionally scale
the strike; today the strike level is fixed and `mod_cv` shapes timbre.

## Verification

[`src/tb/cv_frontend_tb.vhd`](../src/tb/cv_frontend_tb.vhd) drives CV stimulus
into the front-end and feeds its outputs into a live `mesh_resonator`. It checks:
0 V maps to the reference note (`gamma2 = 0.09`); +4096 counts (one octave)
quadruples `gamma2` (note +12); a gate edge delivers a strike (one frame of
`exc_en`) and gate-low a note-off; more mod CV raises `alpha`; and the mesh
sounds in response and stays inside Q1.23. Passes under GHDL:

```
cv_frontend_tb: gate strike delivered (exc_en)
cv_frontend_tb: all checks passed (1V/oct pitch -> gamma2; gate -> strike/decay;
                mod -> alpha; mesh sounds, bounded)
```
