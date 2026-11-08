"""Reject malformed, truncated or empty vector artifacts before HDL execution."""
import argparse
import json
from pathlib import Path


def integer(text, base, width):
    alphabet = '0123456789abcdef' if base == 16 else '0123456789'
    if not text or any(char.lower() not in alphabet for char in text):
        raise ValueError('invalid numeric token: ' + text)
    value = int(text, base)
    if not 0 <= value < (1 << width):
        raise ValueError('out-of-range token: ' + text)
    return value


def math_rows(path):
    rows = Path(path).read_text().splitlines()
    if not rows:
        raise ValueError('empty arithmetic vectors')
    widths = {'FM': (32, 32, 32), 'AC': (128, 128, 128, 64),
              'QU': (512, 256, 8), 'SG': (16, 32)}
    for line in rows:
        parts = line.split()
        if not parts or parts[0] not in widths or len(parts)-1 != len(widths[parts[0]]):
            raise ValueError('bad arithmetic vector: ' + line)
        for text, width in zip(parts[1:], widths[parts[0]]):
            integer(text, 16, width)
    return len(rows)


def validate(directory):
    root = Path(directory)
    checks = json.loads((root / 'checks.json').read_text())
    math_count = math_rows(root / 'math.txt')
    math_rows(root / 'modules.txt')
    flits = (root / 'flits.txt').read_text().splitlines()
    beats = (root / 'expect.txt').read_text().splitlines()
    words = (root / 'rram.hex').read_text().splitlines()
    if not flits or not beats or not words:
        raise ValueError('empty tile vectors')
    if len(flits) != checks['flits'] or len(beats) != checks['beats']:
        raise ValueError('vector count mismatch')
    for line in flits:
        parts = line.split()
        if len(parts) != 4 or parts[0] != 'D':
            raise ValueError('bad down flit')
        integer(parts[1], 10, 32)
        integer(parts[2], 16, 32)
        integer(parts[3], 16, 512)
    y_packets = 0
    for line in beats:
        parts = line.split()
        if len(parts) != 6 or parts[0] != 'U':
            raise ValueError('bad up beat')
        values = [integer(text, base, width) for text, base, width in
                  zip(parts[1:], (10, 16, 10, 10, 16), (2, 8, 1, 2, 128))]
        y_packets += values[0] == 1 and values[2] == 1
    if y_packets != checks['y_packets']:
        raise ValueError('Y packet count mismatch')
    addresses = set()
    for line in words:
        parts = line.split()
        if len(parts) != 2:
            raise ValueError('bad RRAM word')
        address = integer(parts[0], 16, 18)
        integer(parts[1], 16, 1024)
        if address in addresses:
            raise ValueError('duplicate RRAM address')
        addresses.add(address)
    expected = '%d %d %d %d %x' % (
        checks['flits'], checks['beats'], checks['sync1_gu'] + checks['sync1_d'],
        checks['y_packets'], checks['expected_err_status'])
    if (root / 'checks.txt').read_text().strip() != expected:
        raise ValueError('check manifest mismatch')
    return dict(math=math_count, flits=len(flits), beats=len(beats), words=len(words))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory')
    print(json.dumps(validate(parser.parse_args().directory)))
