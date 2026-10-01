#!/usr/bin/env python3
"""README sound demos captured from the RTL (not the float model).

    python3 docs/media/scripts/rtl_media.py CAPTURE_DIR

CAPTURE_DIR holds raw I2S captures written by the Verilator renderer
(render_rtl SCORE FRAMES OUT.s24le OUT.txt): 48 kHz, stereo, signed 24-bit
little-endian. The scores (serial MIDI bit timing) are in docs/media/scores/.

Each clip gets one constant gain that puts its peak at -1 dBFS. There is no
EQ, compression, reverb or editing.
"""
import os
import sys

import numpy as np
from scipy.io import wavfile

sys.path.insert(0, os.path.dirname(__file__))
from mesh_media import AUD, FS, IMG, WAV, encode, spectrogram_png  # noqa: E402

CLIPS = [
    ('rtl_berlin_voltage', '01_berlin_voltage', 'Berlin Voltage: dry EBM / industrial pulse, 132 BPM'),
    ('rtl_oxide_dub', '02_oxide_dub', 'Oxide Dub: free-boundary metallic dub, long tails, 96 BPM'),
    ('rtl_kreuz_rhythm', '03_kreuz_rhythm', 'Kreuz Rhythm: metallic polyrhythm, 150 BPM'),
]


def read_s24le(path):
    b = np.frombuffer(open(path, 'rb').read(), np.uint8)
    b = b[:len(b) // 6 * 6].reshape(-1, 3).astype(np.int32)
    v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
    v = np.where(v & 0x800000, v - 0x1000000, v)
    return (v / 2.0 ** 23).reshape(-1, 2)


def main(capture_dir):
    os.makedirs(WAV, exist_ok=True)
    for name, src, title in CLIPS:
        x = read_s24le(os.path.join(capture_dir, src + '.s24le'))
        gain = 10 ** (-1 / 20) / np.abs(x).max()
        wavfile.write(os.path.join(WAV, name + '.wav'), FS, (x * gain * 32767).astype(np.int16))
        png = os.path.join(IMG, f'spectrogram_{name}.png')
        spectrogram_png(name + '.wav', title, png, fmax=3000)
        encode(name, png, title, artist='RADIAN RTL (Verilator capture)')
        print(f'{name}: {len(x) / FS:.2f} s, gain {20 * np.log10(gain):+.1f} dB')


if __name__ == '__main__':
    main(sys.argv[1])
