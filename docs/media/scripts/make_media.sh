#!/usr/bin/env sh
# Regenerate every README image, 3D model and sound demo under docs/media/.
# Needs: octave-cli, python3 (numpy scipy matplotlib shapely trimesh
# mapbox_earcut pillow), ffmpeg, node + Playwright/Chromium.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)

mkdir -p "$root/docs/media/audio/wav"
(cd "$root/model" && octave-cli --eval "demo_render('outdir', '$root/docs/media/audio/wav')")
python3 "$here/mesh_media.py"

python3 "$here/render_pcb.py"
python3 "$here/build_3d.py"
(cd "$here" && npm install --silent && node render_3d.mjs)
python3 "$here/autocrop.py" stack_hero.png stack_side.png mainboard_3d.png panel_3d.png
