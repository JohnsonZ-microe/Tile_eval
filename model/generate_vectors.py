import argparse
import hashlib
import json
from pathlib import Path
import random

from reference import (ArrayReference, CANON_NAN, INF, apply_scale, decode_bf16, fp_add,
                       fp_mul, fp_shift, pack)


def transaction(rng, fmt=0, mask=15, base=0, first=1, last=1):
    width = 4 if fmt in (0, 4) else (16 if fmt == 5 else 8)
    count = 1024 // width
    if fmt == 5:
        weights = [rng.choice([0, 1, 0x8001, 0x3F80, 0xBF80, 0x3E00, 0x4001, 0x4123]) for _ in range(count)]
    else:
        weights = [rng.randrange(1 << width) for _ in range(count)]
    return dict(rst=1, valid=1, fmt=fmt, weights=pack(weights, width),
                activations=pack([rng.randrange(256) for _ in range(128)], 8),
                ascales=pack([rng.randrange(120, 133) for _ in range(4)], 8),
                wscales=pack([rng.randrange(120, 133) if fmt in (0, 1) else
                             rng.choice([0x3F000000, 0x3F800000, 0xBF800000]) if fmt == 2 else 0x3F80
                             for _ in range(8)], 32),
                mask=mask, base=base, first=first, last=last, tag=0)


def build_cycles(seed, suite):
    rng = random.Random(seed)
    empty = dict(rst=1, valid=0, fmt=0, weights=0, activations=0, ascales=0,
                 wscales=0, mask=0, base=0, first=0, last=0, tag=0)
    cycles = [dict(empty, rst=0), dict(empty, rst=0)]
    coverage = []
    for fmt in range(6):
        for tokens in range(1, 5):
            coverage.append(f'format_{fmt}_tokens_{tokens}')
            for block in range(6):
                cycles.append(transaction(rng, fmt, (1 << tokens) - 1, first=int(block == 0), last=int(block == 5)))
                if block == 2:
                    cycles.append(empty.copy())
    for fmt in range(6):
        for base in [0, 8, 16, 72, 24, 8, 0]:
            cycles.append(transaction(rng, fmt, rng.choice([1, 2, 5, 10, 15]), base, first=0))
    for dimension in ([5120, 2304] if suite == 'full' else [64]):
        for fmt in range(6):
            coverage.append(f'format_{fmt}_K_{dimension}')
            held_scales = 0
            for block in range(dimension // 32):
                sample = transaction(rng, fmt, first=int(block == 0), last=int(block == dimension // 32 - 1))
                if fmt in (2, 3):
                    if block % 4 == 0:
                        held_scales = sample['wscales']
                    sample['wscales'] = held_scales
                cycles.append(sample)
    for fmt, base, mask in [(6, 0, 15), (7, 0, 15), (0, 73, 15), (1, 77, 15), (5, 79, 15), (0, 0, 0)]:
        cycles.append(transaction(rng, fmt, mask, base))
    for fmt in range(6):
        sample = transaction(rng, fmt)
        sample['ascales'] = pack([255, 0, 254, 127], 8)
        sample['wscales'] = pack([255 if fmt < 2 else (0x7FC00000 if fmt == 2 else 0x7FC0)] * 8, 32)
        cycles.append(sample)
    for weight_code in [0x0001, 0x8001, 0x7F7F, 0xFF7F, 0x7F80, 0xFF80, 0x7FC0]:
        sample = transaction(rng, 5)
        sample.update(weights=pack([weight_code] * 64, 16), activations=pack([1] * 128, 8),
                      ascales=pack([127] * 4, 8))
        cycles.append(sample)
    sample = transaction(rng, 5)
    sample.update(weights=pack(([0x7F7F, 0x3F80, 0xFF7F] + [0] * 29) * 2, 16),
                  activations=pack([0x38] * 128, 8), ascales=pack([127] * 4, 8))
    cycles.append(sample)
    sample = transaction(rng, 0)
    sample.update(activations=pack([0x38] * 7 + [0] * 25, 8), mask=1)
    cycles.append(sample)
    coverage.extend(['noncontiguous_token_masks', 'column_interleave', 'same_address_hazard',
                     'invalid_descriptor', 'numeric_substitution', 'bf16_extremes', 'exact_cancellation', 'padding',
                     '128k_scale_reuse'])
    for _ in range(5):
        cycles.append(empty.copy())
    for depth in range(1, 5):
        cycles.extend(transaction(rng, fmt=1) for _ in range(depth))
        cycles.append(dict(empty, rst=0))
        cycles.extend(empty.copy() for _ in range(6))
    coverage.append('reset_each_pipeline_position')
    for _ in range(100 if suite == 'full' else 20):
        cycles.append(transaction(rng, rng.randrange(6), rng.randrange(1, 16), rng.choice([0, 8, 24, 64]), rng.randrange(2)))
        if rng.randrange(3) == 0:
            cycles.append(empty.copy())
    cycles.extend(empty.copy() for _ in range(6))
    for index, sample in enumerate(cycles):
        sample['tag'] = index
    return cycles, coverage


def write_array_vectors(destination, cycles):
    model = ArrayReference()
    pending = {}
    sticky = 0
    committed_count = 0
    keys = ['rst', 'valid', 'fmt', 'weights', 'activations', 'ascales', 'wscales', 'mask', 'base', 'first', 'last', 'tag']
    with (destination / 'array.txt').open('w', encoding='ascii') as stream:
        for index, sample in enumerate(cycles):
            expected = dict(valid=0, done=0, tag=0, mask=0, colmask=0, base=0, error=0, results=0)
            if not sample['rst']:
                model = ArrayReference()
                pending.clear()
                sticky = 0
            else:
                if index in pending:
                    old = pending.pop(index)
                    result = model.execute(old)
                    expected.update(result, valid=1, tag=old['tag'], base=old['base'])
                    sticky |= result['error']
                    committed_count += 1
                if sample['valid']:
                    pending[index + 4] = sample.copy()
            outputs = [expected[name] for name in ['valid', 'done', 'tag', 'mask', 'colmask', 'base', 'error']]
            outputs += [sticky, expected['results'], int(bool(pending))]
            stream.write(' '.join(f'{value:x}' for value in [sample[name] for name in keys] + outputs) + '\n')
    with (destination / 'rf.txt').open('w', encoding='ascii') as stream:
        for column in range(80):
            for lane in range(4):
                stream.write(f'{column:x} {lane:x} {model.rf[column][lane]:08x}\n')
    return committed_count


def write_math_vectors(destination, seed, suite):
    rng = random.Random(seed)
    count = 0
    with (destination / 'math.txt').open('w', encoding='ascii') as stream:
        def emit(operation, left, right, auxiliary, expected):
            nonlocal count
            stream.write(f'{operation:x} {left & 0xFFFFFFFF:x} {right & 0xFFFFFFFF:x} {auxiliary:x} {expected:08x}\n')
            count += 1
        for fmt in range(6):
            maximum = 16 if fmt in (0, 4) else (65536 if fmt == 5 and suite == 'full' else 256)
            for code in range(maximum):
                emit(0, code, fmt, 0, decode_bf16(code, fmt))
        specials = [0, 0x80000000, 1, 0x80000001, 0x007FFFFF, 0x00800000, 0x3F800000,
                    0xBF800000, 0x3F800001, 0x33800000, 0x7F7FFFFF, INF, INF | 0x80000000, CANON_NAN]
        for left in specials:
            for right in specials:
                emit(1, left, right, 0, fp_add(left, right))
                emit(2, left, right, 0, fp_mul(left, right))
            for amount in [-254, -150, -149, -127, -1, 0, 1, 127, 254]:
                emit(3, left, amount, 0, fp_shift(left, amount))
        for _ in range(4000 if suite == 'full' else 200):
            left, right = rng.getrandbits(32), rng.getrandbits(32)
            emit(1, left, right, 0, fp_add(left, right))
            emit(2, left, right, 0, fp_mul(left, right))
            amount = rng.randrange(-254, 255)
            emit(3, left, amount, 0, fp_shift(left, amount))
            fmt, activation_scale = rng.randrange(6), rng.randrange(256)
            emit(4, left, right, (fmt << 8) | activation_scale, apply_scale(left, fmt, activation_scale, right))
        emit(4, 1, 0x40000000, (2 << 8) | 126, 0)
    return count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--seed', type=int, default=817)
    parser.add_argument('--suite', choices=['smoke', 'full'], default='full')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    cycles, coverage = build_cycles(args.seed, args.suite)
    committed_count = write_array_vectors(args.out, cycles)
    math_count = write_math_vectors(args.out, args.seed, args.suite)
    hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in args.out.glob('*.txt')}
    manifest = dict(seed=args.seed, suite=args.suite, cycles=len(cycles), commits=committed_count,
                    math_vectors=math_count, coverage=coverage, sha256=hashes,
                    note='Generated expectations, not RTL simulation results.')
    (args.out / 'vectors.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(manifest))


if __name__ == '__main__':
    main()
