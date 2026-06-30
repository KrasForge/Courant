#!/usr/bin/env python3
"""
stability_study.py — CFL / Courant-number stability sweep.

Sweeps gamma^2 around the theoretical 2D CFL boundary (gamma^2 = 0.5),
runs a short undamped simulation for each value, and classifies each run
as stable or divergent.  Produces:

  model/outputs/cfl_sweep_envelope.png   log peak-amplitude vs. time
  model/outputs/cfl_classification.png   stable/divergent bar chart
  stdout                                 summary table + gamma2_max recommendation

Theory (README §1):
  The explicit 2D scheme is stable iff  gamma^2 <= 1/2.
  Crossing the boundary causes exponential divergence.

Usage:
  python model/stability_study.py
  python model/stability_study.py --no-plots
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdtd_ref import Mesh2D

# ---------------------------------------------------------------------------
# Sweep configuration
# ---------------------------------------------------------------------------
SWEEP_GAMMA2 = [
    0.10, 0.20, 0.30, 0.40,           # well inside stable region
    0.45, 0.48, 0.490, 0.499,          # approaching the boundary
    0.500,                              # theoretical CFL limit
    0.501, 0.510, 0.52, 0.55, 0.60, 0.70,  # unstable region
]
CFL_LIMIT = 0.5          # 1/2 — theoretical 2D stability boundary

NX = NY    = 24          # grid size; small for fast sweep
FS         = 48_000      # Hz
H          = 0.01        # m, spatial step
SIGMA      = 0.0         # undamped — cleanest divergence signal
DURATION   = 0.10        # s  (100 ms per run)
SAMPLE_MS  = 0.5         # amplitude sample interval (ms)
DIV_THRESH = 1e6         # classify divergent above this peak displacement


# ---------------------------------------------------------------------------
# Per-run simulation
# ---------------------------------------------------------------------------

def run_one(gamma2):
    """
    Run one undamped simulation with the given gamma^2.

    Returns
    -------
    times_ms  : 1-D float array  — sample times in ms
    envelope  : 1-D float array  — peak |u|_inf at each sample
    div_ms    : float or None    — time of divergence (ms), None if stable
    """
    c = float(np.sqrt(gamma2)) * H * FS
    mesh = Mesh2D(nx=NX, ny=NY, fs=FS, h=H, c=c, sigma=SIGMA,
                  boundary="fixed", check_cfl=False)
    mesh.strike(si=NY // 2, sj=NX // 2, radius=2.0, amp=1.0)

    n_total    = int(DURATION * FS)
    samp_every = max(1, int(SAMPLE_MS * 1e-3 * FS))

    times_ms = []
    envelope = []
    div_ms   = None

    for n in range(n_total):
        if n % samp_every == 0:
            peak = float(np.max(np.abs(mesh.u)))
            bad  = not np.isfinite(peak) or peak > DIV_THRESH
            times_ms.append(n / FS * 1e3)
            envelope.append(min(peak, DIV_THRESH * 10) if np.isfinite(peak) else DIV_THRESH * 10)
            if bad:
                div_ms = n / FS * 1e3
                break
        mesh.step()

    return np.array(times_ms), np.array(envelope), div_ms


# ---------------------------------------------------------------------------
# Plots
# ---------------------------------------------------------------------------

def save_envelope_plot(results, outdir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(11, 6))

    n_stable = sum(1 for *_, d in results if d is None)
    n_div    = len(results) - n_stable
    blues = plt.cm.Blues_r(np.linspace(0.2, 0.7, max(n_stable, 1)))
    reds  = plt.cm.Reds(   np.linspace(0.3, 0.8, max(n_div,    1)))
    bi, ri = 0, 0

    for g2, times, env, div_ms in results:
        label  = f"γ²={g2:.3f}"
        stable = div_ms is None
        color  = blues[bi] if stable else reds[ri]
        ls     = "-" if stable else "--"
        lw     = 1.2 if stable else 1.5
        ax.semilogy(times, np.maximum(env, 1e-6), color=color,
                    ls=ls, lw=lw, label=label)
        if stable:
            bi += 1
        else:
            ri += 1

    ax.axhline(DIV_THRESH, color="k", lw=0.8, ls=":",
               label=f"div. threshold (10⁶)")
    ax.set_xlabel("Time (ms)")
    ax.set_ylabel("Peak displacement  ‖u‖∞")
    ax.set_title(
        "CFL sweep — peak displacement envelope\n"
        "solid = stable, dashed = divergent"
    )
    ax.legend(ncol=2, fontsize=8, loc="upper left")
    ax.set_ylim(1e-5, DIV_THRESH * 50)
    fig.tight_layout()

    path = os.path.join(outdir, "cfl_sweep_envelope.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  wrote {path}")


def save_classification_plot(results, gamma2_max, outdir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch
    from matplotlib.lines import Line2D

    g2_vals = [r[0] for r in results]
    colors  = ["steelblue" if r[3] is None else "tomato" for r in results]
    labels  = [f"{g:.3f}" for g in g2_vals]

    fig, ax = plt.subplots(figsize=(12, 3.5))
    ax.bar(range(len(g2_vals)), [1] * len(g2_vals),
           color=colors, edgecolor="k", linewidth=0.5)

    # Mark the CFL boundary between last value < 0.5 and first >= 0.5
    cfl_idx = next((i for i, g in enumerate(g2_vals) if g >= CFL_LIMIT),
                   len(g2_vals))
    ax.axvline(cfl_idx - 0.5, color="k", lw=2, ls="--",
               label=f"CFL limit  γ²=0.5")

    # Mark recommended gamma2_max
    gmax_idx = next((i for i, g in enumerate(g2_vals) if g > gamma2_max),
                    len(g2_vals)) - 0.5
    ax.axvline(gmax_idx, color="darkgreen", lw=2, ls=":",
               label=f"γ²_max={gamma2_max:.3f} (recommended)")

    ax.set_xticks(range(len(g2_vals)))
    ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=9)
    ax.set_xlabel("gamma²")
    ax.set_yticks([])
    ax.set_title("CFL classification: stable (blue) / divergent (red)")
    ax.legend(handles=[
        Patch(color="steelblue", label="stable"),
        Patch(color="tomato",    label="divergent"),
        Line2D([0], [0], color="k",         ls="--", lw=2, label=f"CFL limit γ²=0.5"),
        Line2D([0], [0], color="darkgreen", ls=":",  lw=2, label=f"γ²_max={gamma2_max:.3f}"),
    ], loc="upper right", fontsize=9)
    fig.tight_layout()

    path = os.path.join(outdir, "cfl_classification.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  wrote {path}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--no-plots", action="store_true",
        help="Skip matplotlib output (useful in headless/CI environments)",
    )
    parser.add_argument(
        "--outdir",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "outputs"),
    )
    args = parser.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    print("2D FDTD CFL stability sweep")
    print(f"  Grid     : {NX}×{NY}   fs={FS} Hz   h={H} m   sigma={SIGMA}")
    print(f"  Duration : {DURATION*1e3:.0f} ms per run")
    print(f"  CFL limit: gamma^2 = {CFL_LIMIT}  (gamma = {CFL_LIMIT**0.5:.4f})")
    print()

    col = f"{'gamma²':>8}  {'gamma':>8}  {'status':>12}  {'peak@10ms':>12}  {'peak@end':>12}  div. time"
    print(col)
    print("─" * len(col))

    results = []
    for g2 in SWEEP_GAMMA2:
        gamma   = g2 ** 0.5
        times, env, div_ms = run_one(g2)

        idx10 = int(np.searchsorted(times, 10.0))
        p10   = env[min(idx10, len(env) - 1)] if len(env) else float("nan")
        pend  = env[-1]                        if len(env) else float("nan")
        status = "stable" if div_ms is None else "DIVERGENT"
        div_str = f"{div_ms:.1f} ms" if div_ms is not None else "—"

        print(f"{g2:>8.4f}  {gamma:>8.5f}  {status:>12}  "
              f"{p10:>12.3e}  {pend:>12.3e}  {div_str}")

        results.append((g2, times, env, div_ms))

    # Recommendation: largest stable gamma^2 known safe, backed off by 10 %
    stable_g2s = [r[0] for r in results if r[3] is None]
    empirical_max = max(stable_g2s) if stable_g2s else 0.0
    # Round down to 3 d.p. to keep a clean value for RTL coefficients
    gamma2_max = float(f"{empirical_max * 0.90:.3f}")

    print()
    print("─" * 60)
    print(f"Empirical stable maximum : gamma^2 = {empirical_max:.4f}")
    print(f"Recommended gamma2_max   : {gamma2_max:.3f}")
    print()
    print("Rationale:")
    print(f"  The scheme diverges exponentially for gamma^2 > 0.5 (CFL limit).")
    print(f"  The non-linear term (alpha*u^2, README §2) raises the effective")
    print(f"  local gamma^2 above gamma0^2 on loud transients.  A 10 % margin")
    print(f"  below the empirical limit gives gamma2_max = {gamma2_max:.3f}, leaving")
    print(f"  headroom of {CFL_LIMIT - gamma2_max:.3f} for the amplitude-dependent stiffening")
    print(f"  before the hard clamp engages.")
    print()

    if args.no_plots:
        return

    try:
        import matplotlib  # noqa: F401
    except ImportError:
        print("matplotlib not available — skipping plots (pip install matplotlib)")
        return

    print("Writing plots:")
    save_envelope_plot(results, args.outdir)
    save_classification_plot(results, gamma2_max, args.outdir)
    print("Done.")


if __name__ == "__main__":
    main()
