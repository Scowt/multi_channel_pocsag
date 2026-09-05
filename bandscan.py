#!/usr/bin/env python3
"""Parse rtl_power CSV and report the strongest carriers as a ranked list + ASCII spectrum."""
import argparse
import sys
from collections import defaultdict


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="rtl_power output CSV ('-' for stdin)")
    ap.add_argument("--top", type=int, default=20, help="how many peaks to list")
    ap.add_argument("--floor-margin", type=float, default=6.0,
                    help="dB above the median noise floor to count as a carrier")
    ap.add_argument("--width", type=int, default=64, help="ASCII spectrum width")
    args = ap.parse_args()

    fh = sys.stdin if args.csv == "-" else open(args.csv)
    # bin centre Hz -> list of dB readings across all sweeps
    bins: dict[int, list[float]] = defaultdict(list)
    for line in fh:
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 7:
            continue
        try:
            low, high, step = float(parts[2]), float(parts[3]), float(parts[4])
            vals = [float(v) for v in parts[6:] if v not in ("", "-nan", "nan")]
        except ValueError:
            continue
        for i, v in enumerate(vals):
            bins[int(low + i * step)].append(v)

    if not bins:
        print("No usable rows in rtl_power output.", file=sys.stderr)
        return 1

    # Peak-hold: the max across sweeps catches bursty paging traffic that an average would bury.
    peak = {hz: max(v) for hz, v in bins.items()}
    freqs = sorted(peak)
    vals = sorted(peak.values())
    floor = vals[len(vals) // 2]
    thresh = floor + args.floor_margin

    lo, hi = min(vals), max(vals)
    span = max(hi - lo, 1e-9)
    print(f"# bins={len(freqs)}  noise floor={floor:.1f} dB  threshold={thresh:.1f} dB\n")

    # Group contiguous over-threshold bins into carriers.
    carriers, run = [], []
    for hz in freqs:
        if peak[hz] >= thresh:
            run.append(hz)
        elif run:
            carriers.append(run)
            run = []
    if run:
        carriers.append(run)

    ranked = []
    for run in carriers:
        best = max(run, key=lambda h: peak[h])
        ranked.append((peak[best], best, (run[-1] - run[0]) / 1000.0))
    ranked.sort(reverse=True)

    print(f"{'FREQ (MHz)':>12} {'PEAK dB':>9} {'WIDTH kHz':>10}")
    print(f"{'-'*12} {'-'*9} {'-'*10}")
    for db, hz, wk in ranked[: args.top]:
        print(f"{hz/1e6:12.4f} {db:9.1f} {wk:10.1f}")
    if not ranked:
        print("  (nothing above threshold - try --floor-margin 3, more gain, or a longer scan)")

    print(f"\n# spectrum, peak-hold, '#' = above threshold")
    step = max(1, len(freqs) // 110)
    for i in range(0, len(freqs), step):
        chunk = freqs[i:i + step]
        hz = chunk[0]
        db = max(peak[h] for h in chunk)
        n = int((db - lo) / span * args.width)
        ch = "#" if db >= thresh else "."
        print(f"{hz/1e6:9.4f} {db:7.1f} |{ch * n}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
