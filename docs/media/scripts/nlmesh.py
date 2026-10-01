"""NumPy port of model/NLMesh2D.m (the float reference model).

Line-for-line the same update as the Octave class, so the media scripts can
render animations and A/B examples quickly. check_against_octave() proves the
port matches the Octave model to float precision before anything is rendered.
"""
import numpy as np


class NLMesh2D:
    def __init__(self, nx, ny, fs, gamma2, alpha, gamma2_max, sigma, boundary='fixed'):
        k = 1.0 / fs
        self.nx, self.ny, self.boundary = nx, ny, boundary
        self.gamma2, self.alpha, self.gamma2_max = gamma2, alpha, gamma2_max
        self.a0 = 1.0 / (1.0 + sigma * k)
        self.sigk1 = 1.0 - sigma * k
        self.u = np.zeros((ny, nx))
        self.u1 = np.zeros((ny, nx))

    def strike(self, si, sj, radius=2.0, amp=1.0):
        jj, ii = np.meshgrid(np.arange(self.nx), np.arange(self.ny))
        self.u = self.u + amp * np.exp(-((ii - si) ** 2 + (jj - sj) ** 2) / (2.0 * radius ** 2))

    def step(self):
        U = self.u
        ny, nx = self.ny, self.nx
        UP = np.zeros((ny + 2, nx + 2))
        UP[1:ny + 1, 1:nx + 1] = U
        if self.boundary != 'fixed':
            UP[0, 1:nx + 1] = U[1, :]
            UP[ny + 1, 1:nx + 1] = U[ny - 2, :]
            UP[1:ny + 1, 0] = U[:, 1]
            UP[1:ny + 1, nx + 1] = U[:, nx - 2]
        lap = UP[2:, 1:-1] + UP[:-2, 1:-1] + UP[1:-1, 2:] + UP[1:-1, :-2] - 4.0 * UP[1:-1, 1:-1]
        g2l = np.clip(self.gamma2 + self.alpha * U ** 2, 0.0, self.gamma2_max)
        u_next = self.a0 * (2.0 * U - self.sigk1 * self.u1 + g2l * lap)
        u_next = np.clip(u_next, -1.0, 1.0 - 2.0 ** -23)
        self.u1 = U
        self.u = u_next


def check_against_octave(model_dir, steps=400):
    """Run the same strike in Octave's NLMesh2D and here; return max |diff|."""
    import os
    import subprocess
    import tempfile
    args = (32, 32, 48000, 0.05, 0.42, 0.451, 0.4, 'free')
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, 'u.txt')
        code = (f"m = NLMesh2D(32, 32, 48000, 0.05, 0.42, 0.451, 0.4, 'free');"
                f"m.strike(15.5, 15.5, 1.6, 1.0); for t = 1:{steps}; m.step(); end;"
                f"dlmwrite('{out}', m.u, 'precision', '%.17g');")
        subprocess.run(['octave-cli', '--no-gui', '--quiet', '--eval', code], cwd=model_dir, check=True)
        ref = np.loadtxt(out, delimiter=',')
    m = NLMesh2D(*args)
    m.strike(15.5, 15.5, 1.6, 1.0)
    for _ in range(steps):
        m.step()
    return float(np.max(np.abs(m.u - ref)))
