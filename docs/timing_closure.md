# Timing closure (Arty A7, 100 MHz)

How `top_resonator` is constrained and why it closes timing at the 100 MHz
system clock on the target board (README §6), and how the per-node pipeline
keeps the arithmetic off the critical path (README §3, "PE pipeline"). This is
the sign-off counterpart to the resource budget in
[`resource_budget.md`](resource_budget.md).

Constraints live in [`syn/vivado/arty_a7.xdc`](../syn/vivado/arty_a7.xdc); the
implementation + timing flow is
[`syn/vivado/build_arty.tcl`](../syn/vivado/build_arty.tcl).

## Clocks

Two independent clocks, declared as primary clocks on their input pins:

| Clock | Source | Period | Frequency |
| --- | --- | --- | --- |
| `sys_clk` | on-board oscillator (E3) | 10.000 ns | 100 MHz |
| `bclk` | codec I2S bit clock | 81.380 ns | 12.288 MHz (256 x 48 kHz) |

The mesh arithmetic runs entirely in the `sys_clk` domain; audio I/O runs in the
`bclk` (Pmod I2S2) domain. The two come from separate oscillators and are
therefore **asynchronous**.

## The two clock domains and their crossing

The only paths between the domains go through the two `cdc_word` instances:

- `cdc_exc` : excitation sample, `bclk` -> `sys_clk`;
- `cdc_pick`: stereo pickups, `sys_clk` -> `bclk`.

Both use the MCP "synchronised flag + stable data" handshake (see
[`cdc.md`](cdc.md)): a single `req` toggle crosses asynchronously through a
two-flop synchroniser, and the multi-bit word is read from a holding register
only when it is guaranteed stable.

The constraints match that structure exactly:

1. **`set_clock_groups -asynchronous`** between `sys_clk` and `bclk`. This cuts
   setup/hold (and recovery/removal) analysis on every cross-domain path, which
   is the false path the handshake is built around. Only the 1-bit `req` toggle
   actually crosses, and metastability on it is absorbed by the synchroniser, so
   there is nothing to time on that edge.
2. **`set_bus_skew`** on each holding-register -> destination-data capture. The
   async clock group stops *setup* analysis on the data bus, but the captured
   word still must not tear: every bit has to land within one destination clock
   period. A bus-skew check survives the async clock group (it is a skew check,
   not a setup check) and bounds exactly that, per direction (10 ns into the
   `sys_clk` domain, 81.38 ns into the `bclk` domain).
3. **`set_false_path -from [get_ports sys_rst]`**. The reset is an asynchronous
   push-button fanning into both domains; its de-assertion must not create a
   cross-domain timing path.

The XDC also documents the alternative if you do not want a blanket async clock
group: `set_false_path` on the synchroniser input plus
`set_max_delay -datapath_only` on the data bus give the same protection while
keeping the rest of the inter-clock paths analysed.

## I/O timing

`top_resonator` is the I2S **slave**: `bclk` and `lrclk` come from the codec,
data is MSB-first and sampled on the bit-clock edge per the I2S frame. The XDC
sets conservative `set_input_delay` / `set_output_delay` budgets (a half BCLK
period) on `lrclk`, `sd_rx`, and `sd_tx`; tighten these to the codec datasheet
numbers (CS5343 / CS4344 on the Pmod I2S2) for final sign-off.

## PE pipeline and the critical path

The per-node update is **not** a single combinational edge; `node_element`
spreads it across a 4-stage pipeline with every signed multiply isolated to
registered operands and a registered result, so each multiply maps onto a
DSP48E1 with its internal input/output pipeline registers used:

| Stage | Work | Multiply |
| --- | --- | --- |
| 1 | Laplacian sum, `sigk1*u^{n-1}`, `u^2`, `2*u^n` (capture inputs) | `u^2`, `sigk1*u1` |
| 2 | `alpha*u^2`, clamp to `gamma2_local` (CFL-safe) | `alpha*u^2` |
| 3 | `gamma2_local*lap`, form `2u - sigk1*u1 + g2l*lap` | `g2l*lap` |
| 4 | `a0*(...)` + forcing, saturate, commit `u^n`/`u^{n-1}` | `a0*acc` |

Because no stage chains two multiplies or a multiply into a wide add without a
register between them, the worst combinational path inside the PE is a single
DSP multiply plus the saturating store, comfortably inside the 10 ns budget at
100 MHz. The 4-stage latency is invisible to the audio rate: one oversampled
step costs ~7 `sys_clk` cycles and the per-frame budget is ~2083 cycles (see
[`timing_budget.md`](timing_budget.md)), so deepening the pipeline to chase a
faster clock, if a particular speed grade needs it, costs only latency the
budget already has in abundance. The split point to add a 5th stage is the
stage-3 `gamma2_local*lap`-then-add; register the product before the add.

## Reproducing the sign-off

```sh
cd syn/vivado
# Arty A7-35T, 2x2 spatial mesh, OS=4: synth + place + route + timing gate
vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 2 2 4
# Arty A7-100T, 3x3 mesh
vivado -mode batch -source build_arty.tcl -tclargs xc7a100tcsg324-1  3 3 4
# time-multiplexed build (one PE pool, larger grids fit)
vivado -mode batch -source build_arty.tcl -tclargs xc7a35ticsg324-1L 8 8 4 true
```

The script runs `opt_design` / `place_design` / `route_design`, writes
`util_<tag>.rpt` and `timing_<tag>.rpt`, and exits non-zero if the post-route
worst negative slack (setup or hold) is negative, so the run is a pass/fail
timing gate. A clean run prints `TIMING MET: positive slack at the requested
clocks`.
