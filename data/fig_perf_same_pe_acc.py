#!/usr/bin/env python3
"""Plot normalized GEMM performance for static and dynamic experiments.

The experiment files are named
``L{lane}_W{width}_..._ACC{acc}_MxNxK_Cnt*.txt`` and contain a
``throughput=... (GEMM cmd per KCycle)`` line.  Since one cycle sustains
4096 FMAC, the peak-normalized performance is

    throughput * M * N * K / (4096 * 1000).
"""

from pathlib import Path
import os
# Keep matplotlib's font/cache files out of read-only home directories.
os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib")
import re
import matplotlib.pyplot as plt
from matplotlib.ticker import PercentFormatter

LANES = (1, 4, 16)
WIDTHS = {1: 64, 4: 32, 16: 16}
LINESTYLE = {"static": "-", "dynamic": "--"}
MARKER = {1: "o", 4: "s", 16: "^"}


def _number_list(token: str):
    """Return numeric components from tokens such as ``96_128``."""
    return [int(x) for x in re.findall(r"\d+", token)]


def read_experiments(root: Path, group: str, lab: str, lane: int):
    """Read the best (largest ACC, then AB) file for each workload point."""
    width = WIDTHS[lane]
    directory = root / group / lab
    candidates = {}
    # Keep the flexible AB/ACC fields used by dynamic experiments.
    rx = re.compile(
        rf"^L{lane}_W{width}_AB(?P<ab>[0-9_]+)_ACC(?P<acc>[0-9_]+)_"
        rf"(?P<dims>\d+X\d+X\d+)_Cnt\d+\.txt$"
    )
    if not directory.is_dir():
        return {}
    for path in directory.glob("*.txt"):
        m = rx.match(path.name)
        if not m:
            continue
        acc = _number_list(m.group("acc"))
        ab = _number_list(m.group("ab"))
        # Prefer the largest accumulator/cache variant when several exist.
        score = (max(acc, default=0), sum(acc), max(ab, default=0), sum(ab))
        dims = tuple(int(v) for v in m.group("dims").split("X"))
        old = candidates.get(dims)
        if old is None or score > old[0]:
            candidates[dims] = (score, path)

    result = {}
    for dims, (_, path) in candidates.items():
        text = path.read_text(errors="replace")
        tm = re.search(r"throughput\s*=\s*([0-9.eE+-]+)", text)
        if not tm:
            continue
        throughput = float(tm.group(1))
        # throughput is commands per 1000 cycles (KCycle).
        result[dims] = throughput * dims[0] * dims[1] * dims[2] / (4096.0 * 1000.0)
    return result


def make_plot(root: Path, lab: str, output: str):
    fig, ax = plt.subplots(figsize=(3.35, 2.45))  # IEEE single-column width
    for y in (0.2, 0.4, 0.6, 0.8, 1.0):
        ax.axhline(y, color="0.78", lw=0.55, zorder=0)

    # Workload dimension varied by each sweep; the other two are fixed at 1024.
    varying = {"labM": 0, "labN": 1, "labK": 2}[lab]
    all_x = set()
    for group in ("static", "dynamic"):
        for lane in LANES:
            points = read_experiments(root, group, lab, lane)
            xy = sorted((dims[varying], value) for dims, value in points.items())
            if not xy:
                continue
            x, y = zip(*xy)
            all_x.update(x)
            short_group = "S" if group == "static" else "D"
            ax.plot(x, y, color="black", lw=1.0, linestyle=LINESTYLE[group],
                    marker=MARKER[lane], markersize=3.2, markerfacecolor="white",
                    markeredgewidth=0.8, label=f"{short_group}, L{lane}W{WIDTHS[lane]}")

    ax.set_xscale("log", base=2)
    ax.set_ylim(0, 1.05)
    ax.yaxis.set_major_formatter(PercentFormatter(1.0, decimals=0))
    ax.set_xlabel({"labM": "M", "labN": "N", "labK": "K"}[lab])
    ax.set_ylabel("GEMM Utilization")
    if all_x:
        ax.set_xticks(sorted(all_x))
    ax.get_xaxis().set_major_formatter(plt.ScalarFormatter())
    ax.grid(False)
    ax.legend(loc="upper left", frameon=False, ncol=1)
    fig.tight_layout(pad=0.4)
    fig.savefig(output, format="pdf", bbox_inches="tight")
    plt.close(fig)


def main():
    root = Path(__file__).resolve().parent
    plt.rcParams.update({"font.family": "Times New Roman", "font.size": 8,
                         "axes.labelsize": 8, "axes.titlesize": 8,
                         "xtick.labelsize": 8, "ytick.labelsize": 8,
                         "legend.fontsize": 8,
                         "pdf.fonttype": 42})
    for lab, suffix in (("labM", "m"), ("labN", "n"), ("labK", "k")):
        make_plot(root, lab, root / f"perf_same_pe_acc_{suffix}.pdf")


if __name__ == "__main__":
    main()
