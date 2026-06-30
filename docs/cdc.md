# Clock-domain crossing (I2S <-> mesh)

The arithmetic core runs in the system-clock domain; audio I/O runs in the I2S
(BCLK / LRCLK) domain. Two things cross the boundary (README §3):

- the **excitation sample** (mallet), I2S domain -> mesh domain;
- the **L/R pickup outputs**, mesh domain -> I2S domain.

Both are handled by [`src/rtl/cdc_word.vhd`](../src/rtl/cdc_word.vhd), one
instance per direction. The per-frame **strobe** crossing (LRCLK -> a
system-domain `frame` pulse) is a separate, simpler crossing in
[`sample_strobe.vhd`](../src/rtl/sample_strobe.vhd) (issue #18).

## Strategy: synchronised flag + stable data (MCP)

Audio moves one word per ~48 kHz frame, far slower than either clock, so a full
dual-clock FIFO is overkill. `cdc_word` uses the standard multi-cycle-path
pattern:

1. On `src_valid` the source latches `src_data` into a holding register and
   **toggles a single request bit** `req`.
2. `req` is the *only* signal that crosses asynchronously. It passes through a
   **two-flop synchroniser** in the destination domain; any metastability is
   resolved within those two flops.
3. A toggle edge on the synchronised `req` means a new word is ready. The
   destination then **captures the holding register** into a registered output.

The multi-bit data is never sampled bit-by-bit across the boundary (which could
tear into a mix of old/new bits). It is read only when it is guaranteed stable:
the holding register last changed at least the synchroniser latency earlier and
does not change again until the next transfer.

## Why this is safe and deterministic here

- **Metastability**: confined to the 2-flop synchroniser on the 1-bit `req`.
  The data path carries no asynchronously-sampled bits.
- **No tearing**: data is captured only on the synchronised toggle edge, by
  which time the holding register has been stable for >= the synchroniser
  latency.
- **No loss**: holds when transfers are spaced wider than the destination
  synchroniser latency (a few destination clocks). For audio this is always
  true: one transfer per frame, both clocks in the MHz range, so each word is
  stable for thousands of destination cycles. Transfer is therefore exactly one
  word per frame, deterministically.
- **Timing closure**: the holding-register read across the boundary is a
  multi-cycle / false path for static timing analysis (constrain accordingly).

## Verification

[`src/tb/cdc_word_tb.vhd`](../src/tb/cdc_word_tb.vhd) runs both directions with
asynchronous clocks of different frequency, streaming 16 distinct words each way
(including both rails and alternating bit patterns) and checking the destination
recovers every word, in order, bit-for-bit. Result: no loss, no corruption.
