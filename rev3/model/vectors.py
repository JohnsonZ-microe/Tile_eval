import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ORACLE = ROOT / 'oracle' if (ROOT / 'oracle').exists() else ROOT.parent / 'model'
sys.path.insert(0, str(ORACLE))
from reference import ArrayReference, decode, dot32, pack, power2, fp_add, fp_mul, fp_shift, apply_scale
from generate_vectors import build_cycles, transaction, write_math_vectors


def latency():
    source = (ROOT / 'rtl' / 'pe3_pkg.sv').read_text()
    stages = [int(re.search(r'localparam int '+name+r' = (\d+);', source).group(1))
              for name in ['INPUT_STAGES', 'DOT_STAGES', 'SCALE_STAGES', 'ADD_STAGES']]
    return sum(stages)-1


def addresses(sample):
    fmt, base, mask = sample['fmt'], sample['base'], sample['mask']
    ncols = 8 if fmt in (0, 4) else 2 if fmt == 5 else 4
    if fmt > 5 or base+ncols > 80 or not mask:
        return set()
    return {(column, lane) for column in range(base, base+ncols) for lane in range(4) if mask >> lane & 1}


def schedule(samples, delay=None):
    delay = latency() if delay is None else delay
    model = ArrayReference()
    occupied, pending = set(), {}
    cycle, sticky, accepts, commits, stalls = 0, 0, 0, 0, 0
    longest, run = 0, 0
    rows = []
    empty = dict(samples[0], rst=1, valid=0)
    for sample in list(samples)+[empty.copy() for _ in range(delay+1)]:
        while True:
            claim = addresses(sample)
            ready = bool(sample['rst'] and not (occupied & claim))
            accepted = bool(ready and sample['valid'])
            expected = dict(valid=0, done=0, tag=0, mask=0, colmask=0, base=0, error=0, results=0)
            if not sample['rst']:
                occupied.clear()
                pending.clear()
                model = ArrayReference()
                sticky = 0
            else:
                if cycle in pending:
                    previous = pending.pop(cycle)
                    expected.update(model.execute(previous), valid=1, tag=previous['tag'], base=previous['base'])
                    occupied -= addresses(previous)
                    sticky |= expected['error']
                    commits += 1
                if accepted:
                    occupied |= claim
                    pending[cycle+delay] = dict(sample)
                    accepts += 1
            run = run+1 if accepted else 0
            longest = max(longest, run)
            expected.update(sticky=sticky, busy=int(bool(pending)), ready=int(ready))
            rows.append((dict(sample), expected))
            cycle += 1
            if accepted or not sample['valid'] or not sample['rst']:
                break
            stalls += 1
            if stalls > 1000000:
                raise RuntimeError('scheduler timeout')
    assert not pending and not occupied
    return rows, model.rf, dict(cycles=cycle, accepts=accepts, commits=commits, stalls=stalls, longest_accept_run=longest)


def stimuli(seed, suite):
    samples, coverage = build_cycles(seed, suite)
    rng = random.Random(seed+1)
    empty = dict(samples[0], rst=1, valid=0)
    extra = [dict(empty, rst=0)]
    for base in range(0, 80, 8):
        for lane in range(4):
            extra.append(transaction(rng, 0, 1 << lane, base))
    extra.extend(empty.copy() for _ in range(latency()+1))
    extra.extend([transaction(rng, 0, 15, 0), transaction(rng, 1, 5, 4, first=0)])
    for depth in range(1, latency()+1):
        extra.extend([dict(empty, rst=0), transaction(rng)])
        extra.extend(empty.copy() for _ in range(depth-1))
        extra.append(dict(empty, rst=0))
    samples += extra
    for index, sample in enumerate(samples):
        sample['tag'] = index
    return samples, coverage+['40_independent_consecutive_accepts', 'partial_overlap_stall', 'reset_all_inflight_positions']


def write_dot(destination, seed, suite):
    rng = random.Random(seed)
    count = 0
    with (destination / 'dot.txt').open('w') as stream:
        for wide in [0, 1]:
            for index in range(1000 if suite == 'full' else 60):
                fmt = 5 if wide else rng.randrange(5)
                width = 16 if fmt == 5 else 4 if fmt in (0, 4) else 8
                weights = [rng.getrandbits(width) for _ in range(32)]
                activations = [rng.randrange(256) for _ in range(32)]
                if wide and index < 4:
                    weights = [0x7f7f, 1, 0xff7f]+[0]*29
                    activations = [0x38]*32
                elif wide and index < 12:
                    code = [0x7f7f,0xff7f,1,0x8001,0,0x8000,0x7f80,0x7fc0][index-4]
                    weights = [code]*32
                    activations = [0x7e]*32
                elif 12 <= index < 45:
                    fmt = 5 if wide else 4
                    weights = ([0xbf80 if wide else 0xf]*(index-12)+
                               [0x3f80 if wide else 1]*(44-index))
                    activations = [0x38]*32
                from reference import decode_bf16
                decoded = [decode_bf16(code, fmt) for code in weights]
                finite = all(not isinstance(decode(code, fmt), str) for code in weights)
                total = sum(decode(weight, fmt)*decode(activation, 1) for weight, activation in zip(weights, activations)) if finite else 0
                quantum = -142 if wide else -18
                exact = int(total / power2(quantum)) & ((1 << (285 if wide else 42))-1)
                stream.write('%x %x %x %x %x %x\n' % (wide, pack(decoded,16),pack(activations,8),dot32(weights,activations,fmt),int(finite),exact))
                count += 1
    return count


def generate(destination, seed=817, suite='full'):
    destination.mkdir(parents=True, exist_ok=True)
    samples, coverage = stimuli(seed, suite)
    rows, rf, stats = schedule(samples)
    inputs = ['rst','valid','fmt','weights','activations','ascales','wscales','mask','base','first','last','tag']
    outputs = ['valid','done','tag','mask','colmask','base','error','sticky','results','busy','ready']
    with (destination/'array.txt').open('w') as stream:
        for sample, expected in rows:
            stream.write(' '.join(format(sample[key],'x') for key in inputs)+' '+
                         ' '.join(format(expected[key],'x') for key in outputs)+'\n')
    with (destination/'rf.txt').open('w') as stream:
        for column in range(80):
            for lane in range(4):
                stream.write('%x %x %08x\n' % (column,lane,rf[column][lane]))
    math_count=write_math_vectors(destination,seed,suite)
    with (destination/'math.txt').open('a') as stream:
        def emit(operation,left,right,auxiliary,expected):
            stream.write('%x %x %x %x %x\n'%(operation,left & 0xffffffff,right & 0xffffffff,auxiliary,expected))
        for exponent in range(1,255):
            left=(exponent << 23) | 0x555555
            for delta in [-1,0,1]:
                right=(left+delta) | 0x80000000
                emit(1,left,right,0,fp_add(left,right))
                math_count+=1
            for difference in [1,2,3,4,23,24,25,26,27,31,32,254]:
                right=(max(0,exponent-difference) << 23) | 0x7fffff
                for sign in [0,0x80000000]:
                    emit(1,left,right|sign,0,fp_add(left,right|sign))
                    math_count+=1
        for value in [1,2,3,0x7fffff,0x800000,0x3f800001,0x7f7fffff]:
            for amount in [-254,-150,-149,-127,-126,-25,-24,-1,0,1,24,127,254]:
                emit(3,value,amount,0,fp_shift(value,amount))
                math_count+=1
            for fmt in [2,3,4]:
                weight=0x40000000 if fmt==2 else 0x4000
                emit(4,value,weight,(fmt << 8)|126,apply_scale(value,fmt,126,weight))
                math_count+=1
    rng = random.Random(seed+3)
    cpa_count = 2000 if suite == 'full' else 200
    with (destination/'cpa.txt').open('w') as stream:
        for index in range(cpa_count):
            left, right = rng.getrandbits(285), rng.getrandbits(285)
            if index < 285:
                left, right = (1 << index)-1, 1
            reset = int(index > 1 and index % 37 != 0)
            valid = int(index % 7 != 0)
            stream.write('%x %x %x %x %x %x %x\n' % (reset,valid,left,right,
                (left+right)&((1 << 42)-1),(left+right)&((1 << 48)-1),(left+right)&((1 << 285)-1)))
    stats.update(seed=seed, suite=suite, commit_delay=latency(), coverage=coverage,
                 cpa_vectors=cpa_count,
                 math_vectors=math_count, dot_vectors=write_dot(destination,seed,suite),
                 status='expected vectors only; not an RTL simulation')
    stats['sha256'] = {path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in destination.glob('*.txt')}
    (destination/'vectors.json').write_text(json.dumps(stats,indent=2))
    return stats


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--seed', type=int, default=817)
    parser.add_argument('--suite', choices=['smoke','full'], default='full')
    args = parser.parse_args()
    print(json.dumps(generate(args.out,args.seed,args.suite),indent=2))
