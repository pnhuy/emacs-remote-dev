#!/usr/bin/env python3
"""Compare two benchmark CSVs and flag regressions (T107, SC-013).

    bench/compare.py BASELINE.csv NEW.csv [--threshold 0.20] [--min-abs-ms 1.0]
    bench/compare.py --vs-tramp RESULT.csv        # rdev/tramp ratios per op and profile

A row regresses when its median (or p95) grew by more than THRESHOLD relative
and by more than MIN-ABS-MS absolute (sub-millisecond jitter is not a
regression), or when failures increased.  Exit status 1 if any regression.
"""
import argparse, csv, statistics, sys
from collections import defaultdict


def load(path):
    rows = defaultdict(list)
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if int(r["n"] or 0) == 0:
                continue
            rows[(r["backend"], r["profile"], r["op"])].append(r)
    out = {}
    for k, rs in rows.items():
        out[k] = {
            "median": statistics.median(float(r["median_ms"]) for r in rs),
            "p95": statistics.median(float(r["p95_ms"]) for r in rs),
            "failures": sum(int(r["failures"]) for r in rs),
        }
    return out


def regress(base, new, thr, floor):
    bad = []
    for k in sorted(set(base) & set(new)):
        b, n = base[k], new[k]
        for m in ("median", "p95"):
            if n[m] - b[m] > floor and n[m] > b[m] * (1 + thr):
                bad.append((k, m, b[m], n[m]))
        if n["failures"] > b["failures"]:
            bad.append((k, "failures", b["failures"], n["failures"]))
    return bad


def vs_tramp(path):
    d = load(path)
    print(f"{'profile':<10} {'op':<14} {'rdev ms':>9} {'tramp ms':>9} {'ratio':>7}")
    for (be, pr, op), v in sorted(d.items(), key=lambda kv: (kv[0][1], kv[0][2])):
        if be != "rdev":
            continue
        t = d.get(("tramp", pr, op))
        if t and t["median"] > 0:
            print(f"{pr:<10} {op:<14} {v['median']:9.1f} {t['median']:9.1f} {v['median']/t['median']:7.2f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--threshold", type=float, default=0.20)
    ap.add_argument("--min-abs-ms", type=float, default=1.0)
    ap.add_argument("--vs-tramp", action="store_true")
    a = ap.parse_args()
    if a.vs_tramp:
        vs_tramp(a.files[0])
        return 0
    if len(a.files) != 2:
        ap.error("need BASELINE.csv NEW.csv")
    base, new = load(a.files[0]), load(a.files[1])
    bad = regress(base, new, a.threshold, a.min_abs_ms)
    compared = len(set(base) & set(new))
    for (be, pr, op), m, b, n in bad:
        print(f"REGRESSION {be}/{pr}/{op} {m}: {b:.2f} -> {n:.2f}")
    print(f"compared {compared} series, {len(bad)} regression(s) (> {a.threshold:.0%}, > {a.min_abs_ms} ms)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
