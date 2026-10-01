# docs/media/

Sound demos, board renders and 3D models used by the top-level README. Every
file here is generated. Change the scripts, not the outputs.

```sh
docs/media/scripts/make_media.sh
```

## What is here

| Path | Contents | Generated from |
| --- | --- | --- |
| `audio/demo_{gong,plate,drum}.mp3` | Polyphonic demo phrases | `model/demo_render.m` (Octave) |
| `audio/chaos_ab.mp3` | One strike, $\alpha = 0$ then $\alpha = 0.42$ | `scripts/mesh_media.py` |
| `audio/*.mp4` | Spectrogram + moving playhead + audio. Drag one into a GitHub comment or the web editor to get an inline player | `scripts/mesh_media.py` |
| `images/spectrogram_*.png` | Spectrogram per clip | `scripts/mesh_media.py` |
| `images/mesh_strike.gif` | 32×32 mesh after a strike, linear vs chaos | `scripts/mesh_media.py` |
| `images/{mainboard,panel}_{top,bottom}.png` | Solder-mask style board views | `scripts/render_pcb.py` |
| `images/{stack_hero,stack_side,mainboard_3d,panel_3d}.png` | 3D renders | `scripts/render_3d.mjs` |
| `3d/courant_stack.stl` | Mated stack, one mesh, for GitHub's STL viewer | `scripts/build_3d.py` |
| `3d/courant_{stack,mainboard,panel}.glb` | Coloured glTF models | `scripts/build_3d.py` |

## What these are, and are not

- **Audio is model output, not hardware.** It is rendered by the float
  reference model `model/NLMesh2D.m`. `scripts/nlmesh.py` is a NumPy port that
  `mesh_media.py` checks against Octave on every run (max |Δu| ≈ 2e-15)
  before it renders anything. The RTL's bit-exact check is a separate test:
  `model/nl_reference.m` against the GHDL testbenches.
- **Board renders are read from the native KiCad 10 files**
  (`hardware/courant/deliverables/courant.kicad_pcb`,
  `hardware/panel/design/radian_panel.kicad_pcb`): outline, cutouts, drills,
  pads, tracks, zones, silkscreen and footprint placement. Nothing in
  `hardware/` is written.
- **3D component bodies are parametric stand-ins** sized from package
  datasheets, placed at the native footprint positions. The stack spacing
  (19.99 mm) and board-to-board registration come from
  `hardware/stack/panel-stack.json`. The vendor/actual-part STEP models in
  `hardware/CURRENT_DESIGN.md` are not committed (`*.step` is gitignored), so
  these models are layout previews, not mechanical CAD. The knobs are
  illustrative: knob choice belongs to the enclosure.

## Requirements

- `octave-cli` (GNU Octave 8+)
- Python 3 with `numpy scipy matplotlib shapely trimesh mapbox_earcut pillow`
- `ffmpeg` with libmp3lame and libx264
- Node 18+ with Playwright and a Chromium build (`npm install` in `scripts/`
  fetches three.js; it renders through SwiftShader, so no GPU is needed)
