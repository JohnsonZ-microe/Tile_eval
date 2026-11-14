"""Strict rev4 schema-2 comparison; trace agreement is not full calibration."""
import argparse
import csv
import json
import re
from pathlib import Path

FIELDS = 'epoch cycle sample event transaction pass phase slot kb group bank payload'.split()
NUMBERS = [key for key in FIELDS if key not in ('sample', 'event', 'payload')]


def read_events(path):
    events = []
    previous = None
    with Path(path).open(newline='', encoding='utf-8') as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != FIELDS:
            raise ValueError('expected calibration trace schema 2')
        for line, row in enumerate(reader, 2):
            if None in row or any(value is None or value == '' for value in row.values()):
                raise ValueError('line {}: missing or extra field'.format(line))
            for key in NUMBERS:
                if not re.fullmatch(r'-?[0-9]+', row[key]):
                    raise ValueError('line {}: invalid {}'.format(line, key))
                row[key] = int(row[key])
                if row[key] < (0 if key in ('epoch', 'cycle') else -1):
                    raise ValueError('line {}: invalid {}'.format(line, key))
            if row['sample'] not in ('pre', 'post') or not re.fullmatch(r'[a-z][a-z0-9_]*', row['event']):
                raise ValueError('line {}: invalid sampling stage or event'.format(line))
            if not re.fullmatch(r'[0-9a-fA-F]{128}', row['payload']):
                raise ValueError('line {}: payload must be 512 known bits (no X/Z)'.format(line))
            row['payload'] = row['payload'].lower()
            order = (row['epoch'], row['cycle'], int(row['sample'] == 'post'))
            if previous is not None and order < previous:
                raise ValueError('line {}: non-monotonic epoch/cycle/sample'.format(line))
            previous = order
            events.append(row)
    if not events:
        raise ValueError('empty calibration trace')
    return events


def compare(expected, actual, required_events=()):
    if not expected or not actual:
        return dict(status='failed', reason='empty trace')
    channels = sorted(set(row['event'] for row in expected + actual))
    for name in sorted(set(required_events)):
        for label, rows in (('expected', expected), ('actual', actual)):
            if not any(row['event'] == name for row in rows):
                return dict(status='failed', reason='required event missing', trace=label, event=name)
    left_channels = {name: [] for name in channels}
    right_channels = {name: [] for name in channels}
    for row in expected:
        left_channels[row['event']].append(row)
    for row in actual:
        right_channels[row['event']].append(row)
    # Independent channels can be emitted in either order on the same sample.
    # Within each channel, preserve every occurrence and every identity field.
    for name in channels:
        left, right = left_channels[name], right_channels[name]
        for index in range(max(len(left), len(right))):
            want = left[index] if index < len(left) else None
            got = right[index] if index < len(right) else None
            if want != got:
                return dict(status='failed', event=name, index=index,
                            expected=want, actual=got,
                            differing_fields=[key for key in FIELDS if want is None or got is None or want[key] != got[key]],
                            expected_context=left[max(0, index-2):index+3],
                            actual_context=right[max(0, index-2):index+3])
    return dict(status='passed', events=len(expected), scope=channels,
                calibration='trace agreement only; stimulus and coverage require separate evidence')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('expected')
    parser.add_argument('actual')
    parser.add_argument('--require-event', action='append', default=[])
    args = parser.parse_args()
    try:
        result = compare(read_events(args.expected), read_events(args.actual), args.require_event)
    except (ValueError, OSError) as error:
        result = dict(status='failed', reason=str(error))
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
