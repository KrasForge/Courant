Project-local production footprint snapshot for the canonical RADIAN mainboard.

The native board is authoritative. The library now uses semantic package/part identities instead of generator-era aliases while preserving the proven board geometry. All BOM placements carry Manufacturer/MPN metadata and a project-local 3D model.

Routing reconciliation rule: copper, vias, footprint placement/orientation, pad positions/sizes/nets/layers are preserved. The only intentional package-geometry change in the 2026-09-18 exact-part pass is J1–J4 Molex KK-254 drill diameter 1.00 -> 1.02 mm plus corrected connector courtyards. Geometry variants such as the existing 0201/0805/1210 artwork variants remain separate library footprints so native instances match their library copies exactly.

J1/J3/J4 are Molex 22-23-2021; J2 is Molex 22-23-2061; J17/J18 are Samtec IPT1-110-06-L-D. Molex and Samtec connector STEP solids in this project are drawing-derived reference geometry, not vendor-supplied STEP files. Standard IC/passive package models are project-local copies of package-accurate KiCad STEP assets. This is not a substitute for first-article fit, solderability, thermal, power, or functional qualification.
