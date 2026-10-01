#!/usr/bin/env python3
"""Sound-demo media for the README: A/B audio, spectrograms, mesh animation.

    docs/media/scripts/make_media.sh

Everything here comes from the float reference model (model/NLMesh2D.m, via
the NumPy port in nlmesh.py, which is checked against Octave first). It is
*not* a recording of hardware: the FPGA build has not been brought up yet.
"""
import os
import shutil
import subprocess
import sys

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import cm
from scipy.io import wavfile
from scipy.signal import spectrogram

sys.path.insert(0, os.path.dirname(__file__))
from nlmesh import NLMesh2D, check_against_octave  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MEDIA = os.path.join(ROOT, 'docs', 'media')
AUD = os.path.join(MEDIA, 'audio')
WAV = os.path.join(AUD, 'wav')       # intermediate, gitignored
IMG = os.path.join(MEDIA, 'images')
FS = 48000
NX = NY = 32

# demo_render.m's gong voice (free edges, long shimmer)
GONG = dict(g2=0.05, gmax=0.451, sigma=0.4, bc='free')

BG = '#0e1116'
FG = '#e6e6e6'
MUTED = '#8b949e'


def hpf_norm(L, R):
    """demo_render.m's output chain: 45 Hz one-pole HPF, RMS target, tanh."""
    a = np.exp(-2 * np.pi * 45 / FS)

    def hp(x):
        y = np.zeros_like(x)
        xp = yp = 0.0
        for n, v in enumerate(x):
            yp = a * (yp + v - xp)
            xp = v
            y[n] = yp
        return y
    L, R = hp(L), hp(R)
    r = np.sqrt(np.mean(np.concatenate([L, R]) ** 2))
    if r > 0:
        L, R = L * 0.16 / r, R * 0.16 / r
    L, R = np.tanh(1.3 * L), np.tanh(1.3 * R)
    g = 0.95 / max(np.max(np.abs(np.concatenate([L, R]))), 1e-12)
    return L * g, R * g


def strike_note(alpha, dur, amp=1.0, v=GONG):
    m = NLMesh2D(NX, NY, FS, v['g2'], alpha, v['gmax'], v['sigma'], v['bc'])
    m.strike((NY - 1) / 2, (NX - 1) / 2, 1.6, amp)
    n = int(dur * FS)
    L, R = np.zeros(n), np.zeros(n)
    for t in range(n):
        m.step()
        L[t] = m.u[5, 5]
        R[t] = m.u[NY - 6, NX - 6]
    return L, R


def write_wav(path, L, R):
    wavfile.write(path, FS, (np.column_stack([L, R]) * 32767).astype(np.int16))


def ab_audio():
    """Same strike, chaos off then on, each normalised the same way."""
    gap = np.zeros(int(0.5 * FS))
    parts = []
    for alpha in (0.0, 0.42):
        L, R = hpf_norm(*strike_note(alpha, 3.0))
        parts.append((L, R))
    L = np.concatenate([parts[0][0], gap, parts[1][0]])
    R = np.concatenate([parts[0][1], gap, parts[1][1]])
    write_wav(os.path.join(WAV, 'chaos_ab.wav'), L, R)
    return 3.0, 0.5


def spectro_ax(ax, x, title, fmax=8000):
    f, t, S = spectrogram(x, FS, nperseg=2048, noverlap=1536, window='hann')
    S = 10 * np.log10(S + 1e-12)
    S -= S.max()
    ax.pcolormesh(t, f / 1000, S, shading='auto', cmap='magma', vmin=-90, vmax=0, rasterized=True)
    ax.set_ylim(0, fmax / 1000)
    ax.set_facecolor(BG)
    ax.set_title(title, color=FG, loc='left', fontsize=11, pad=6)
    ax.tick_params(colors=MUTED, labelsize=8)
    for s in ax.spines.values():
        s.set_color('#30363d')
    ax.set_ylabel('kHz', color=MUTED, fontsize=8)


def spectrogram_png(name, title, out, marks=None, fmax=8000):
    sr, x = wavfile.read(os.path.join(WAV, name))
    x = x.astype(float).mean(axis=1) if x.ndim == 2 else x.astype(float)
    fig, ax = plt.subplots(figsize=(10, 2.6), dpi=150)
    fig.patch.set_facecolor(BG)
    spectro_ax(ax, x, title, fmax)
    ax.set_xlabel('seconds', color=MUTED, fontsize=8)
    for tx, label in (marks or []):
        ax.text(tx, 7.4, label, color=FG, fontsize=9, weight='bold',
                bbox=dict(facecolor=BG, edgecolor='none', alpha=0.7, pad=2))
    fig.tight_layout()
    fig.savefig(out, facecolor=BG)
    plt.close(fig)
    return ax


def mesh_animation(out_gif, frames=110, every=3):
    """Side-by-side: identical hard strike, alpha = 0 vs alpha = 0.42."""
    meshes = []
    for alpha in (0.0, 0.42):
        m = NLMesh2D(NX, NY, FS, GONG['g2'], alpha, GONG['gmax'], GONG['sigma'], 'fixed')
        m.strike(11.0, 12.0, 1.6, 1.0)
        meshes.append(m)
    X, Y = np.meshgrid(np.arange(NX), np.arange(NY))
    tmp = os.path.join(MEDIA, 'scripts', '.frames')
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    norm = matplotlib.colors.Normalize(-0.6, 0.6)
    for k in range(frames):
        fig = plt.figure(figsize=(9, 4.2), dpi=100)
        fig.patch.set_facecolor(BG)
        for i, (m, label) in enumerate(zip(meshes, ('linear  (α = 0)', 'chaos injection  (α = 0.42)'))):
            ax = fig.add_subplot(1, 2, i + 1, projection='3d', computed_zorder=False)
            ax.set_facecolor(BG)
            ax.plot_surface(X, Y, m.u, facecolors=cm.RdBu_r(norm(m.u)), rstride=1, cstride=1,
                            linewidth=0, antialiased=False, shade=False)
            ax.set_zlim(-1, 1)
            ax.view_init(elev=32, azim=-55)
            ax.set_box_aspect((1, 1, 0.5), zoom=1.45)
            ax.set_axis_off()
            fig.text(0.25 + 0.5 * i, 0.9, label, color=FG, fontsize=12, ha='center')
        fig.text(0.5, 0.04, f'32×32 FDTD mesh · same strike · step {k * every:4d} '
                 f'({k * every / FS * 1000:5.2f} ms of audio)', color=MUTED, ha='center',
                 fontsize=9, family='DejaVu Sans Mono')
        fig.subplots_adjust(0, 0.02, 1, 0.92, 0.0)
        fig.savefig(os.path.join(tmp, f'f{k:04d}.png'), facecolor=BG)
        plt.close(fig)
        for m in meshes:
            for _ in range(every):
                m.step()
    pal = os.path.join(tmp, 'pal.png')
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '20', '-i', os.path.join(tmp, 'f%04d.png'),
                    '-vf', 'scale=720:-1:flags=lanczos,palettegen=max_colors=96', pal], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '20', '-i', os.path.join(tmp, 'f%04d.png'),
                    '-i', pal, '-lavfi', 'scale=720:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4',
                    '-loop', '0', out_gif], check=True)
    shutil.rmtree(tmp)


def h264_args():
    """libx264 when ffmpeg has it; Fedora's stock build only ships libopenh264."""
    enc = subprocess.run(['ffmpeg', '-hide_banner', '-encoders'], capture_output=True, text=True).stdout
    if 'libx264' in enc:
        return ['-c:v', 'libx264', '-tune', 'stillimage', '-crf', '28']
    return ['-c:v', 'libopenh264', '-b:v', '400k']


def encode(name, png, title, artist='Courant reference model'):
    """MP3 for linking, MP4 (spectrogram + moving playhead) for drag-in players."""
    src = os.path.join(WAV, name + '.wav')
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', src, '-codec:a', 'libmp3lame', '-q:a', '2',
                    '-metadata', f'title={title}', '-metadata', f'artist={artist}',
                    os.path.join(AUD, name + '.mp3')], check=True)
    sr, x = wavfile.read(src)
    dur = len(x) / sr
    # playhead spans the spectrogram plot area (tight_layout margins, measured)
    from PIL import Image
    w, h = Image.open(png).size
    x0, x1 = 0.062 * w, 0.985 * w
    vf = (f"[0:v]scale={w}:{h}[bg];color=c=white@0.85:s=3x{int(h * 0.67)}[ph];"
          f"[bg][ph]overlay=x='{x0:.1f}+({x1 - x0:.1f})*t/{dur:.3f}':y={int(h * 0.13)}:shortest=1,format=yuv420p,"
          f"pad=ceil(iw/2)*2:ceil(ih/2)*2")
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-loop', '1', '-framerate', '30', '-i', png, '-i', src,
                    '-filter_complex', vf, *h264_args(),
                    '-c:a', 'aac', '-b:a', '160k', '-t', f'{dur:.3f}', '-movflags', '+faststart',
                    os.path.join(AUD, name + '.mp4')], check=True)


def main():
    os.makedirs(WAV, exist_ok=True)
    os.makedirs(IMG, exist_ok=True)
    err = check_against_octave(os.path.join(ROOT, 'model'))
    print(f'NumPy port vs Octave NLMesh2D: max |du| = {err:.2e}')
    assert err < 1e-9, 'nlmesh.py has drifted from model/NLMesh2D.m'

    note, gap = ab_audio()
    demos = [
        ('chaos_ab', 'A/B: identical strike, chaos off (left) vs on (right)'),
    ]
    for name, title in demos:
        if not os.path.exists(os.path.join(WAV, name + '.wav')):
            sys.exit(f'missing {name}.wav')
        png = os.path.join(IMG, f'spectrogram_{name}.png')
        marks = [(0.1, 'α = 0  (linear)'), (note + gap + 0.1, 'α = 0.42  (chaos on)')] if name == 'chaos_ab' else None
        spectrogram_png(name + '.wav', title, png, marks)
        encode(name, png, title)
        print('audio', name)
    mesh_animation(os.path.join(IMG, 'mesh_strike.gif'))
    print('animation done')


if __name__ == '__main__':
    main()
