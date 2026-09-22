# Sample-strobe timing and cycle budget

The mesh advances one time-step per audio sample, strobed from the I2S word
clock (README §3). [`src/rtl/sample_strobe.vhd`](../src/rtl/sample_strobe.vhd)
crosses LRCLK into the system-clock domain (two-flop synchroniser + rising-edge
detect) and emits one clean single-cycle `frame` pulse per audio sample.
Oversampling sub-steps are sequenced from that pulse by `mesh_resonator`.

## Cycle budget per audio frame

At a 100 MHz system clock and `f_s = 48 kHz`:

```
cycles / frame = 100e6 / 48e3 ~= 2083
```

The whole mesh sweep for one sample (all `OS` oversampled time-steps) must fit
inside those ~2083 cycles.

### Fully-spatial mesh (one PE per node)

Every node updates in parallel, so one mesh time-step costs only the PE
pipeline plus the sequencer handshake. Measured from `mesh_resonator` (OS=4,
256 frames): ~28 cycles per frame, i.e. **~7 system clocks per oversampled
step** (4-stage `node_element` latency + the strobe/`valid` handshake).

| OS | cycles / frame (~7 x OS) | % of 2083-cycle budget |
| --- | --- | --- |
| 1x | 7 | 0.3% |
| 2x | 14 | 0.7% |
| 4x | 28 | 1.3% |
| 8x | 56 | 2.7% |
| 16x | 112 | 5.4% |

So a fully-spatial mesh has enormous headroom: oversampling up to roughly
`OS = 2083 / 7 ~= 290` still fits within one sample period. Grid size does not
change this number (the nodes update concurrently); it changes area, not time.

### Time-multiplexed mesh

The current `grid_mesh_tdm` implementation serializes the raster through one
shared arithmetic path. With STIFFNESS=0 it keeps the original one-node-per-clock
sweep. Nonzero STIFFNESS needs the diagonal and second axial ring of the
13-point biharmonic stencil, but it does **not** add eight simultaneous memory
read ports: four gather states fetch two extra taps per clock, then the normal
node-update state runs.

For the production 8x8 grid:

| TDM mode | clocks / mesh step | OS=4 mesh clocks / audio frame |
| --- | ---: | ---: |
| STIFFNESS=0 | legacy ~66 | ~264 |
| STIFFNESS>0 | **322 measured** | **1288** |

`stiffness_tb` pins the 322-clock nonzero-stiffness value. The surrounding
`mesh_resonator` FIRE/WAIT handshake adds only a few clocks per substep, so a
stiff OS=4 voice remains around 1.3k clocks/frame, below the 2,083-clock budget
at 100 MHz / 48 kHz. Voices are separate TDM engines and run in parallel, so
polyphony consumes area rather than multiplying this per-frame latency.

Larger grids or higher OS must be re-budgeted: nonzero stiffness costs roughly
five raster clocks per node in the current implementation, while membrane mode
retains the legacy one-clock raster path.

## Post-mesh FX latency

The effects are handshake-driven between audio frames, not part of the mesh
oversampling sweep. `fx_master_bus` accepts one post-FDN sample and returns it
after three additional 100 MHz clocks (shared left/right compressor gain plus
output), about **0.14%** of the 2,083-clock frame budget. Parameter smoothing,
master crossfade and FDN modulation update once per 48 kHz sample and do not add
block buffering. The four-voice retrigger/steal mixer now needs only nine system
clocks for its shared fade interpolation, also negligible versus 2,083 clocks
per frame. The musical mesh's legacy velocity/exciter-shaped strike uses the existing oversample substeps, while high-frequency damping and anisotropy are computed during the normal node update. RIM compliance is applied during the ordinary boundary-neighbour fetch. STRIKE SIZE/X/Y only change the per-node forcing comparison/weight during the same raster, and fractional pickup interpolation captures its four corner samples as the raster already visits them. The #87 physical mallet likewise adds **no extra raster state**: its two scalar hammer states advance on the existing mesh strobe, while the actual strike-point contact corners are captured during the normal TDM raster (the spatial backend reads them directly). STIFFNESS is the exception: when nonzero it activates the four two-tap gather states described above for the wider plate stencil; when zero those states are bypassed exactly.
No audio clock, panel, or PCB change is needed.

## Conclusion

The single-cycle `frame` strobe plus the `mesh_resonator` sequencer completes
the configured production 8x8/OS=4 mesh within one audio sample period in both
membrane and stiff-surface modes. Fully-spatial leaves large timing headroom;
for TDM, larger grids or higher oversampling must be checked against the formulas
above, especially when STIFFNESS is nonzero.
