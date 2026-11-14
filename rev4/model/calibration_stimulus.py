"""Extract external edge inputs, never DUT observations, from schema-2 traces.

Reset rows denote epoch initialization, not physical reset duration. Sparse rows
must be replayed with zero dn_valid/up_credit on intervening active cycles.
No model outputs, completion horizon or memory contents are inferred here.
"""
import argparse
import hashlib
import json
from pathlib import Path
from calibration_compare import read_events


def extract(events):
    result = []
    initialized = set()
    seen = set()
    for row in events:
        kind = row['event']
        if kind not in ('reset', 'down', 'credit'):
            continue
        epoch, cycle = row['epoch'], row['cycle']
        if row['sample'] != 'pre':
            raise ValueError('external inputs must be sampled pre-edge')
        key = (epoch, cycle, kind)
        if key in seen:
            raise ValueError('duplicate external input on one edge')
        seen.add(key)
        if kind == 'reset':
            if cycle != 0 or epoch in initialized:
                raise ValueError('reset must initialize a new epoch at cycle zero')
            if int(row['payload'], 16) != 0:
                raise ValueError('unexpected reset payload')
            initialized.add(epoch)
            result.append(dict(epoch=epoch, cycle=0, event='reset'))
            continue
        if epoch not in initialized:
            raise ValueError('external input before epoch reset')
        value = int(row['payload'], 16)
        if kind == 'down':
            sideband = row['transaction']
            if not 0 <= sideband < (1 << 32):
                raise ValueError('down sideband outside 32-bit port')
            if row['pass'] != ((sideband >> 3) & 255):
                raise ValueError('down pass metadata disagrees with sideband')
            result.append(dict(epoch=epoch, cycle=cycle, event='down',
                               sideband=sideband, payload=row['payload']))
        else:
            if not 1 <= value <= 3:
                raise ValueError('credit must be a nonzero 2-bit increment')
            result.append(dict(epoch=epoch, cycle=cycle, event='credit', value=value))
    if not any(row['event'] == 'down' for row in result):
        raise ValueError('no down stimulus')
    # Independent input channels have no intra-edge order; initialization first.
    rank = {'reset': 0, 'down': 1, 'credit': 2}
    return sorted(result, key=lambda row: (row['epoch'], row['cycle'], rank[row['event']]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    inputs = extract(read_events(args.trace))
    artifact = dict(schema=1, inputs=inputs,
                    source_sha256=hashlib.sha256(args.trace.read_bytes()).hexdigest(),
                    scope='external down/credit edges and reset epochs only; not model predictions',
                    missing=['memory image', 'physical reset duration', 'explicit replay horizon'])
    # Never replace a historical artifact by accident.
    with args.out.open('x', encoding='utf-8') as stream:
        json.dump(artifact, stream, indent=2)
        stream.write('\n')
    print(json.dumps(dict(status='extracted', inputs=len(inputs), output=str(args.out))))


if __name__ == '__main__':
    main()
