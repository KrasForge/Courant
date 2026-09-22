#!/usr/bin/env bash
# Run on a machine with KiCad 10 installed. DOES NOT order or fabricate anything.
# Official CLI options: https://docs.kicad.org/10.0/en/cli/cli.html
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v kicad-cli >/dev/null || { echo 'KiCad 10 kicad-cli is required.' >&2; exit 127; }
mkdir -p "$ROOT/reports/native"
kicad-cli version | tee "$ROOT/reports/native/version.txt"
# The generator did not invoke KiCad. Parsing/export failure is itself a blocker.
kicad-cli sch export netlist --format kicadxml --output "$ROOT/reports/native/panel_netlist.xml" "$ROOT/design/radian_panel.kicad_sch" || exit $?
kicad-cli sch erc --format json --severity-all --exit-code-violations --output "$ROOT/reports/native/erc.json" "$ROOT/design/radian_panel.kicad_sch"
ERC=$?
# --save-board deliberately saves KiCad's filled planes to a COPY, preserving draft source.
TMP="$ROOT/reports/native/work";mkdir -p "$TMP"
cp "$ROOT/design/"*.kicad_pcb "$ROOT/design/"*.kicad_pro "$ROOT/design/"*.kicad_sch "$TMP/"
cp "$ROOT/design/fp-lib-table" "$ROOT/design/sym-lib-table" "$TMP/"
# Preserve relative project libraries for the temporary project.
ln -sfn "$ROOT/library" "$ROOT/reports/native/library"
ln -sfn "$ROOT/cad" "$ROOT/reports/native/cad"
kicad-cli pcb drc --refill-zones --save-board --schematic-parity --all-track-errors --format json --severity-all --exit-code-violations --output "$ROOT/reports/native/drc.json" "$TMP/radian_panel.kicad_pcb"
DRC=$?
printf 'ERC exit=%s\nDRC exit=%s\n' "$ERC" "$DRC" | tee "$ROOT/reports/native/status.txt"
echo 'Inspect ALL reports. No excluded error is automatically accepted. Even zero ERC/DRC does not verify circuit behavior, chosen footprints, electrical safety, or physical fit.'
if [[ "$ERC" -ne 0 || "$DRC" -ne 0 ]];then exit 1;fi
