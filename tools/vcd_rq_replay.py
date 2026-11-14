#!/usr/bin/env python3
"""vcd_rq_replay.py - replay RQ/scheduler state from a windowed tile VCD.

Prints, for every rising clk edge in [lo, hi], the PRE-edge values (what the
RTL samples) of iss_fire0/1, rram handshake, rq pointers/count and the four
RQ entries' slot/full bits - enough to adjudicate RQ identity questions.

Usage: python3 vcd_rq_replay.py tile_ffn_v4.vcd 113000 113050
"""
import argparse
import re
import sys

WANT = {
    "clk": "tb_tile_v4.clk",
    "fire0": "sched_u.iss_fire0", "fire1": "sched_u.iss_fire1",
    "req": "sched_u.rram_req", "ready": "sched_u.rram_ready",
    "valid": "sched_u.rram_valid", "cons": "sched_u.cons_fire",
    "push": "sched_u.rq_push", "fill": "sched_u.rq_fill",
    "cons_p": "sched_u.rq_cons", "cnt": "sched_u.rq_cnt",
    "iss0v": "sched_u.iss[0].valid", "iss1v": "sched_u.iss[1].valid",
    "s0v": "sched_u.slot[0].valid", "s1v": "sched_u.slot[1].valid",
}
for _i in range(4):
    WANT["rq%ds" % _i] = "sched_u.rq[%d].slot" % _i
    WANT["rq%df" % _i] = "sched_u.rq[%d].full" % _i


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("lo", type=int)
    ap.add_argument("hi", type=int)
    ap.add_argument("--first-edge-ns", type=float, default=5.0)
    ap.add_argument("--period-ns", type=float, default=10.0)
    a = ap.parse_args()

    id2key, clk_id, scale_ps, scopes = {}, None, None, []
    hdr = []
    with open(a.vcd, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            hdr.append(line)
            if line.startswith("$enddefinitions"):
                break
    m = re.search(r"\$timescale\s+([\d.]+)\s*(s|ms|us|ns|ps|fs)", " ".join(hdr))
    scale_ps = float(m.group(1)) * {"s": 1e12, "ms": 1e9, "us": 1e6,
                                    "ns": 1e3, "ps": 1.0, "fs": 1e-3}[m.group(2)]
    for line in hdr:
        if line.startswith("$scope"):
            scopes.append(line.split()[2])
        elif line.startswith("$upscope"):
            scopes.pop()
        elif line.startswith("$var"):
            p = line.split()
            full = ".".join(scopes + [p[4]])
            for k, suf in WANT.items():
                if full == suf or full.endswith("." + suf):
                    id2key[p[3]] = k
                    if k == "clk":
                        clk_id = p[3]
    if clk_id is None:
        raise SystemExit("clk not found")
    missing = [s for s in WANT if s not in id2key.values()]
    if missing:
        print("WARNING unmapped:", missing)

    vals, snaps = {}, []

    def apply(ch):
        ch = ch.strip()
        if ch and ch[0] in "01xzXZ":
            if ch[1:] in id2key:
                vals[id2key[ch[1:]]] = ch[0]
        elif ch[:1] in "bB":
            bits, vid = ch[1:].split(None, 1)
            if vid in id2key:
                vals[id2key[vid]] = bits

    period = a.period_ns * 1e3 / scale_ps
    base = a.first_edge_ns * 1e3 / scale_ps
    with open(a.vcd, "r", errors="replace") as f:
        t, body, rise = None, [], False
        for line in f:
            line = line.strip()
            if line.startswith("#"):
                if t is not None:
                    pre = dict(vals)
                    for ch in body:
                        apply(ch)
                    if rise:
                        snaps.append((int((t - base) // period), pre))
                t, body, rise = int(line[1:]), [], False
            elif line and not line.startswith("$"):
                if line[0] == "1" and line[1:] == clk_id:
                    rise = True
                body.append(line)

    print("cyc    f0 f1 rq rd va cs | push fl cns cnt | rq0 rq1 rq2 rq3 s,f | i0v i1v s0v s1v")
    for cyc, v in snaps:
        if a.lo <= cyc <= a.hi:
            rq = " ".join("%s%s" % (v.get("rq%ds" % i, "?"),
                                    v.get("rq%df" % i, "?")) for i in range(4))

            def num(k):
                b = v.get(k, "?")
                try:
                    return "%2d" % int(b, 2)
                except Exception:
                    return "%2s" % b
            print("%6d  %s  %s  %s   %s %s %s %s" % (
                cyc,
                " ".join(v.get(k, "?") for k in
                         ("fire0", "fire1", "req", "ready", "valid", "cons")),
                " ".join(num(k) for k in ("push", "fill", "cons_p", "cnt")),
                rq, v.get("iss0v", "?"), v.get("iss1v", "?"),
                v.get("s0v", "?"), v.get("s1v", "?")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
