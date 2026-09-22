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
`NVOICES`, and the pool never diverges. In the playable `MUSICAL_VOICES` mode,
retrigger/steal resets the selected mesh instead of inheriting the previous
resonator state, with a 32-frame output crossfade from the old pickup value to
avoid a hard discontinuity. The fade interpolation is now time-multiplexed
through one shared narrow DSP multiplier for the whole voice pool; at four
voices it completes in nine 100 MHz clocks, rather than dedicating four
left/right multiplier pairs to every voice.

Musical voices additionally enable RTL-only physical-model refinements:

- **velocity/exciter-dependent strike shape**: auto/point/soft-mallet/pluck/rim/scrape-burst modes use the existing oversample substeps rather than another audio engine;
- **sub-grid geometry**: strike force is bilinearly distributed and left/right pickups are bilinearly interpolated at quarter-cell offsets, increasing positional resolution without increasing `NX*NY`;
- **anisotropy**: a signed macro applies a shift/add X-vs-Y Laplacian bias, splitting otherwise symmetric modes without another coefficient multiplier;
- **bending stiffness / plate dispersion**: an 8-bit STIFFNESS macro drives the 13-point biharmonic operator; it is latched per voice and its `mu2*Biharm` scale is shift/add so the mesh still uses 18 DSPs;
- **physical mallet**: an 8-bit HARDNESS macro is latched per voice; nonzero HARDNESS with AUTO/MALLET CHARACTER runs a stateful hammer that reads the actual strike-point surface, reacts to contact force, and continues across frames after the one-shot note trigger. The contact curve is shift/add and consumes 0 DSPs;
- **MATERIAL macro**: neutral/membrane/wood/metal/glass coordinate anisotropy bias, high-frequency loss, nonlinearity and default exciter character;
- **micro-variation**: a deterministic LFSR adds ±3.125% strike variation and moves each stereo pickup by at most one grid node on a new strike;
- **frequency-dependent loss**: a Laplacian-of-velocity term damps high spatial modes faster than low modes, with MATERIAL selecting the loss strength.

These are preset/register features only: no ADC channels or PCB signals are added. `musical_refine_tb` drives nonzero material, anisotropy, fractional geometry and explicit scrape excitation; `stiffness_tb` drives nonzero bending stiffness against an independent fixed-point golden; `mallet_tb` does the same for the stateful physical mallet and requires spatial/TDM contact-driven responses to remain bit-identical.

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

**Time-multiplexing is what makes polyphony fit.** The table below records the older ~18-DSP/voice planning model. The current full physical-model 8x8 `grid_mesh_tdm` maps to **18 DSP** in the open-source XC7 flow, including runtime STIFFNESS/plate dispersion, HARDNESS/stateful contact, MATERIAL/anisotropy, HF loss and fractional strike/pickup geometry; see `resource_budget.md`. Four grids therefore use 72 DSP before mixer/front-end/FX glue. Full-top Vivado utilization remains the authoritative board number.

Historical planning table:

| Voices | TIME_MUX DSP (~18/voice) | Fits A7-35T (90)? | Fits A7-100T (240)? |
| --- | --- | --- | --- |
| 1 | ~18 | yes | yes |
| 4 | ~72 | yes | yes |
| 8 | ~144 | no (35T) / yes (100T) | yes |
| 12 | ~216 | no | yes |

Those rows are retained as pre-FX historical planning data. The current custom board target is the XC7A50T. Each fully refined 8x8 time-mux surface voice, including runtime STIFFNESS and HARDNESS, maps to **18 DSPs**, so four voice meshes account for 72 DSPs before the shared fade/front-end/FX logic. The current four-voice `synth_top` maps to **116 / 120 DSPs (96.7%)** in the open-source XC7 flow; the separate PLAY/EDIT panel controller adds one standalone DSP, for an approximate board-level planning total of **117 / 120**. That margin is intentionally treated as provisional until Vivado place/route.

### The cycle budget is the other limit

Each voice sweeps its mesh every oversampled step. Per audio frame there are
~2083 cycles at 100 MHz / 48 kHz ([`timing_budget.md`](timing_budget.md)). For
the 8x8/OS=4 production configuration, STIFFNESS=0 retains the legacy ~264
mesh clocks/frame. Nonzero STIFFNESS activates four two-tap gather states per
node for the 13-point plate stencil: `stiffness_tb` measures **322 clocks per
mesh step**, or 1288 mesh clocks at OS=4 before the small resonator handshake
overhead. The as-built `poly_voices` gives each voice its own resonator, so
voices run concurrently and the per-frame cost is one voice's sweep regardless
of `NVOICES` (area, not time, scales).

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
