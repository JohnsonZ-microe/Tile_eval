#!/usr/bin/env python3
"""Generate the rev4 sigmoid ROM (rev4/scripts/gen_sigmoid_rom.py).

Table: 2^16 entries x 32 b, indexed by the raw 16-bit BF16 code of the gate
value z. value = fp32(sigmoid(bf16_to_double(code))) evaluated in IEEE double
precision with a single FP32 RNE rounding (struct pack). Special codes:
NaN -> 0x7FC00000 (canonical), +inf -> 1.0, -inf -> 0.0, +-0 -> 0.5.

The output hex file is bound by SHA-256 in docs/baseline.json; the offline
reference (model/tile_reference.py sigmoid_table) generates identical bytes.
"""
import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path


def bf16_to_double(code):
    return struct.unpack('>f', struct.pack('>I', code << 16))[0]


def fp32_from_double(x):
    return struct.unpack('>I', struct.pack('>f', x))[0]


def entry(code):
    if (code & 0x7F80) == 0x7F80 and (code & 0x7F):   # NaN
        return 0x7FC00000
    v = bf16_to_double(code)
    if math.isnan(v):
        return 0x7FC00000
    if math.isinf(v):
        return fp32_from_double(1.0 if v > 0 else 0.0)
    # numerically stable form of the frozen reference (arith_cells 5):
    # z >= 0: 1/(1+exp(-z));  z < 0: exp(z)/(1+exp(z)); double, then FP32.
    # No cutoffs: exp(v) for v<0 never overflows (underflows to 0.0), so
    # FP32 subnormals in the far negative tail are preserved (R4-009).
    if v >= 0.0:
        s = 1.0 / (1.0 + math.exp(-v))
    else:
        e = math.exp(v)
        s = e / (1.0 + e)
    return fp32_from_double(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='rtl/pe4_sigmoid_rom.hex')
    args = ap.parse_args()
    table = [entry(c) for c in range(65536)]
    path = Path(args.out)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', newline='\n') as fh:
        for v in table:
            fh.write('%08x\n' % v)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(json.dumps({'path': str(path), 'entries': 65536,
                      'sha256': digest, 'bytes': path.stat().st_size}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
