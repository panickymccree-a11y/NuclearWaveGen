#!/usr/bin/env python3
"""
Poisson distribution verification for nuc_event_gen_10mcps simulation.

Reads event_log.csv from the testbench and produces:
  - Console report (mean, variance, Fano factor, χ² tests per lane)
  - A single summary figure (verify_poisson.png) with:
      [a] Poisson PMF histogram  — observed vs theoretical
      [b] Inter-arrival time     — observed vs geometric
      [c] PMF residuals          — (obs - theory) / theory
      [d] Summary statistics     — all metrics + pass/fail verdicts

Usage:
    python verify_poisson.py [event_log.csv]
"""

import sys
import os
import numpy as np
from collections import Counter
from math import exp, factorial
import csv

# ── Optional imports ────────────────────────────────────────────────
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.ticker import MaxNLocator
    HAS_MPL = True
except ImportError:
    HAS_MPL = False

try:
    from scipy import stats as scipy_stats
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False


# ══════════════════════════════════════════════════════════════════════
#  Data loading
# ══════════════════════════════════════════════════════════════════════

def load_event_log(path):
    """Load event_log.csv → (cycles, lane0_counts, lane1_counts)."""
    cycles, lane0, lane1 = [], [], []
    with open(path, "r") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if header is None:
            raise ValueError("Empty log file")
        for row in reader:
            if len(row) < 3:
                continue
            cycles.append(int(row[0]))
            lane0.append(int(row[1]))
            lane1.append(int(row[2]))
    return np.array(cycles), np.array(lane0, dtype=int), np.array(lane1, dtype=int)


# ══════════════════════════════════════════════════════════════════════
#  Statistics helpers
# ══════════════════════════════════════════════════════════════════════

def compute_stats(counts):
    """Return dict of statistics for a 1-D event-count array."""
    n = len(counts)
    total_events = int(np.sum(counts))
    mean_val = float(np.mean(counts))
    var_val = float(np.var(counts, ddof=0))
    fano = var_val / mean_val if mean_val > 0 else float("inf")
    fano_se = np.sqrt(2.0 / (n - 1)) if n > 1 else float("inf")
    fano_ok = abs(fano - 1.0) <= 2.0 * fano_se

    return {
        "n": n,
        "total_events": total_events,
        "mean": mean_val,
        "var": var_val,
        "fano": fano,
        "fano_se": fano_se,
        "fano_ok": fano_ok,
    }


def chi2_poisson(counts, mean_val):
    """χ² goodness-of-fit vs Poisson(mean_val). Returns (chi2, p, dof)."""
    if not HAS_SCIPY:
        return None, None, None

    counter = Counter(counts)
    n = len(counts)
    max_k = max(counter.keys())

    obs_list, exp_list = [], []
    accum_obs, accum_exp = 0, 0.0
    k = max_k
    while k >= 0:
        obs_k = counter.get(k, 0)
        exp_k = n * mean_val**k * exp(-mean_val) / factorial(k)
        accum_obs += obs_k
        accum_exp += exp_k
        if accum_exp >= 5.0 or k == 0:
            obs_list.insert(0, accum_obs)
            exp_list.insert(0, accum_exp)
            accum_obs, accum_exp = 0, 0.0
        k -= 1

    obs_arr = np.array(obs_list, dtype=float)
    exp_arr = np.array(exp_list, dtype=float)
    exp_arr = exp_arr * obs_arr.sum() / exp_arr.sum()
    dof = max(len(obs_arr) - 2, 1)
    chi2, p = scipy_stats.chisquare(f_obs=obs_arr, f_exp=exp_arr, ddof=1)
    return chi2, p, dof


def inter_arrival_stats(counts):
    """Compute inter-arrival statistics. Returns dict or None."""
    idx = np.where(counts > 0)[0]
    if len(idx) < 2:
        return None

    ia = np.diff(idx)
    n_ia = len(ia)
    mean_ia = float(np.mean(ia))
    var_ia = float(np.var(ia, ddof=0))

    # For Bernoulli Poisson, T ~ Geometric(p = λ)
    p_est = 1.0 / mean_ia if mean_ia > 0 else 0
    exp_var = (1.0 - p_est) / (p_est * p_est) if p_est > 0 else float("inf")

    ks_stat, ks_p = None, None
    if HAS_SCIPY:
        ks_stat, ks_p = scipy_stats.kstest(ia, "expon", args=(0, mean_ia))

    # χ² geometric
    geo_chi2, geo_p = None, None
    if HAS_SCIPY and p_est > 0:
        counter = Counter(ia)
        max_t = max(counter.keys())
        obs_list, exp_list = [], []
        accum_obs, accum_exp = 0, 0.0
        t = max_t
        while t >= 1:
            obs_t = counter.get(t, 0)
            exp_t = n_ia * (1 - p_est) ** (t - 1) * p_est
            accum_obs += obs_t
            accum_exp += exp_t
            if accum_exp >= 5.0 or t == 1:
                obs_list.insert(0, accum_obs)
                exp_list.insert(0, accum_exp)
                accum_obs, accum_exp = 0, 0.0
            t -= 1
        o_arr = np.array(obs_list, dtype=float)
        e_arr = np.array(exp_list, dtype=float)
        e_arr = e_arr * o_arr.sum() / e_arr.sum()
        dof = max(len(o_arr) - 2, 1)
        geo_chi2, geo_p = scipy_stats.chisquare(f_obs=o_arr, f_exp=e_arr, ddof=1)

    return {
        "ia": ia,
        "n": n_ia,
        "mean": mean_ia,
        "var": var_ia,
        "exp_var": exp_var,
        "p_est": p_est,
        "min": int(np.min(ia)),
        "max": int(np.max(ia)),
        "ks_stat": ks_stat,
        "ks_p": ks_p,
        "geo_chi2": geo_chi2,
        "geo_p": geo_p,
    }


# ══════════════════════════════════════════════════════════════════════
#  Console report
# ══════════════════════════════════════════════════════════════════════

def print_report(label, st, ia):
    """Print statistics for one dataset."""
    print(f"\n{'='*60}")
    print(f"  {label}")
    print(f"{'='*60}")
    print(f"  Samples               : {st['n']:,}")
    print(f"  Total events          : {st['total_events']:,}")
    print(f"  Mean (λ_est)          : {st['mean']:.6f}")
    print(f"  Variance              : {st['var']:.6f}")
    print(f"  Fano factor           : {st['fano']:.4f}  (Poisson ideal = 1.0)")
    print(f"  Fano SE               : ±{st['fano_se']:.4f}")
    ci_lo = st['fano'] - 2*st['fano_se']
    ci_hi = st['fano'] + 2*st['fano_se']
    print(f"  Fano 95% CI           : [{ci_lo:.4f}, {ci_hi:.4f}]")
    verdict = "✓ PASS" if st['fano_ok'] else "✗ FAIL"
    print(f"  Fano ≈ 1 ?            : {verdict}")

    # χ² Poisson
    if st.get('chi2') is not None:
        print(f"\n  χ² Poisson GOF:")
        print(f"    χ²                   : {st['chi2']:.4f}")
        print(f"    dof                  : {st['chi2_dof']}")
        print(f"    p-value              : {st['chi2_p']:.6f}")
        verdict2 = "✓ PASS" if st['chi2_p'] > 0.05 else "✗ FAIL"
        print(f"    Result               : {verdict2}")

    # Inter-arrival
    if ia is not None:
        print(f"\n  Inter-Arrival Analysis:")
        print(f"    Pairs                : {ia['n']:,}")
        print(f"    Mean interval        : {ia['mean']:.2f} samples  (1/λ ≈ {1/st['mean']:.1f})")
        print(f"    Variance             : {ia['var']:.1f}  (Geom exp: {ia['exp_var']:.1f})")
        if ia['ks_p'] is not None:
            v3 = "✓ PASS" if ia['ks_p'] > 0.05 else "✗ FAIL"
            print(f"    KS test p-value      : {ia['ks_p']:.6f}  {v3}")
        if ia['geo_p'] is not None:
            v4 = "✓ PASS" if ia['geo_p'] > 0.05 else "✗ FAIL"
            print(f"    χ² Geometric p-value : {ia['geo_p']:.6f}  {v4}")


# ══════════════════════════════════════════════════════════════════════
#  Summary figure
# ══════════════════════════════════════════════════════════════════════

def make_figure(stats_lane0, stats_lane1, stats_comb, ia_lane0, ia_lane1, ia_comb,
                counts_lane0, counts_lane1, counts_comb, out_path):
    """Render the 4-panel summary figure."""
    if not HAS_MPL:
        print("\n[matplotlib not available — skipping figure]")
        return

    st = stats_comb   # primary dataset for the figure
    ia = ia_comb
    counts = counts_comb
    mean_val = st["mean"]

    # ── figure setup ────────────────────────────────────────────────
    fig = plt.figure(figsize=(18, 11))
    gs = fig.add_gridspec(2, 3, height_ratios=[1, 1], width_ratios=[1, 1, 0.7],
                          hspace=0.38, wspace=0.35)

    ax_pmf    = fig.add_subplot(gs[0, 0])   # (a) Poisson PMF
    ax_ia     = fig.add_subplot(gs[0, 1])   # (b) Inter-arrival
    ax_res    = fig.add_subplot(gs[1, 0])   # (c) Residuals
    ax_text   = fig.add_subplot(gs[1, 1])   # (d) Summary text
    ax_verdict = fig.add_subplot(gs[:, 2])  # Verdict panel

    # ── (a) Poisson PMF histogram ───────────────────────────────────
    counter = Counter(counts)
    max_k = max(counter.keys())
    k_display = min(max_k, 5)  # show k=0..5 (P(k>=6) is tiny for λ=0.02)
    ks_full = np.arange(0, max_k + 1)
    obs_pmf = np.array([counter.get(k, 0) for k in ks_full], dtype=float)
    obs_pmf /= obs_pmf.sum()
    theory = np.array([mean_val**k * exp(-mean_val) / factorial(k) for k in ks_full])

    width = 0.35
    ax_pmf.bar(ks_full - width/2, obs_pmf, width, color="#2166ac", alpha=0.85,
               label="Observed")
    ax_pmf.bar(ks_full + width/2, theory, width, color="#b2182b", alpha=0.75,
               label=f"Poisson(λ={mean_val:.4f})")
    ax_pmf.set_xlabel("Events per sample  k")
    ax_pmf.set_ylabel("Probability")
    ax_pmf.set_title("(a) Event-count distribution", fontweight="bold")
    ax_pmf.legend(fontsize=9, loc="upper right")
    ax_pmf.set_xlim(-0.6, k_display + 0.6)
    ax_pmf.xaxis.set_major_locator(MaxNLocator(integer=True))
    ax_pmf.grid(axis="y", alpha=0.25)

    # inset: log-scale full range
    axin = ax_pmf.inset_axes([0.52, 0.42, 0.44, 0.44])
    axin.semilogy(ks_full, obs_pmf, ".-", color="#2166ac", ms=3)
    axin.semilogy(ks_full, theory, ".-", color="#b2182b", ms=3)
    axin.set_title("log scale", fontsize=8)
    axin.grid(True, alpha=0.2)
    axin.tick_params(labelsize=7)

    # ── (b) Inter-arrival time ──────────────────────────────────────
    if ia is not None:
        ia_arr = ia["ia"]
        p_est = ia["p_est"]
        trun = min(int(ia["mean"] * 8), ia["max"])
        # histogram
        bins = np.arange(1, trun + 2, max(1, trun // 60))
        ax_ia.hist(ia_arr[ia_arr <= trun], bins=bins, density=True,
                   color="#2166ac", alpha=0.75, edgecolor="white", linewidth=0.3,
                   label=f"Observed (n={ia['n']:,})")
        # geometric overlay
        t_vals = np.arange(1, trun + 1)
        geo_pmf = (1 - p_est) ** (t_vals - 1) * p_est
        ax_ia.plot(t_vals, geo_pmf, "-", color="#b2182b", lw=2.2,
                   label=f"Geometric(p={p_est:.5f})")
        ax_ia.set_xlabel("Inter-arrival time  (samples)")
        ax_ia.set_ylabel("Probability density")
        ax_ia.set_title("(b) Inter-arrival distribution", fontweight="bold")
        ax_ia.legend(fontsize=9, loc="upper right")
        ax_ia.grid(axis="y", alpha=0.25)
    else:
        ax_ia.text(0.5, 0.5, "Insufficient events", ha="center", va="center",
                   transform=ax_ia.transAxes, fontsize=14, color="grey")
        ax_ia.set_title("(b) Inter-arrival distribution", fontweight="bold")

    # ── (c) PMF residuals ──────────────────────────────────────────
    residuals = (obs_pmf - theory) / (theory + 1e-12)
    colors = ["#2166ac" if abs(r) < 3 else "#b2182b" for r in residuals[:k_display+1]]
    ax_res.bar(ks_full[:k_display+1], residuals[:k_display+1], color=colors, alpha=0.8,
               edgecolor="white", linewidth=0.3)
    ax_res.axhline(y=0, color="black", linewidth=0.8)
    ax_res.axhline(y=2, color="grey", linestyle="--", linewidth=0.6, alpha=0.6)
    ax_res.axhline(y=-2, color="grey", linestyle="--", linewidth=0.6, alpha=0.6)
    ax_res.set_xlabel("Events per sample  k")
    ax_res.set_ylabel("(obs−theory) / theory")
    ax_res.set_title("(c) Standardised residuals", fontweight="bold")
    ax_res.set_xlim(-0.6, k_display + 0.6)
    ax_res.xaxis.set_major_locator(MaxNLocator(integer=True))
    ax_res.grid(axis="y", alpha=0.25)

    # ── (d) Summary text ────────────────────────────────────────────
    ax_text.axis("off")

    # Build pass/fail for each check
    def pf(ok):
        return "✓" if ok else "✗"

    lines = []
    lines.append("─" * 44)
    lines.append("  Combined lanes  (interleaved, 500 MS/s eq.)")
    lines.append("─" * 44)
    lines.append(f"  Samples           : {st['n']:,}")
    lines.append(f"  Total events      : {st['total_events']:,}")
    lines.append(f"  λ (expected)      : 0.020000  (10 Mcps)")
    lines.append(f"  λ (observed)      : {st['mean']:.6f}")
    lines.append(f"  Variance          : {st['var']:.6f}")
    lines.append(f"  Fano factor       : {st['fano']:.4f}   {pf(st['fano_ok'])} Fano≈1")
    lines.append("")
    lines.append("─" * 44)
    lines.append("  Per-lane statistics")
    lines.append("─" * 44)
    lines.append(f"  Lane 0  λ={stats_lane0['mean']:.6f}  Fano={stats_lane0['fano']:.4f}  {pf(stats_lane0['fano_ok'])}")
    lines.append(f"  Lane 1  λ={stats_lane1['mean']:.6f}  Fano={stats_lane1['fano']:.4f}  {pf(stats_lane1['fano_ok'])}")
    lines.append("")
    lines.append("─" * 44)
    lines.append("  χ² goodness-of-fit")
    lines.append("─" * 44)
    if st.get("chi2") is not None:
        lines.append(f"  χ² Poisson    p = {st['chi2_p']:.4f}   {pf(st['chi2_p']>0.05)}")
    if ia is not None:
        if ia.get("ks_p") is not None:
            lines.append(f"  KS exp.       p = {ia['ks_p']:.4f}   {pf(ia['ks_p']>0.05)}")
        if ia.get("geo_p") is not None:
            lines.append(f"  χ² geometric  p = {ia['geo_p']:.4f}   {pf(ia['geo_p']>0.05)}")
    if st.get("chi2") is None:
        lines.append("  (scipy not available)")
    lines.append("")
    lines.append("─" * 44)
    lines.append("  τ decay (current) : 2⁴ = 16 samples")
    lines.append(f"  Simulation         : {st['n']*2e-9:.3f} s real-time eq.")

    text_str = "\n".join(lines)
    ax_text.text(0.02, 0.98, text_str, transform=ax_text.transAxes,
                 fontfamily="monospace", fontsize=8.5, verticalalignment="top",
                 bbox=dict(boxstyle="round,pad=0.4", facecolor="whitesmoke",
                           edgecolor="#cccccc", alpha=0.9))

    # ── Verdict panel ───────────────────────────────────────────────
    ax_verdict.axis("off")

    # Aggregate verdict
    checks = [st["fano_ok"]]
    if st.get("chi2_p") is not None:
        checks.append(st["chi2_p"] > 0.05)
    if ia is not None and ia.get("ks_p") is not None:
        checks.append(ia["ks_p"] > 0.05)
    if ia is not None and ia.get("geo_p") is not None:
        checks.append(ia["geo_p"] > 0.05)

    all_pass = all(checks)
    n_pass = sum(checks)
    n_total = len(checks)

    if all_pass:
        verdict_text = "PASS"
        verdict_sub = f"All {n_total}/{n_total} checks"
        v_color = "#1b7837"
        v_bg = "#e8f5e9"
    elif n_pass >= n_total * 0.75:
        verdict_text = "PASS\n(with note)"
        verdict_sub = f"{n_pass}/{n_total} checks"
        v_color = "#e69500"
        v_bg = "#fff8e1"
    else:
        verdict_text = "FAIL"
        verdict_sub = f"{n_pass}/{n_total} checks"
        v_color = "#b71c1c"
        v_bg = "#ffebee"

    ax_verdict.text(0.5, 0.72, verdict_text, transform=ax_verdict.transAxes,
                    fontsize=52, fontweight="bold", color=v_color,
                    ha="center", va="center")
    ax_verdict.text(0.5, 0.52, verdict_sub, transform=ax_verdict.transAxes,
                    fontsize=13, color="#555555", ha="center", va="center")

    # Check detail
    detail_lines = []
    detail_lines.append(f"{'✓' if st['fano_ok'] else '✗'}  Fano factor ≈ 1")
    if st.get("chi2_p") is not None:
        detail_lines.append(f"{'✓' if st['chi2_p']>0.05 else '✗'}  χ² Poisson GOF")
    if ia is not None and ia.get("ks_p") is not None:
        detail_lines.append(f"{'✓' if ia['ks_p']>0.05 else '✗'}  KS inter-arrival")
    if ia is not None and ia.get("geo_p") is not None:
        detail_lines.append(f"{'✓' if ia['geo_p']>0.05 else '✗'}  χ² geometric")

    ax_verdict.text(0.5, 0.30, "\n".join(detail_lines), transform=ax_verdict.transAxes,
                    fontsize=10, fontfamily="monospace", ha="center", va="top",
                    color="#333333")

    # Decorative circle behind verdict
    circle = plt.Circle((0.5, 0.72), 0.22, transform=ax_verdict.transAxes,
                        facecolor=v_bg, edgecolor=v_color, linewidth=3, zorder=-1)
    ax_verdict.add_patch(circle)

    # ── Suptitle ────────────────────────────────────────────────────
    status_icon = "✓" if all_pass else ("⚠" if n_pass >= n_total*0.75 else "✗")
    fig.suptitle(f"{status_icon}  Poisson Process Verification  —  "
                 f"nuc_event_gen_10mcps  (λ = {st['mean']:.4f} @ 500 MS/s)",
                 fontsize=14, fontweight="bold", y=0.985)

    # ── Save ────────────────────────────────────────────────────────
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fig.savefig(out_path, dpi=180, bbox_inches="tight",
                facecolor="white", edgecolor="none")
    plt.close(fig)
    print(f"\n  Summary figure saved →  {out_path}")


# ══════════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════════

def main():
    # ── input path ──────────────────────────────────────────────────
    if len(sys.argv) > 1:
        log_path = sys.argv[1]
    else:
        # try common locations
        candidates = [
            os.path.join(os.path.dirname(__file__), "event_log.csv"),
            "event_log.csv",
            os.path.join(os.path.dirname(__file__), "sim_out", "event_log.csv"),
        ]
        log_path = None
        for c in candidates:
            if os.path.exists(c):
                log_path = c
                break
        if log_path is None:
            print("ERROR: event_log.csv not found.  Pass path as argument.")
            print(f"  Looked in: {candidates}")
            sys.exit(1)

    if not os.path.exists(log_path):
        print(f"ERROR: Log file not found: {log_path}")
        sys.exit(1)

    out_dir = os.path.join(os.path.dirname(os.path.abspath(log_path)), "analysis")
    os.makedirs(out_dir, exist_ok=True)
    fig_path = os.path.join(out_dir, "verify_poisson.png")

    # ── load data ───────────────────────────────────────────────────
    print(f"Loading: {log_path}")
    cycles, lane0, lane1 = load_event_log(log_path)

    # interleaved combined stream
    all_counts = np.empty(len(lane0) + len(lane1), dtype=int)
    all_counts[0::2] = lane0
    all_counts[1::2] = lane1

    print(f"\nClock cycles : {len(cycles):,}")
    print(f"Sample rate  : 500 MS/s eq. (2 lanes × 250 MHz)")
    print(f"Total samples: {len(all_counts):,}")
    print(f"Duration     : {len(all_counts)*2e-6:.2f} ms  (real-time equivalent)")

    # ── compute statistics ──────────────────────────────────────────
    st0 = compute_stats(lane0)
    st1 = compute_stats(lane1)
    stA = compute_stats(all_counts)

    # add χ²
    st0["chi2"], st0["chi2_p"], st0["chi2_dof"] = chi2_poisson(lane0, st0["mean"])
    st1["chi2"], st1["chi2_p"], st1["chi2_dof"] = chi2_poisson(lane1, st1["mean"])
    stA["chi2"], stA["chi2_p"], stA["chi2_dof"] = chi2_poisson(all_counts, stA["mean"])

    # inter-arrival
    ia0 = inter_arrival_stats(lane0)
    ia1 = inter_arrival_stats(lane1)
    iaA = inter_arrival_stats(all_counts)

    # ── console report ──────────────────────────────────────────────
    print_report("Lane 0", st0, ia0)
    print_report("Lane 1", st1, ia1)
    print_report("Combined (interleaved)", stA, iaA)

    # ── summary figure ──────────────────────────────────────────────
    make_figure(st0, st1, stA, ia0, ia1, iaA, lane0, lane1, all_counts, fig_path)

    # ── final summary ───────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"  OVERALL VERDICT")
    print(f"{'='*60}")
    print(f"  Expected λ  = 0.020000  (10 Mcps @ 500 MS/s)")
    print(f"  Observed λ  = {stA['mean']:.6f}")
    print(f"  Fano factor = {stA['fano']:.4f}  (Poisson: 1.0)")
    print(f"  rate_threshold_q32 = 0x051E_B852")
    print(f"\n  Figure → {fig_path}")

    if not HAS_MPL:
        print("  [install matplotlib for the figure]")
    if not HAS_SCIPY:
        print("  [install scipy for χ² / KS tests]")
    print()


if __name__ == "__main__":
    main()
