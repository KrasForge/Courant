# Pmod I2S2 codec bring-up (Arty A7)

Getting real audio in and out of the engine on the target board (README §6).
The Pmod I2S2 carries two Cirrus codecs: a **CS5343** stereo ADC and a
**CS4344** stereo DAC. This note covers how they are "initialised", the clocks
the FPGA must generate, the Pmod wiring, and the bring-up checklist.

## There is no register configuration

Both the CS5343 and the CS4344 are **hardware-mode (stand-alone) codecs**: they
have *no* I2C or SPI control port and *no* register map. There is nothing to
write at power-up. Each codec selects its speed mode automatically from the
**MCLK/LRCK ratio** and begins converting as soon as it sees valid, stable
clocks at a supported ratio. So on this board, "codec initialisation" is
entirely a clocking problem:

> Provide a clean MCLK, a serial bit clock (SCLK/BCLK), and a word-select
> (LRCK) at a supported ratio, and the codec runs.

The FPGA is therefore the **I2S master** and generates all three clocks.
[`src/rtl/i2s_clkgen.vhd`](../src/rtl/i2s_clkgen.vhd) does this.

## Clocks and ratios

Targeting `f_s = 48 kHz` in single-speed mode:

| Clock | Frequency | Ratio | Source |
| --- | --- | --- | --- |
| MCLK | 12.288 MHz | 256 x f_s | MMCM from the 100 MHz oscillator |
| BCLK (SCLK) | 3.072 MHz | 64 x f_s (= MCLK / 4) | `i2s_clkgen` |
| LRCK | 48 kHz | 1 x f_s (= BCLK / 64) | `i2s_clkgen` |

`MCLK / LRCK = 256` is a single-speed-mode ratio valid for both the CS5343 and
the CS4344 (they also accept 384x / 512x). `BCLK = 64 x f_s` gives 32 bit-clocks
per channel, enough for the 24-bit word MSB-justified into a 32-bit slot that
[`i2s_transceiver`](../src/rtl/i2s_transceiver.vhd) drives. LRCK is a 50%-duty
square wave: low = left, high = right.

### Generating MCLK (clocking wizard / MMCM)

12.288 MHz is not an integer division of the 100 MHz board oscillator, so MCLK
comes from an MMCM (Vivado Clocking Wizard). One working solution:

```
CLKIN1   = 100.000 MHz
M (MULT) = 49.125         -> VCO = 614.0625 MHz (within the Artix-7 MMCM range)
O (DIV)  = 49.953125      -> 12.288 MHz   (CLKOUT0 = MCLK)
```

The exact M/O are part-specific; let the Clocking Wizard solve for 12.288 MHz
and check the reported output is within a few ppm. `i2s_clkgen` then divides
MCLK down to BCLK and LRCK with simple synchronous counters, so all three clocks
are phase-locked with no drift. (For 44.1 kHz, target MCLK = 11.2896 MHz the
same way; the divider ratios are unchanged.)

On real silicon, forward MCLK and BCLK to the codec pins through an **ODDR**
(clock-capable output buffer), not through logic, to keep the edges clean;
`i2s_clkgen` assigns them directly, which is equivalent in simulation and the
point at which to drop in the ODDR for hardware.

## Pmod wiring (Pmod I2S2 on header JA)

The Pmod I2S2 has two 6-pin headers: **J1 = ADC (line in)**, **J2 = DAC
(line out)**. Both share the master clock and bit/word clocks; only the data
pin differs (ADC drives SDOUT, DAC receives SDIN).

| Signal | Direction (FPGA) | Pmod I2S2 pin | Arty Pmod JA | Arty pkg pin |
| --- | --- | --- | --- | --- |
| MCLK | out | MCLK | JA1 | G13 |
| LRCK | out | LRCK | JA2 | B11 |
| SCLK (BCLK) | out | SCLK | JA3 | A11 |
| SDIN (to DAC) | out | SDIN (J2) | JA4 | D12 |
| SDOUT (from ADC) | in | SDOUT (J1) | JA7 | D13 |
| GND / VCC | - | GND / VCC | JA5/6, JA11/12 | - |

Adjust the JA pin LOCs to your wiring; the clock ratios are independent of the
pin assignment. These are the pins constrained in
[`syn/vivado/arty_a7.xdc`](../syn/vivado/arty_a7.xdc).

Note that `top_resonator` is currently an I2S *slave* (it takes `bclk`/`lrclk`
as inputs). For a master-mode board build, drive both the codec pins **and**
`top_resonator`'s `bclk`/`lrclk` inputs from `i2s_clkgen`, so the transceiver
frames against the same clocks the codec sees.

## Verification

### Simulation (clock ratios)
[`src/tb/i2s_clkgen_tb.vhd`](../src/tb/i2s_clkgen_tb.vhd) drives `i2s_clkgen`
from a 12.288 MHz MCLK and checks, over several frames, that MCLK:BCLK:LRCK is
exactly 256:64:1, that the ratios never deviate (stable, not momentarily right),
that LRCK is 50%-duty, and that MCLK is forwarded unchanged. This is the
bench-equivalent of the scope check below.

### On hardware (scope / logic analyzer)
After FPGA configuration, confirm at the Pmod header:

1. **MCLK** present at 12.288 MHz, clean (no missing edges).
2. **BCLK** at 3.072 MHz, **LRCK** at 48 kHz, both phase-locked to MCLK
   (BCLK = MCLK/4, LRCK = BCLK/64).
3. **LRCK** is a 50%-duty square wave aligned to BCLK.
4. The codec produces output: with SDIN fed a known tone (or SDOUT looped to
   SDIN), the recovered samples on SDOUT track the input. Because the codecs
   self-start on valid clocks, stable clocks at the ratios above are the
   acknowledgement that the codec has initialised; there is no config-ack
   register to read back.
