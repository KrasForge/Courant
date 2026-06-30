#!/usr/bin/env python3
"""
fdtd_ref.py - 2D lossy wave-equation FDTD reference model.

Implements the explicit centred-difference update from README §1:

    u[i,j]^{n+1} = a0 * ( 2*u[i,j]^n  -  sigk1*u[i,j]^{n-1}
                          + gamma^2 * Lap(u[i,j]^n) )

    Lap(u)[i,j] = u[i+1,j] + u[i-1,j] + u[i,j+1] + u[i,j-1] - 4*u[i,j]

    gamma  = c * k / h          Courant number; stable when gamma^2 <= 0.5
    a0     = 1 / (1 + sigma*k)  forward coefficient
    sigk1  = 1 - sigma*k        backward coefficient
    k      = 1 / fs             time step

Boundaries
----------
  "fixed" : Dirichlet u=0 (clamped edges — frame drum)
  "free"  : Neumann du/dn=0 (mirrored ghost — free plate)

Outputs
-------
  model/outputs/impulse_<bc>.wav          stereo 16-bit PCM audio
  model/outputs/displacement_<bc>.gif     false-colour displacement animation

Usage
-----
  python model/fdtd_ref.py                # fixed-boundary impulse response
  python model/fdtd_ref.py --free         # free-boundary variant
  python model/fdtd_ref.py --duration 3   # longer tail
  python model/fdtd_ref.py --sigma 0.5    # slower decay
"""

import argparse
import os
import wave

import numpy as np

# ---------------------------------------------------------------------------
# Documented default parameters (reproducible reference run)
# ---------------------------------------------------------------------------
DEFAULTS = dict(
    nx=32,          # grid width (columns)
    ny=32,          # grid height (rows)
    fs=48_000,      # audio sample rate (Hz)
    h=0.01,         # spatial step (m)
    # c=144 m/s → gamma=0.300, gamma^2=0.090 (well inside the 0.5 CFL limit)
    # Fundamental mode (1,1) on a 32×32 fixed-BC grid:
    #   f₁₁ = c*sqrt(2) / (2 * NX*h) ≈ 318 Hz
    c=144.0,
    sigma=1.5,      # damping (1/s); energy e-fold time ≈ 0.67 s
    duration=2.0,   # simulation duration (s)
    boundary="fixed",
)


class Mesh2D:
    """
    Explicit finite-difference 2D lossy wave equation on a rectangular grid.

    Attributes
    ----------
    u  : (ny, nx) ndarray  —  displacement at time n
    u1 : (ny, nx) ndarray  —  displacement at time n-1
    """

    def __init__(self, nx, ny, fs, h, c, sigma, boundary="fixed",
                 check_cfl=True):
        k = 1.0 / fs
        gamma2 = (c * k / h) ** 2
        if check_cfl and gamma2 > 0.5:
            raise ValueError(
                f"CFL violated: gamma^2={gamma2:.4f} > 0.5 "
                f"(c={c} m/s, h={h} m, fs={fs} Hz). Reduce c or increase h."
            )
        self.nx, self.ny = nx, ny
        self.boundary = boundary
        self.gamma2 = gamma2
        self.a0    = 1.0 / (1.0 + sigma * k)
        self.sigk1 = 1.0 - sigma * k

        self.u  = np.zeros((ny, nx), dtype=np.float64)
        self.u1 = np.zeros((ny, nx), dtype=np.float64)

    def strike(self, si, sj, radius=2.0, amp=1.0):
        """
        Apply a Gaussian displacement impulse centred on node (si, sj).

        Parameters
        ----------
        si, sj : int    row and column of the strike centre
        radius : float  Gaussian half-width in grid cells
        amp    : float  peak displacement (normalised units)
        """
        ii, jj = np.mgrid[0:self.ny, 0:self.nx]
        d2 = (ii - si) ** 2 + (jj - sj) ** 2
        self.u += amp * np.exp(-d2 / (2.0 * radius ** 2))

    def step(self):
        """Advance the mesh by one sample period (one time step k = 1/fs)."""
        # Ghost cells implement boundary condition
        if self.boundary == "fixed":
            # Dirichlet u=0: pad with zeros
            up = np.pad(self.u, 1, mode="constant", constant_values=0.0)
        else:
            # Neumann du/dn=0: ghost cell mirrors first interior cell
            # np.pad mode="reflect" gives padded[0] = data[1] (not data[0])
            up = np.pad(self.u, 1, mode="reflect")

        lap = (up[2:, 1:-1] + up[:-2, 1:-1]
               + up[1:-1, 2:] + up[1:-1, :-2]
               - 4.0 * up[1:-1, 1:-1])

        u_next = self.a0 * (2.0 * self.u - self.sigk1 * self.u1
                            + self.gamma2 * lap)
        self.u1 = self.u
        self.u  = u_next

    def sample(self, nodes):
        """Return displacement at a list of (row, col) pickup nodes."""
        return np.array([self.u[r, c] for r, c in nodes], dtype=np.float64)


# ---------------------------------------------------------------------------
# Simulation driver
# ---------------------------------------------------------------------------

def run_simulation(params, pickup_nodes, snap_interval_ms=10):
    """
    Run the FDTD simulation and collect audio and snapshot data.

    Parameters
    ----------
    params          : dict matching DEFAULTS keys
    pickup_nodes    : list of (row, col) tuples
    snap_interval_ms: interval between displacement snapshots (ms)

    Returns
    -------
    audio : (n_samples, n_pickups) float64 array
    snaps : list of (ny, nx) float64 displacement snapshots
    fs    : int sample rate
    """
    mesh = Mesh2D(
        nx=params["nx"], ny=params["ny"],
        fs=params["fs"], h=params["h"],
        c=params["c"], sigma=params["sigma"],
        boundary=params["boundary"],
    )

    mesh.strike(si=params["ny"] // 2, sj=params["nx"] // 2)

    n_samples = int(params["duration"] * params["fs"])
    snap_every = max(1, int(snap_interval_ms * 1e-3 * params["fs"]))

    audio = np.empty((n_samples, len(pickup_nodes)), dtype=np.float64)
    snaps = []

    for n in range(n_samples):
        audio[n] = mesh.sample(pickup_nodes)
        if n % snap_every == 0:
            snaps.append(mesh.u.copy())
        mesh.step()

    return audio, snaps, params["fs"]


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def save_wav(path, audio, fs):
    """Write normalised stereo (or mono) 16-bit PCM WAV."""
    peak = np.max(np.abs(audio))
    data = audio / peak if peak > 1e-12 else audio
    pcm = np.clip(data * 32767.0, -32768, 32767).astype(np.int16)
    n_channels = audio.shape[1] if audio.ndim > 1 else 1
    with wave.open(path, "wb") as wf:
        wf.setnchannels(n_channels)
        wf.setsampwidth(2)
        wf.setframerate(fs)
        wf.writeframes(pcm.tobytes())
    print(f"  wrote {path}  ({n_channels}ch, {fs} Hz, {len(pcm)} frames)")


def save_animation(path, snaps, params):
    """Save false-colour displacement animation as animated GIF."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.animation import FuncAnimation, PillowWriter
    except ImportError:
        print("  matplotlib not available — skipping animation (pip install matplotlib)")
        return

    vmax = max(np.max(np.abs(s)) for s in snaps) or 1.0
    fig, ax = plt.subplots(figsize=(5, 5))
    im = ax.imshow(snaps[0], vmin=-vmax, vmax=vmax, cmap="RdBu_r",
                   origin="lower", aspect="equal")
    ax.set_title(
        f"2D FDTD  {params['nx']}×{params['ny']}  "
        f"c={params['c']} m/s  σ={params['sigma']}  {params['boundary']} BC"
    )
    ax.set_xlabel("j (column)")
    ax.set_ylabel("i (row)")
    plt.colorbar(im, ax=ax, label="displacement u")

    def _update(frame):
        im.set_data(snaps[frame])
        return (im,)

    ani = FuncAnimation(fig, _update, frames=len(snaps), interval=40, blit=True)
    ani.save(path, writer=PillowWriter(fps=25))
    plt.close(fig)
    print(f"  wrote {path}  ({len(snaps)} frames @ 25 fps)")


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--free", action="store_true",
                        help="Use free (Neumann) boundaries instead of fixed (Dirichlet)")
    parser.add_argument("--duration", type=float, default=DEFAULTS["duration"],
                        metavar="S",
                        help=f"Simulation duration in seconds (default {DEFAULTS['duration']})")
    parser.add_argument("--sigma", type=float, default=DEFAULTS["sigma"],
                        help=f"Damping coefficient 1/s (default {DEFAULTS['sigma']})")
    parser.add_argument("--c", type=float, default=DEFAULTS["c"],
                        help=f"Wave speed m/s (default {DEFAULTS['c']})")
    parser.add_argument("--outdir",
                        default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                             "outputs"),
                        help="Output directory (default: model/outputs/)")
    args = parser.parse_args()

    params = {**DEFAULTS,
              "boundary": "free" if args.free else "fixed",
              "duration": args.duration,
              "sigma": args.sigma,
              "c": args.c}

    k = 1.0 / params["fs"]
    gamma = params["c"] * k / params["h"]
    print("Parameters:")
    print(f"  grid      : {params['nx']} x {params['ny']}")
    print(f"  fs        : {params['fs']} Hz,  k = {k:.2e} s")
    print(f"  h         : {params['h']} m")
    print(f"  c         : {params['c']} m/s")
    print(f"  gamma     : {gamma:.4f}  (gamma^2 = {gamma**2:.4f}, CFL limit = 0.5000)")
    print(f"  sigma     : {params['sigma']} 1/s")
    print(f"  boundary  : {params['boundary']}")
    print(f"  duration  : {params['duration']} s  "
          f"({int(params['duration'] * params['fs'])} samples)")
    print()

    ny, nx = params["ny"], params["nx"]
    pickup_nodes = [
        (ny // 2, nx // 4),      # left channel
        (ny // 2, 3 * nx // 4),  # right channel
    ]
    print(f"Strike    : ({ny // 2}, {nx // 2})  (grid centre)")
    print(f"Pickup L  : {pickup_nodes[0]}")
    print(f"Pickup R  : {pickup_nodes[1]}")
    print()
    print("Running simulation…")

    audio, snaps, fs = run_simulation(params, pickup_nodes)

    os.makedirs(args.outdir, exist_ok=True)
    bc = params["boundary"]
    print("Writing outputs:")
    save_wav(os.path.join(args.outdir, f"impulse_{bc}.wav"), audio, fs)
    save_animation(os.path.join(args.outdir, f"displacement_{bc}.gif"), snaps, params)
    print("Done.")


if __name__ == "__main__":
    main()
