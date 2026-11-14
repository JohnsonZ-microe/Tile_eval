#!/usr/bin/env python3
"""vcd_trim.py - extract a cycle window from a (possibly huge) VCD file.

Keeps the full header (all $var definitions) plus every value change whose
timestamp falls inside [from_cycle, to_cycle], so the result is a small,
loadable VCD that replays just the window of interest.

Cycle math defaults match tb_tile_v4 (clk toggles every 5 ns -> first
posedge at 5 ns, period 10 ns); override with --period-ns/--first-edge-ns.

Usage:
  python3 vcd_trim.py big.vcd small.vcd --from 112900 --to 113060
"""
import argparse
import re
import sys

UNIT = {"fs": 1e-15, "ps": 1e-12, "ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1.0}


def vcd_units_per_second(timescale_line):
    m = re.search(r"\$timescale\s+([\d.]+)\s*(fs|ps|ns|us|ms|s)\s*\$end",
                  timescale_line)
    if not m:
        raise SystemExit("cannot parse $timescale: %r" % timescale_line)
    return float(m.group(1)) * UNIT[m.group(2)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--from", dest="cyc_from", type=int, required=True,
                    help="first cycle to keep (inclusive)")
    ap.add_argument("--to", dest="cyc_to", type=int, required=True,
                    help="last cycle to keep (inclusive)")
    ap.add_argument("--period-ns", type=float, default=10.0)
    ap.add_argument("--first-edge-ns", type=float, default=5.0)
    args = ap.parse_args()

    header = []
    timescale = None
    in_defs = True
    # pass 1: header (streamed; stops at first timestamp line)
    with open(args.src, "r", errors="replace") as f:
        for line in f:
            if line.startswith("$timescale"):
                timescale = line
            if in_defs:
                header.append(line)
                if line.startswith("$enddefinitions"):
                    in_defs = False
                    break
        if in_defs or timescale is None:
            raise SystemExit("no $enddefinitions/$timescale found - not a VCD?")
        t_from_ns = args.first_edge_ns + args.period_ns * args.cyc_from
        t_to_ns = args.first_edge_ns + args.period_ns * (args.cyc_to + 1)
        ups = vcd_units_per_second(timescale)
        lo = int(round(t_from_ns * 1e-9 / ups))
        hi = int(round(t_to_ns * 1e-9 / ups))

        kept = total = 0
        emit = False
        with open(args.dst, "w") as o:
            o.writelines(header)
            o.write("$comment window cycles %d..%d (vcd time %d..%d) $end\n"
                    % (args.cyc_from, args.cyc_to, lo, hi))
            for line in f:
                if line.startswith("#"):
                    total += 1
                    t = int(line[1:].strip() or 0)
                    emit = lo <= t <= hi
                if emit:
                    kept += 1
                    o.write(line)
    print("kept %d/%d timestamp sections -> %s" % (kept, total, args.dst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
