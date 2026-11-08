"""Strict event comparison. No inferred offset, tolerance, or event dropping."""
import argparse
import csv
import json
from pathlib import Path


def read_events(path):
    with Path(path).open(newline='') as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ['cycle', 'event', 'transaction', 'value']:
            raise ValueError('invalid trace header')
        events = []
        for row in reader:
            if None in row or not row['event']:
                raise ValueError('invalid trace row')
            events.append(dict(cycle=int(row['cycle']), event=row['event'],
                               transaction=int(row['transaction']), value=int(row['value'])))
    if not events or any(row['cycle'] < 0 for row in events):
        raise ValueError('empty trace or negative cycle')
    if any(left['cycle'] > right['cycle'] for left, right in zip(events, events[1:])):
        raise ValueError('non-monotonic trace')
    return events


def compare(expected, actual):
    keys = sorted(set(row['event'] for row in expected + actual))
    for event in keys:
        left = [row for row in expected if row['event'] == event]
        right = [row for row in actual if row['event'] == event]
        for index in range(max(len(left), len(right))):
            want = left[index] if index < len(left) else None
            got = right[index] if index < len(right) else None
            if want != got:
                return dict(status='failed', event=event, index=index,
                            expected=want, actual=got,
                            expected_context=left[max(0, index-2):index+3],
                            actual_context=right[max(0, index-2):index+3])
    return dict(status='passed', events=len(expected), scope=keys)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('expected')
    parser.add_argument('actual')
    args = parser.parse_args()
    result = compare(read_events(args.expected), read_events(args.actual))
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
