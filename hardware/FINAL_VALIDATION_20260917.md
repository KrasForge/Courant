# RADIAN final validation — 2026-09-17

Six-pot FX/direct-stack and enclosure CAD revision is complete at RTL + PCB-source + native-KiCad + reference-mechanical-CAD level.

- Mainboard: DRC **0**, unconnected **0**; SHA-256 `d7e2a898628225a0c21e27cb2387acf627036a41f7194c9551310b80ddac1b14`.
- Panel: ERC **0**, DRC **0**, unconnected **0**, parity **0**; SHA-256 `2640a117c312d2dd634bed3f620eb7622dab7716cf4d0946a9230fb8ff92d2a2`.
- Controls: **TENSION · DECAY · CHAOS · DRIVE · DELAY · REVERB**.
- Stack: Samtec **IPT1-110-06-L-D ↔ IPS1-110-01-L-D**, 40/40 pins net+XY matched, 19.99 mm fully mated, ~20.0 mm support target.
- RTL: **28/28 GHDL testbenches pass**.
- tscircuit: main typecheck/source check/full build pass; panel build pass. The exact 0201 tscircuit pad model matches **76/76** native pads.
- Main BOM: **191/191** placements resolved.
- Case CAD: CASE-P2-DIRECT-STACK; exact 2.00 mm faceplate/REVERB-insert thickness; six current macro openings + relocated MODE; mainboard shifted +0.46 mm for 19.99 mm fully-mated PCB gap; support planes updated; exported STEP validation and Xvfb preview render pass.
- Updated case assembly: hardware/panel/cad/RADIAN_P1_desktop_fit_study.step — SHA-256 ef70ab0a0f20970f53eebf58b0f1367d4517faeeebfa8a1866a3acb62fd81d42.
- Updated case shell: hardware/panel/cad/RADIAN_P1_case_shell_updated.step — SHA-256 4537715b2c1a7ae8ba7100f1178de85cac9fc652569fd058491b34546737527b.
- Main fab ZIP: `9159e62b65503af61e786e26a80dcd1be913c5a04e104c1cc5c3a0e2f93ee9a7`; embedded BOM current; ZIP integrity pass.
- Panel fab ZIP: `341016495117f15b1a56e051833066d1dab58a5879c722866f3b8b892b004080`; embedded BOM current; ZIP integrity pass.

Remaining gates require physical hardware only: first-article Samtec seating/retention and support/enclosure tolerance, real knob/fastener stack, power/thermal/fault tests, and target-FPGA implementation/bring-up.
