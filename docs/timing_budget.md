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

### Time-multiplexed mesh (a pool of P PEs)

If the grid is folded through `P` shared PEs instead, each oversampled step
sweeps `NX*NY` nodes in `ceil(NX*NY / P)` passes, so:

```
cycles / frame ~= OS * ceil(NX*NY / P) * (pipeline-limited per-pass cost)
```

For example a 32x32 = 1024-node mesh at OS=4 through P=16 PEs is on the order of
`4 * 64 * (~4) ~= 1024` cycles, still under the 2083-cycle budget; larger grids
or higher OS trade against `P`. The fully-spatial and time-multiplexed builds
share the same RTL (`grid_mesh` generics), so this is a synthesis-time choice.

## Conclusion

The single-cycle `frame` strobe plus the `mesh_resonator` sequencer completes
the full oversampled mesh sweep well within one audio sample period for every
practical configuration: fully-spatial leaves >94% of the budget free even at
16x oversampling, and the time-multiplexed fold still fits a 32x32 mesh.
