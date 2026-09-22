# Milestones

## M0: Numerical reference model & stability study
- [x] MATLAB/Octave reference model (`model/fdtd_ref.m`)
- [x] CFL/stability sweep with plots (`model/stability_study.m`)
- [x] Repository scaffolding: `src/`, `sim/`, `docs/` tree and GHDL CI
      (`.github/workflows/ghdl-ci.yml` installs GHDL and runs `make -C sim`,
      which wildcards every testbench)

## M1: Node PE RTL & unit test
- [x] `src/rtl/fdtd_pkg.vhd` — Q1.23 types and `node_update` function
- [x] `src/rtl/node_element.vhd` — single-node processing element
- [x] `src/tb/node_element_tb.vhd` — unit testbench

## M2: Full mesh and system testbench
- [x] `src/rtl/grid_mesh.vhd` — NX×NY structural mesh with boundary wiring
- [x] `src/tb/top_resonator_tb.vhd` — impulse-response and stability tests

## M3: I/O integration
- [x] `src/rtl/i2s_transceiver.vhd` — I2S RX/TX + sample-strobe
- [x] `src/rtl/top_resonator.vhd` — top-level with control bus and CDC

## M4: Board bring-up
- [x] Synthesis for Digilent Arty A7 (`syn/vivado/arty_synth.vhd`,
      `build_arty.tcl`, `arty_a7.xdc`)
- [x] Resource budget documented in `docs/resource_budget.md`

## M5: Standalone instrument board
- [x] `hardware/courant/` — tscircuit schematic for the Rev A board
- [x] Device pinouts checked against manufacturer datasheets
- [x] Board-specific electrical rule checks (`npm run check`)
- [x] Vivado pin constraints generated from the board's own `io` map
- [x] Route the board. 2192 segments, 4436.7 mm, 313 vias on six layers, both
      ground planes uncut, no track under 0.15 mm: **0 DRC errors, 0
      unconnected**. tscircuit places it; KiCad writes the Specctra DSN and
      Freerouting cuts most of the copper (`npm run route`).
- [x] Finish the last connections. The nine that no router could close were not
      a routing problem: the back-side decoupling array was 0402 centred on the
      ball grid, and a 0402 land spans 1.56 mm on a 1.0 mm pitch, so each
      capacitor covered all four of its ball's escape slots — ten of the twenty
      slots needed. `design.ts` now places them as 0201, offset half a pitch
      diagonally onto a slot and turned 45 degrees, which costs one slot per
      capacitor instead of four. `scripts/reland_decaps.py` moves that onto the
      routed board without re-routing it; `scripts/close.py` then closes what
      is left with a real grid search, since every earlier tool could only draw
      straight lines, Ls and mitres and the survivors needed 20-36 segment
      paths. The two 0.1373 mm clearance violations are fixed by shifting the
      offending segment 0.02 mm, not by moving components.
- [ ] Measure the actual 5 V draw on a real board. Estimated at ~0.30 A against
      the 3 A the source specifies; that one number decides whether a Eurorack
      case's +5 V rail can run it (see `deliverables/courant-eurorack.md`).
- [ ] Eurorack, if wanted: an adapter cable with a fuse and reverse-polarity
      diode is enough for power, and one 10 kOhm resistor per CV channel from
      VREF25 converts the front end to +/-5 V bipolar exactly. Only modular-level
      audio output needs new circuitry — the board is 4.5 dB below it and has no
      bipolar rail to swing into.
- [x] Panel board integrated at `hardware/panel/` (RADIAN Panel P1): 180.6 ×
      108 mm, 4 layers, carrying the panel controls and the 12 V → 5.08 V
      inlet. Ground planes filled (they had outlines but no fill, so there was
      no plane), DRC run for the first time and cleared 2 → 0 by moving SW3
      0.6 mm off two header courtyards, Gerbers and drills generated, and all
      45 harness pins verified against the mainboard interface net for net.
      Three `power_pin_not_driven` ERC findings remain by choice — see
      `hardware/panel/INTEGRATION.md`.
- [ ] Fabricate and bring up: rails, JTAG, configuration, audio
- [x] SPI master RTL for the MCP3208 panel/CV ADC — `src/rtl/adc_mcp3208.vhd`
      with `src/tb/adc_mcp3208_tb.vhd`. Scans CH0-2 (pots, to panel_ctrl) and
      CH3-4 (pitch/mod CV, to cv_frontend) round-robin at 1 MHz SCLK, which is
      the MCP3208's 2.7 V figure rather than its 5 V one because this board runs
      it at VDD 3.3 V. **Not simulated here — GHDL is not installed in this
      environment; the GHDL CI job is what verifies it.**
      Integration note: the board's CV divider is 20k/20k into a 2.5 V
      reference, so one volt is 819.2 codes, not the 4096 codes per volt
      `cv_frontend`'s defaults assume. Instantiate it with CV_SCALE = 960,
      CV_SHIFT = 16 for 1V/oct tracking.
- [x] Swap U1 to XC7A50T-1FTG256I. Done in `design.ts` and in the routed
      board. The pin compatibility is now verified rather than assumed:
      `reference/xc7a50tftg256pkg.txt` and `reference/xc7a35tftg256pkg.txt` are
      byte-identical from line 2 to the end — all 256 balls, banks, I/O types
      and no-connect flags — and differ only in the device name on the header
      line. So the swap is a part number and nothing else: same footprint,
      placement, copper, ball assignments and generated XDC. It is $51.74
      cheaper (JLCPCB $67.01 against $118.75, 135 in stock against 175),
      carries 52,160 logic cells against 33,280 and 120 DSP slices against 90 —
      taking the 4-voice build off 82% DSP utilisation — and is industrial
      temperature range rather than commercial. `npm run check` passes.
      Still worth a Vivado synthesis run to confirm timing closes (same -1
      speed grade, so it should).
