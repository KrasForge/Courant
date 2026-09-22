# Design sources and provenance

Accessed/reviewed during P1 creation, 15 September 2026. This list separates user-supplied facts, external datasheets, design choices and unverified assumptions. Prices/stock are not established by this package.

## User files

`reference/input_manifest.json` records SHA-256 hashes of the original supplied mainboard files and key datasheets. Mainboard PCB and STEP files were not edited. The matching previous CAD-input hashes establish which hardware revision the fit study used.

- `courant-panel-interface.csv`: 45 header pin/net entries; authoritative mainboard boundary for this panel.
- `courant-panel-hardware.md`: proposed off-board choices, mainboard 5 V input and 0–5 V CV limitations. These selections were proposals, not frozen purchases.
- `courant.kicad_pcb`, `courant-assembly.step`, `courant-bom.csv`: original board geometry/components. Prior CAD-aligned STEP used for assembly fit reference.
- `Bourns_PTV09_potentiometer.pdf`, pages 1–2: PTV09A configuration 4 bushingless/rear-facing footprint and shaft dimensions. Signal terminals span 5.0 mm with the wiper midway (2.5 mm pitch). Changed neither resistance nor pot variant.
- `Bourns_PEC11R_encoder.pdf`, pages 2–3: rear-facing switch encoder footprint and ordering code. P1 selects 20 mm shaft rather than the original proposed 15 mm shaft, explicitly changing the MPN to PEC11R-4220F-S0024.
- `SameSky_SDS-J_DIN5_socket.pdf`: retained right-angle off-board DIN dimensional context. P1 does not claim this part can mount on the single panel PCB.
- Original Rev F.1 CAD archive: retained panel centres, mainboard alignment, case and dock geometry. Original CAD mechanical-fit results are not reused as P1 validation results.

## New external electrical/mechanical data

1. **Texas Instruments, TPS54302 datasheet** (SLVSD79C, March 2026), pinout, 5 V/3 A typical application and layout guidance. Circuit topology and nominal passive values are based on that application; the resulting PCB is not claimed to be TI's validated layout.
   https://www.ti.com/lit/ds/symlink/tps54302.pdf

2. **Bourns SRP7050TA power inductor series**, SRP7050TA-100M row and recommended land pattern. Nominal 10 uH, 4 A Irms and 7.5 A Isat under datasheet conditions; these ratings do not establish the enclosure temperature or system current capability.
   https://www.bourns.com/docs/Product-Datasheets/SRP7050TA.pdf

3. **Texas Instruments OPAx192 datasheet**, OPA2192 pinout and single-supply operation. The modulation equation is a P1 design derivation, not a reproduced reference circuit. Output headroom and dynamics need testing.
   https://www.ti.com/lit/ds/symlink/opa2192.pdf

4. **Thonk WQP518MA/PJ398SM supplier drawing and product page**. This is a supplier's dimensional reference, not a vendor-approved P1 footprint or manufacturer STEP model. The under-barrel hole and three contact positions are derived from the drawing.
   https://www.thonk.co.uk/shop/thonkiconn/
   https://www.thonk.co.uk/wp-content/uploads/2018/07/Thonkiconn_Jack_Datasheet-new.jpg

5. **E-Switch 100-series configurator and family datasheet**. M2 straight PCB pins, T1 actuator, B1 bushing, SP1 ON-ON and proposed R gold-contact option. Exact variant availability and purchased dimensions need confirmation.
   https://www.e-switch.com/product/100-series-miniature-toggle-switch/
   https://configured-product-images.s3.amazonaws.com/Datasheets/100.pdf

6. **E-Switch ST110001 mechanical drawing** for the Q silver-contact version, hosted by Farnell. Used for the common M2 mechanical family (8.89 mm body, 6.35 mm bushing, 4.70 mm terminal pitch, 1.85 mm holes). It is not a specific approval of the selected R-contact variant.
   https://www.farnell.com/cad/2341777.pdf

7. **Doepfer A-100 technical documentation**, module-side 10-pin versus 16-pin connections and available rails/signals. P1 intentionally uses the 10-pin module form because it uses no bus +5/CV/gate. Bus-side connector remains 16-pin with an appropriate 16-to-10 cable.
   https://doepfer.de/a100_man/a100t_e.htm
   https://www2.doepfer.eu/index.php/en/faqs/item/orientation-of-bus-connection-cables

8. **KiCad 10 CLI documentation**, native netlist/ERC/DRC and `--refill-zones --save-board` options. `source/verify_native.sh` uses documented commands, but was not executed in the creation environment.
   https://docs.kicad.org/10.0/en/cli/cli.html

## Explicit P1 choices, not facts supplied by the user

- One four-layer interface PCB with two intended inner GND planes.
- Regulated 12 V desktop inlet rather than the earlier 5 V proposal.
- 10-pin module-side rack header and positive-rail diode OR, not a 16-pin module header or ideal-diode mux.
- Vertical mono patch jacks replacing the proposed right-angle TRS parts; separate L/R outputs retained.
- Longer encoder shaft, shared panel PCB plane at −8 mm and associated mounting spacers.
- Optional bipolar MOD circuitry and default bypass jumper; PITCH and line-level audio unchanged.
- Short DIN and desktop inlet harnesses; no extra custom carrier PCB.
- Proposed part substitutions/envelopes, unrated generic harnesses and unspecified fuse/passive entries are **release gates**, not verified purchasing selections.

## Model and analysis limitations

STEP component bodies were constructed from dimensions and simple pin shapes. They are reference geometry, not downloaded certified manufacturer models. Inner-plane connectivity, EMI, converter stability and toleranced mechanical fit remain unverified. The numerical DC report evaluates ideal resistor equations and a sampled tolerance distribution; it does not simulate the complete circuit.
