# Courant
A 2D finite-difference physical-modeling synthesis engine in structural VHDL,
with amplitude-dependent non-linear "chaos injection."

This project simulates a vibrating two-dimensional acoustic membrane (a drum
head, a plate, a sheet of metal) directly in FPGA fabric. Instead of recording
or sampling an instrument, it solves the acoustic wave equation in real time on
a spatial mesh of arithmetic cells and streams the result out as audio. A
non-linear tension term makes the mesh stiffen under load, so hard hits bend
pitch upward and bloom into inharmonic, metallic partials before settling back
into a natural decay.

> **Status: pre-silicon, simulation-first.** This is a design and reference
> model repository. The numerical model and RTL are developed and validated in
> simulation (GHDL) before any board bring-up.

---

## Why an FPGA

A 2D mesh is embarrassingly parallel: every node runs the *same* small update
every time step, reading only its four neighbours. That maps naturally onto
FPGA fabric, where many nodes update concurrently and the per-sample cost does
not grow the way a sequential `for`-loop over the grid does on a CPU.

The honest trade is real, though, and this README states it plainly rather than
selling a fantasy:

| Aspect | Software (CPU / plugin) | This FPGA engine |
| --- | --- | --- |
| **Grid scaling** | Sequential per node; cost grows with node count | Concurrent nodes; one mesh step per audio sample, independent of node count (up to the fabric's DSP/LUT budget) |
| **Latency** | Governed by the host audio buffer (roughly 0.7 to 6 ms typical) | Deterministic, sub-sample; no block buffering. Group delay through the model is the physical wave propagation itself |
| **Per-node non-linearity** | Often simplified or dropped to save CPU | Evaluated on every node, every step |
| **Iteration speed** | Edit, recompile in seconds | Requires re-synthesis (minutes); behaviour bounded by chosen fabric |
| **Cost / footprint** | Runs on hardware you already own | Needs an FPGA plus audio codec; each extra voice consumes finite DSP/LUT |

FPGAs win on **deterministic parallelism and latency**. Software wins on
**flexibility and cost**. This project is about the former.

---

## 1. Mathematical foundation

The engine models a lossy 2D wave equation for the transverse displacement
`u(x, y, t)` of the surface:

$$\frac{\partial^2 u}{\partial t^2} = c^2\left(\frac{\partial^2 u}{\partial x^2} + \frac{\partial^2 u}{\partial y^2}\right) - 2\sigma\frac{\partial u}{\partial t}$$

* `c` is the wave propagation speed (sets pitch and tension)
* `sigma` is the frequency-independent damping (sets decay time)

### Discretisation

Using centred finite differences on a grid with spacing `h` and time step
`k = 1/f_s` (with `f_s` the audio rate, e.g. 48 kHz), the explicit update for
node `(i, j)` is:

$$u_{i,j}^{n+1} = \frac{1}{1+\sigma k}\left[\,2u_{i,j}^{n} - (1-\sigma k)\,u_{i,j}^{n-1} + \gamma^2\left(u_{i+1,j}^{n} + u_{i-1,j}^{n} + u_{i,j+1}^{n} + u_{i,j-1}^{n} - 4u_{i,j}^{n}\right)\right]$$

where `gamma = ck/h` is the **Courant number**. The bracketed Laplacian stencil
is the only inter-node coupling; everything else is local.

### Stability (CFL), and why it is the whole game here

An explicit 2D scheme is only stable when the Courant number satisfies:

$$\gamma^2 \le \tfrac{1}{2}\qquad\left(\gamma \le \tfrac{1}{\sqrt 2}\approx 0.7071\right)$$

Cross that line and the scheme does not merely "sound bad," it diverges
**exponentially**. This matters enormously for the next section.

---

## 2. The non-linear twist: chaos injection

A linear mesh with constant `gamma` is predictable and, frankly, a bit sterile.
This engine makes the local Courant term **amplitude-dependent**, so the mesh
stiffens where it is moving hardest:

$$\gamma_{i,j}^2 = \gamma_0^2 + \alpha\,(u_{i,j}^{n})^2$$

* `gamma0^2` is the base stiffness and pitch
* `alpha` is the chaos coupling

High-amplitude regions momentarily raise the local wave speed, bending the
wavefront, shifting pitch up, and bleeding energy into inharmonic partials. This
is the characteristic "tension modulation" of struck plates and gongs, including
genuine period-doubling routes into chaos.

### The catch (and the fix)

`alpha * u^2` only ever *increases* `gamma^2`, and it does so most exactly when
the sound is loudest. In other words it pushes toward the CFL boundary precisely
when you least want it to. Naively, a hard hit drives `gamma^2 > 1/2` and the
mesh blows up. **Output saturation alone does not save you**: it clamps the
*displayed* sample while the internal state pins to the rails and buzzes at
Nyquist. You get a brick, not a gong.

The fix is structural, and is treated here as a first-class part of the design
rather than an afterthought:

1. **Clamp the local term:** `gamma2_local = clamp(gamma0^2 + alpha*u^2, 0,
   gamma2_max)` with `gamma2_max < 1/2` (a safety margin below the CFL limit).
   This bounds the instability into a limit-cycle / soft-clip regime that is
   chaotic and rich, but convergent.
2. **Saturating state arithmetic:** displacement is clamped to the Q1.23 range,
   turning blow-up energy into musical soft saturation.
3. **Guaranteed decay:** the damping term `sigma` ensures the linear regime
   always returns to rest.

### Aliasing, stated rather than hidden

A squaring non-linearity at the base sample rate generates harmonics above
Nyquist that fold back as aliasing. "Zero aliasing" would be a false claim for
any non-linear scheme. The mitigation is **oversampling**: run the mesh at an
integer multiple of `f_s` (the FPGA has ample clock headroom, see below) and
decimate on output. The oversampling factor is a documented quality and area
knob, not magic.

---

## 3. Architecture

```
                 +-------------------------------------+
                 |        Control / Register Bus       |
                 |  (gamma0^2, sigma, alpha, g2_max)   |
                 +-------------------------------------+
                                    |  (control rate; coeffs precomputed)
                                    v
 +---------------+   +-----------------------------------+   +----------------+
 |  Audio In     |   |         Parallel Node Mesh        |   |  Audio Out     |
 | (I2S RX)      |==>| [0,0] [0,1] [0,2] ... (NX cols)   |==>| (I2S TX)       |
 | strike/mallet |   |   |     |     |                   |   | stereo pickup  |
 +---------------+   | [1,0] [1,1] [1,2] ...             |   +----------------+
                     |   |     |     |                   |
                     |  ... (NY rows; fixed/free edges)  |
                     +-----------------------------------+
                                    ^
                       sample strobe (approx f_s), derived
                       from the I2S word clock (CDC)
```

### Node Processing Element (PE)

Each node owns:

* **State registers** holding `u^n` and `u^(n-1)`.
* **A fixed-point datapath** for the update above (Laplacian, the `alpha*u^2`
  term, the `gamma2_local` clamp, the bracket, and the `a0 * (...)` scale),
  mapped to DSP slices.
* **Nearest-neighbour wiring** (N/S/E/W). Edge nodes use **fixed** (`u = 0`,
  Dirichlet) or **free** (mirrored, Neumann) boundaries.

### Parallel vs. time-multiplexed: the real engineering choice

A *fully spatial* mesh instantiates one PE per node. That is `O(N^2)` DSP slices
and hits a hard ceiling fast: a 32x32 mesh with a couple of multipliers per node
is well over a thousand DSPs, beyond most mid-range parts. The honest options:

* **Fully spatial:** small mesh on a large FPGA. Lowest latency, biggest area.
* **Time-multiplexed:** fold the grid through a small pool of PEs. At 100 MHz
  over 48 kHz there are roughly 2083 system-clock cycles per audio sample,
  plenty to sweep a modest grid through a pipeline and still finish within one
  sample period.

This repo targets a *parameterisable* mesh so the same RTL can be built either
way; the choice is a synthesis-time trade, documented per target.

### "Single cycle" and "zero latency": what is actually true

The per-node update is a multi-stage pipeline (multiplies, the clamp, the final
scale), not a single combinational clock edge. What *is* true:

* **One mesh time-step per audio sample:** the mesh advances on each sample
  strobe.
* **No audio-buffer latency:** there is no DAW block to fill, so end-to-end
  latency is sub-sample and deterministic, dominated by the codec and the PE
  pipeline depth (nanoseconds to microseconds), not milliseconds.

### Interfaces

* **I2S transceiver:** serial and parallel RX/TX. RX captures the incoming
  sample used as the excitation (the "mallet"); TX streams two pickup nodes as
  left and right.
* **Clock-domain crossing:** the mesh is strobed once per audio frame from the
  I2S word clock, isolating the arithmetic core from the system clock.

---

## 4. Numerics

| Property | Value |
| --- | --- |
| Format | Signed **Q1.23** (24-bit two's complement) |
| Range / resolution | `[-1.0, +1.0)` / `2^-23` (approx `1.19e-7`) |
| Multiply | Q1.23 times Q1.23 gives Q2.46, rescaled by a `>>23` shift, saturated |
| Accumulation | Wide (48-bit) guard accumulator, saturated on store |
| Coefficients | `a0 = 1/(1+sigma*k)` and `sigk1 = (1-sigma*k)` are **precomputed** on the control bus, so there is no per-node division (division is expensive; this avoids it entirely) |
| Overflow | Saturating arithmetic throughout, giving graceful soft-clip, never wrap-around spikes |

---

## 5. Repository structure (planned)

```text
.
├── src/
│   ├── rtl/
│   │   ├── fdtd_pkg.vhd          # Q1.23 types, math helpers, the node_update function
│   │   ├── node_element.vhd      # single-node PE (registers + datapath)
│   │   ├── grid_mesh.vhd         # NX x NY structural mesh, boundary wiring, pickup taps
│   │   ├── i2s_transceiver.vhd   # I2S RX/TX + sample-strobe generation
│   │   └── top_resonator.vhd     # mesh + I/O + control bus + CDC
│   └── tb/
│       ├── node_element_tb.vhd   # unit test for the node datapath / node_update
│       └── top_resonator_tb.vhd  # system impulse-response & stability tests
├── model/                        # Python/MATLAB reference model + stability study
├── sim/                          # GHDL scripts, Makefile, captured impulse responses
├── docs/                         # derivation, fixed-point analysis, deviations log
├── MILESTONES.md
└── README.md
```

---

## 6. Building & simulating

The reference flow uses **GHDL** (open-source, VHDL-2008):

```sh
# analyse + elaborate + run the node unit test
ghdl -a --std=08 src/rtl/fdtd_pkg.vhd src/rtl/node_element.vhd src/tb/node_element_tb.vhd
ghdl -r --std=08 node_element_tb --wave=sim/node.ghw

# full system impulse-response / stability test
make -C sim
```

Synthesis targets a low-cost dev board for bring-up, for example a **Digilent
Arty A7** (Xilinx Artix-7) with a **PMOD I2S2** codec, keeping the path to real
audio cheap and reproducible. Resource budgeting (spatial vs. time-multiplexed)
is tracked per target in `docs/`.

---

## 7. What this is and is not

* It **is** a deterministic, low-latency, parallel physical-modeling engine and
  an honest study of non-linear FDTD on FPGA.
* It **is** simulation-first: nothing is claimed to "work on hardware" until it
  has.
* It is **not** zero-latency, zero-aliasing, or single-clock-cycle. Those are
  marketing, and this document avoids them deliberately.
* It is **not** a finished instrument yet. See the roadmap.

---

## License

MIT.
