# Polyphony (voice scaling)

Playing several notes at once (milestone M8). The engine supports a configurable
pool of independent voices, allocated to notes and mixed to one stereo output.
This note covers the voice abstraction, allocation/stealing, mixing, and the
voice-count-vs-resource trade that decides how many voices fit a given board.

## Voice abstraction

A **voice** is a full `mesh_resonator` with its own state and coefficients, so
voices are genuinely independent: different pitch (`gamma2`), different timbre
(`alpha`), and overlapping natural decays. [`poly_voices`](../src/rtl/poly_voices.vhd)
instantiates `NVOICES` of them and mixes their pickups.

The input is the note-mapping interface shared by the MIDI and CV front-ends
(note-on/off events plus the current note's coeffs and strike amplitude), so the
voice pool is independent of the control source: MIDI (issue #28), CV, or a
sequencer all drive the same port.

## Allocation and stealing

[`voice_allocator`](../src/rtl/voice_allocator.vhd) maps note events onto the
pool, in priority order:

1. **Retrigger** a voice already playing this exact note (a repeated key does not
   consume a second voice);
2. **Free** the lowest-indexed idle voice;
3. **Steal** the oldest voice by a round-robin pointer when all are busy.

A note-off marks its voice free for reuse; it does not silence it (the mesh keeps
ringing and decays naturally, so a released note still sounds until it decays).
Stealing is bounded and deterministic: the active-voice count never exceeds
`NVOICES`, and the pool never diverges.

## Mixing

All voices share the per-frame `frame` tick, so their `out_valid` pulses align.
The mixer sums the `NVOICES` stereo pickups in the 48-bit guard accumulator and
scales by the compile-time constant `1/NVOICES` (an average, so a full pool
cannot clip), then saturates back to Q1.23. No runtime divider.

## Voice count vs. resource cost

Each voice is a mesh, and (from [`resource_budget.md`](resource_budget.md)) a
fully-spatial 8x8 mesh is **1152 DSP** (18 DSP/node x 64 nodes). So fully-spatial
polyphony multiplies that:

| Voices | Spatial DSP (8x8) | Fits A7-35T (90)? | Fits A7-100T (240)? |
| --- | --- | --- | --- |
| 1 | 1152 | no | no |
| 4 | 4608 | no | no |
| 8 | 9216 | no | no |

Fully-spatial polyphony is hopeless on the target board even for one voice, for
the same O(N^2) reason a single spatial mesh is (issue #24). The DSP cost is the
binding resource.

**Time-multiplexing is what makes polyphony fit.** With `TIME_MUX = true` each
voice folds its mesh through one shared PE (~18 DSP), independent of grid size:

| Voices | TIME_MUX DSP (~18/voice) | Fits A7-35T (90)? | Fits A7-100T (240)? |
| --- | --- | --- | --- |
| 1 | ~18 | yes | yes |
| 4 | ~72 | yes | yes |
| 8 | ~144 | no (35T) / yes (100T) | yes |
| 12 | ~216 | no | yes |

So an A7-35T comfortably runs ~4 voices and an A7-100T ~12, at 8x8 (a further PE
pool per voice, issue #24, trades DSP for cycles and can go larger).

### The cycle budget is the other limit

Each voice sweeps its mesh every oversampled step. Per audio frame there are
~2083 cycles at 100 MHz / 48 kHz ([`timing_budget.md`](timing_budget.md)). A
`TIME_MUX` voice at NX*NY = 64 nodes, OS = 4 costs ~`OS * NX*NY` = ~256
cycles/frame per voice if the voices run **sequentially** through one pool; run
them on **parallel** PE pools (one per voice) and they overlap. The as-built
`poly_voices` gives each voice its own resonator, so voices run concurrently and
the per-frame cost is one voice's sweep regardless of `NVOICES` (area, not time,
scales) - the same trade the single mesh makes.

## Configurability

`NVOICES` is a generic on `poly_voices` (and `voice_allocator`), as are the mesh
size, oversampling, boundary, and spatial-vs-time-mux choice. Pick the voice
count for the target from the tables above.

## Verification

[`src/tb/poly_tb.vhd`](../src/tb/poly_tb.vhd) drives the pool (NVOICES = 3) with
note events and checks: a note-on allocates a voice and the mesh sounds; three
held notes fill all voices and mix without divergence; a fourth note steals a
voice (active count stays <= NVOICES); and a note-off frees the right voice. The
output is asserted to stay inside Q1.23 for the whole run (no divergence). All
pass under GHDL.
