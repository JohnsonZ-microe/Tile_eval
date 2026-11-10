#!/usr/bin/env python3
"""Compute-core checkpoint trace (04 Compute Core).

Generates FP4 stimulus + expected FP32 values at each PE pipeline checkpoint.
Output feeds tb_compute_v4.sv.  Usage:
    python3 model/compute_trace.py --out <vectors>/compute_trace.txt
"""
import argparse, random, sys
from pathlib import Path
from fractions import Fraction

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tile_reference import fp_add, fp_shift, round_fp32

FP4 = {0:Fraction(0),1:Fraction(1,2),2:Fraction(1),3:Fraction(3,2),
       4:Fraction(2),5:Fraction(3),6:Fraction(4),7:Fraction(6)}
def fp4(c): v=FP4[c&7]; return -v if c&8 else v
def e4m3(c):
    if c&127==127: return Fraction(0)
    e=(c>>3)&15; m=c&7; s=-1 if c&128 else 1
    if e==0: return Fraction(s*m,512)
    return Fraction(s*(8+m),8)*Fraction(2)**(e-7)

def gen(seed=817):
    rng=random.Random(seed)
    NKB,NCOL=3,8
    lines=[]
    # per-column RF accumulators (8 columns, lane 0 only)
    rf=[0]*NCOL
    # shared activations (same 32 codes for all k-blocks and columns)
    acodes=[rng.randrange(1,120) for _ in range(32)]
    for j in range(32):
        lines.append("ACT %d %02x"%(j,acodes[j]))
    lines.append("ASCALE 7f")
    lines.append("WSCALE 7f")
    for kb in range(NKB):
        lines.append("# k_block=%d"%kb)
        wcols=[[rng.randrange(0,16) for _ in range(32)] for _ in range(NCOL)]
        for c in range(NCOL):
            for j in range(32):
                lines.append("WEIGHT %d %d %d %01x"%(kb,c,j,wcols[c][j]))
        for c in range(NCOL):
            exact=Fraction(0)
            for j in range(32):
                exact+=fp4(wcols[c][j])*e4m3(acodes[j])
            p32=round_fp32(exact)
            lines.append("CP_FP32 %d %d value=%08x"%(kb,c,p32))
            sc=fp_shift(p32,0)  # ascale=127,wscale=127 -> shift 0
            lines.append("CP_SCALE %d %d value=%08x"%(kb,c,sc))
            rf[c]=fp_add(rf[c] if kb>0 else 0, sc)
            lines.append("CP_RF %d %d value=%08x"%(kb,c,rf[c]))
    return '\n'.join(lines)

if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--out',required=True)
    ap.add_argument('--seed',type=int,default=817)
    a=ap.parse_args()
    t=gen(a.seed)
    Path(a.out).write_text(t+'\n')
    print("wrote %s (%d lines)"%(a.out,t.count('\n')+1))
