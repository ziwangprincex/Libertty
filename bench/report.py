#!/usr/bin/env python3
"""Summarize bench/results/*.dat (vtebench --dat) as Markdown tables.

vtebench reports the milliseconds to write one sample (>= 1 MiB of the
benchmark's escape-sequence stream) into the terminal. The streams are
generated from the terminal's grid size, so when terminals ran at different
sizes only throughput is comparable: results/<terminal>.bytes (from
payload-sizes.sh) gives the sample size per benchmark at that terminal's grid,
and the main table is MB/s (higher is better).
"""
import pathlib
import statistics
import sys

results = pathlib.Path(__file__).resolve().parent / "results"
order = ["libertty", "kitty", "ghostty", "otty", "tern", "alacritty"]


def load(path):
    lines = path.read_text().splitlines()
    names = lines[0].split()
    columns = {n: [] for n in names}
    for line in lines[1:]:
        for name, value in zip(names, line.split()):
            if value != "_":
                columns[name].append(int(value))
    return columns


def load_bytes(term):
    path = results / f"{term}.bytes"
    if not path.exists():
        return {}
    return {name: int(n) for name, n in (line.split() for line in path.read_text().splitlines() if line.strip())}


terms = sorted((p.stem for p in results.glob("*.dat")),
               key=lambda t: order.index(t) if t in order else len(order))
if not terms:
    sys.exit("no results in " + str(results))

data = {t: load(results / f"{t}.dat") for t in terms}
payload = {t: load_bytes(t) for t in terms}
sizes = {}
for t in terms:
    size = results / f"{t}.size"
    rows_cols = size.read_text().split() if size.exists() else []
    sizes[t] = f"{rows_cols[1]}×{rows_cols[0]}" if len(rows_cols) == 2 else "?"

benches = sorted({b for cols in data.values() for b in cols})


def throughput(term, bench):
    """MB/s from the median sample, or None without a size or a nonzero time."""
    samples = data[term].get(bench)
    nbytes = payload[term].get(bench)
    if not samples or not nbytes:
        return None
    ms = statistics.median(samples)
    return nbytes / 1e6 / (ms / 1000) if ms > 0 else None


def table(title, value, better, fmt):
    print(f"### {title}")
    print()
    print("| benchmark | " + " | ".join(terms) + " |")
    print("|---|" + "---:|" * len(terms))
    print("| grid (cols×rows) | " + " | ".join(sizes[t] for t in terms) + " |")
    for bench in benches:
        values = {t: value(t, bench) for t in terms}
        known = [v for v in values.values() if v is not None]
        best = better(known) if known else None
        cells = []
        for t in terms:
            v = values[t]
            if v is None:
                cells.append("—")
            else:
                cells.append(f"**{fmt(v)}**" if v == best else fmt(v))
        print(f"| {bench} | " + " | ".join(cells) + " |")
    print()


if all(payload.values()):
    table("Throughput, MB/s (median sample; higher is better)", throughput, max, lambda v: f"{v:.0f}")
    print("Geometric mean of throughput relative to the best per benchmark (1.00 = best everywhere):")
    for t in terms:
        ratios = []
        for bench in benches:
            values = [throughput(u, bench) for u in terms]
            mine = throughput(t, bench)
            known = [v for v in values if v]
            if mine and known:
                ratios.append(mine / max(known))
        if ratios:
            print(f"- {t}: {statistics.geometric_mean(ratios):.2f} over {len(ratios)} benchmarks")
    print()

table("Median ms per sample (lower is better; only comparable at equal grid sizes)",
      lambda t, b: statistics.median(data[t][b]) if data[t].get(b) else None, min, lambda v: f"{v:g}")
